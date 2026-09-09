# Manual de Implementación — Zammad + Snipe-IT + n8n

- **Objetivo:** Implementar en una VM con Docker Engine el stack de mesa de ayuda (Zammad), gestión de activos (Snipe-IT) y automatización de integraciones (n8n).
- **Nivel de despliegue:** Un solo comando con Docker Compose.

---

## Tabla de contenido

1. [Propósito y beneficios](#1-propósito-y-beneficios)
2. [Diagramas del flujo de sincronización](#2-diagramas-del-flujo-de-sincronización)
3. [Uso de imágenes oficiales](#3-uso-de-imágenes-oficiales)
4. [Arquitectura](#4-arquitectura)
5. [Requisitos de hardware](#5-requisitos-de-hardware)
6. [Prerrequisitos](#6-prerrequisitos)
7. [Despliegue paso a paso](#7-despliegue-paso-a-paso)
8. [Tokens de acceso y usuarios de integración](#8-tokens-de-acceso-y-usuarios-de-integración)
9. [Operación diaria](#9-operación-diaria)
10. [Backups y restauración](#10-backups-y-restauración)
11. [Integración con Tryton (resumen)](#11-integración-con-tryton-resumen)
12. [Notas de producción](#12-notas-de-producción)

---

## 1. Propósito y beneficios

El stack combina tres tecnologías complementarias para el ciclo de vida del soporte y el inventario TI:

| Sistema | Rol | Resuelve |
|---------|-----|----------|
| **Zammad** | Mesa de ayuda (helpdesk) | Gestión de tickets de soporte, canales de correo/chat, SLAs y base de conocimiento |
| **Snipe-IT** | Inventario de activos IT | Registro central de equipos (computadoras, laptops, switches, UPS, etc.), asignaciones a usuarios, historial y estados |
| **n8n** | Plataforma de automatización | Integraciones entre sistemas (ERP Tryton, Snipe-IT, Zammad) sin desarrollo a medida |

**Beneficios conjuntos:**

- **Información centralizada:** los técnicos ven desde el ticket el activo asignado al usuario, su estado y garantía, sin saltar entre sistemas.
- **Inventario siempre al día:** la sincronización desde el ERP (Tryton) mantiene Snipe-IT actualizado de forma automática, eliminando la carga manual.
- **Automatización de procesos:** n8n orquesta el movimiento de datos (extracción, transformación, carga) entre los tres ambientes.
- **Implementación estandarizada:** los tres sistemas corren con imágenes oficiales y configuración de referencia validada por cada vendor, sin Dockerfiles propios que mantener.

---

## 2. Diagramas del flujo de sincronización

### 2.1 Visión general

```
                        ┌───────────────────────────────────────────────┐
                        │               SERVIDOR (VM)                   │
                        │                                               │
  ┌───────────┐         │   ┌──────────────┐        ┌─────────────────┐ │
  │  TRYTON   │◄────────┼──►│      n8n     │───────►│    SNIPE-IT     │ │
  │ (ERP -    │ JSON-RPC│   │Automatización│ API    │ Gestión de      │ │
  │  activos) │  sesión │   │ (puerto 5678)│ Bearer │ activos         │ │
  └───────────┘         │   └──────┬───────┘        └────────┬────────┘ │
                        │          │                         │          │
                        │   ┌──────▼───────┐                 │          │
                        │   │    ZAMMAD    │◄────────────────┘          │
                        │   │ Mesa de ayuda│   consulta de activo       │
                        │   │ (puerto 8000)│   asociado al ticket       │
                        │   └──────────────┘                            │
                        │                                               │
                        │   Red interna Docker: bridge "net"            │
                        └───────────────────────────────────────────────┘

    Usuarios finales  ───►  Zammad (tickets)
    Usuarios TI       ───►  Snipe-IT (inventario) / Zammad (tickets)
    Administradores   ───►  n8n (workflows) / Snipe-IT / Zammad
```

### 2.2 Flujo de inventario: Tryton → n8n → Snipe-IT

```
┌────────────┐  1. Login JSON-RPC        ┌──────────────┐
│   TRYTON   │◄──────────────────────────│      n8n     │
│ (ERP)      │                           │              │
│            │  2. search_read activos   │   Workflow   │
│            │◄──────────────────────────│ "Tryton sync │
│            │──────────────────────────►│   assets"    │
│            │  JSON con ~19,339 activos │              │
└────────────┘                           └──────┬───────┘
                                                │
                                  3. API REST /api/v1
                                  (Bearer token)
                                                │
                                                ▼
                                        ┌──────────────┐
                                        │   SNIPE-IT   │
                                        │              │
                                        │ 4. Crea/     │
                                        │    actualiza │
                                        │    categorías│
                                        │    y activos │
                                        └──────────────┘

    Resultado: el inventario de Snipe-IT queda sincronizado con el ERP
    de forma automática y recurrente, sin digitación manual.
```

### 2.3 Flujo de soporte: Zammad → n8n → Snipe-IT

```
┌──────────────┐  1. Usuario reporta     ┌──────────────┐
│   ZAMMAD     │     problema            │     n8n      │
│ (Mesa de     │────────────────────────►│              │
│  ayuda)      │  ticket creado          │  Workflow    │
│              │                         │  "Activo del │
│              │  2. Enriquecer ticket   │   usuario"   │
│              │◄────────────────────────│              │
└──────────────┘                         └──────┬───────┘
                                                │
                                  3. API REST /api/v1/assets
                                  (buscar por usuario)
                                                │
                                                ▼
                                        ┌──────────────┐
                                        │   SNIPE-IT   │
                                        │              │
                                        │ 4. Devuelve  │
                                        │    activo    │
                                        │    asignado  │
                                        └──────────────┘

    Resultado: el técnico ve en el ticket qué equipo tiene asignado
    el usuario, su estado y garantía → resolución más rápida.
```

> El flujo 2.2 ya está implementado (workflows `Tryton sync categories` y `Tryton sync assets` en `flows/`). El flujo 2.3 es el caso de uso objetivo de la arquitectura y se construye en n8n sobre las mismas credenciales documentadas en la sección 8.

---

## 3. Uso de imágenes oficiales

### 3.1 Justificación

El stack **no utiliza Dockerfiles propios**: todos los servicios corren con las imágenes oficiales publicadas por cada vendor. Razones:

- **Seguridad y mantenimiento:** cada vendor publica parches de seguridad y correcciones en sus releases oficiales; actualizar es solo cambiar la etiqueta de la imagen y recrear los contenedores.
- **Configuración validada por el vendor:** los archivos `docker-compose.yml` oficiales de referencia (healthchecks, variables de entorno, volúmenes) son la fuente de la configuración usada en este proyecto; esto elimina errores de configuración y versiones divergentes entre entornos.
- **Cero mantenimiento propio:** no hay dependencias de librerías a actualizar, ni builds que se rompan, ni conocimiento interno necesario para mantener una imagen customizada.
- **Trazabilidad:** se conoce exactamente la version de cada componente (ej. Zammad latest, Elasticsearch 8.16.0, Postgres 15) y se puede reproducir el entorno en cualquier momento.

### 3.2 Fuentes oficiales utilizadas

| Servicio | Fuente oficial utilizada |
|----------|--------------------------|
| `zammad-*` | [zammad/zammad-docker-compose](https://github.com/zammad/zammad-docker-compose) + [docs.zammad.org](https://docs.zammad.org/en/latest/install/docker-compose.html) |
| `snipe-it` + `snipe-db` | [snipe/snipe-it docker-compose](https://github.com/snipe/snipe-it/blob/master/docker-compose.yml) + [snipe-it.readme.io/docs/docker](https://snipe-it.readme.io/docs/docker) |
| `n8n` + `n8n-db` | [n8n-io/n8n-hosting](https://github.com/n8n-io/n8n-hosting) + [docs.n8n.io](https://docs.n8n.io/hosting/installation/docker/) |

---

## 4. Arquitectura

### 4.1 Servicios y puertos

Toda la infraestructura corre en una única VM con Docker Compose. Los contenedores se comunican entre sí por una red bridge interna (`net`) y por la red externa `docker_net` hacia las bases de datos compartidas; solo se publican al host los puertos de las interfaces web y (en laboratorio) los de las bases de datos.

> **Bases de datos externas:** desde `refactor(zammad-snipeit): use external databases`, `snipe-db`/`zammad-db`/`n8n-db` ya no existen en este compose. Las DBs viven en contenedores externos `dbs-postgres` y `dbs-mariadb` definidos en `/Volumes/CRGS-1T/Docker/docker-compose.yml` (red `docker_net`, volumenes `/Volumes/CRGS-1T/Docker/data/*`). Crear roles/DBs con `./scripts/init-external-dbs.sh` antes del primer `up`.

**Snipe-IT — Gestión de activos (puerto `8080`)**

| Servicio | Imagen | Puerto publicado | Base de datos |
|----------|--------|------------------|---------------|
| `dbs-mariadb` (externo, `docker_net`, alias `mariadb`) | `mariadb:lts-ubi` | `3306:3306` | MySQL `snipeit` (`snipe_user`/`your_snipe_password_here`, creado por `init-external-dbs.sh`, ver `envs/snipe-db.env.example`) |
| `snipe-it` | `snipe/snipe-it:latest-alpine` | `8080:80` | Conecta a `mariadb` (alias de `dbs-mariadb` en `docker_net`) |

**Zammad — Mesa de ayuda (puerto `8000`)**

| Servicio | Imagen | Puerto publicado | Rol |
|----------|--------|------------------|-----|
| `dbs-postgres` (externo, `docker_net`, alias `postgres`) | `postgres:17-alpine` | `5432:5432` | PostgreSQL `zammad_production` (`zammad_user`, creado por `init-external-dbs.sh`) |
| `zammad-search` | `elasticsearch-wolfi:8.16.0` | — | Índices de búsqueda |
| `zammad-redis` | `redis:7-alpine` | — | Caché/sesiones |
| `zammad-memcached` | `memcached:1.6.42-alpine` | — | Caché de objetos (256M) |
| `zammad-init` | `ghcr.io/zammad/zammad:latest` | — | Inicializacion de la base (requiere DB externa existente; no crea rol/DB) |
| `zammad-railsserver` | `ghcr.io/zammad/zammad:latest` | — | Aplicacion principal |
| `zammad-scheduler` | `ghcr.io/zammad/zammad:latest` | — | Tareas programadas |
| `zammad-websocket` | `ghcr.io/zammad/zammad:latest` | — | Notificaciones en tiempo real |
| `zammad-nginx` | `ghcr.io/zammad/zammad:latest` | `8000:8080` | Reverse proxy interno |
| `zammad-backup` | `ghcr.io/zammad/zammad:latest` | — | Backups automaticos |

**n8n — Automatización (puerto `5678`)**

| Servicio | Imagen | Puerto publicado | Base de datos |
|----------|--------|------------------|---------------|
| `dbs-postgres` (externo, `docker_net`, alias `postgres`) | `postgres:17-alpine` | `5432:5432` | PostgreSQL `n8n` (`n8n_user`, creado por `init-external-dbs.sh`) |
| `n8n` | `docker.n8n.io/n8nio/n8n` | `5678:5678` | Conecta a `postgres` (alias de `dbs-postgres` en `docker_net`) |

### 4.2 Orden de arranque (dependencias)

```
dbs-mariadb (externo) ──► snipe-it
dbs-postgres (externo) ─────┐
zammad-search ───────────────┼─► zammad-init ──► zammad-railsserver ─┐
zammad-redis ────────────────┘                    zammad-scheduler ──┼──► zammad-nginx
zammad-memcached                               zammad-websocket ─┘
dbs-postgres (externo) ──► n8n
```

El orden se garantiza con `depends_on` + healthchecks para `zammad-search`/`redis`/`memcached`; las DBs externas deben existir previamente (`./scripts/init-external-dbs.sh` crea `snipeit`/`zammad_production`/`n8n` + roles antes del primer `docker compose up`). `zammad-init` no crea el rol/DB, solo migra.

### 4.3 Persistencia de datos

| Volumen | Destino en contenedor | Contenido |
|---------|------------------------|-----------|
| `/Volumes/CRGS-1T/Docker/data/mariadb` (externo, host) | `/var/lib/mysql` en `dbs-mariadb` | Datos MariaDB `snipeit` |
| `/Volumes/CRGS-1T/Docker/data/postgres` (externo, host) | `/var/lib/postgresql/data` en `dbs-postgres` | Datos PostgreSQL `zammad_production` + `n8n` |
| `./snipe-data/uploads` (bind) | `/var/www/html/public/uploads` en `snipe-it` | Uploads de activos |
| `./snipe-data/snipeit` (bind) | `/var/lib/snipeit` en `snipe-it` | Datos internos (incl. llaves Passport) |
| `zammad-search-data` (named) | `/usr/share/elasticsearch/data` | Índices Elasticsearch |
| `zammad-var-data` (named) | `/opt/zammad/var` | Archivos internos Zammad |
| `zammad-storage` (named) | `/opt/zammad/storage` | Adjuntos de tickets |
| `zammad-backup` (named) | `/var/tmp/zammad` | Backups generados |
| `n8n-home-data` (named) | `/home/node/.n8n` | Configuración y workflows n8n |

> **Nota técnica:** Elasticsearch, Zammad y n8n corren como uid 1000 y usan *named volumes* porque los bind mounts se crean como root en el host y causan `Permission denied` (EACCES). Docker gestiona el ownership automáticamente con named volumes.

---

## 5. Requisitos de hardware

### 5.1 Recomendado (producción)

| Recurso | Valor |
|---------|-------|
| CPU | **8 vCPU** |
| RAM | **16 GB** |
| Disco | **100 GB SSD** (mínimo; crecer con backups) |
| SO | Ubuntu Server 24.04 LTS (64-bit) |
| Docker | Engine 24+ con plugin Compose v2 |

### 5.2 Mínimo (entorno de pruebas)

| Recurso | Valor |
|---------|-------|
| CPU | 4 vCPU |
| RAM | 8 GB |
| Disco | 60 GB SSD |

### 5.3 Consumo estimado por servicio

| Componente | RAM estimada | Justificación |
|------------|--------------|---------------|
| Elasticsearch (Zammad) | ~2 GB | Heap JVM reservado de 1 GB (`-Xms1g -Xmx1g`) + overhead |
| Zammad app (rails + scheduler + websocket + nginx) | ~3 GB | Múltiples procesos Ruby on Rails |
| PostgreSQL (Zammad) + Redis + Memcached | ~1.5 GB | Bases + cachés |
| Snipe-IT (PHP + Apache) | ~1 GB | Aplicación PHP + procesos |
| MariaDB (Snipe-IT) | ~1 GB | Base de datos |
| n8n + PostgreSQL | ~1.5 GB | Node.js + base |
| SO + Docker (overhead) | ~1 GB | Daemons y kernel |
| **Total** | **~11 GB** | 16 GB recomendados dejan margen para picos y backups |

> Elasticsearch es el componente más sensible a la RAM: con menos de 1 GB de heap degrada el rendimiento de búsqueda de Zammad.

---

## 6. Prerrequisitos

### 6.1 Paquetes del sistema (Ubuntu/Debian)

```bash
# Docker Engine + plugin Compose v2
sudo apt update
sudo apt install -y docker.io docker-compose-v2 git
sudo systemctl enable --now docker
docker --version          # ≥ 24.x
docker compose version    # plugin v2
```

### 6.2 Puertos de red requeridos

| Puerto | Servicio | Nota |
|--------|----------|------|
| `8000` | Zammad | Interfaz web (publicar) |
| `8080` | Snipe-IT | Interfaz web (publicar) |
| `5678` | n8n | Interfaz web (publicar) |
| `3307` | MariaDB (Snipe-IT) | Solo laboratorio; no exponer en producción |
| `5432` | PostgreSQL (n8n) | Solo laboratorio; no exponer en producción |

En producción se recomienda exponer únicamente los puertos web (8000, 8080, 5678) detrás de un reverse proxy con TLS (ver sección 12).

### 6.3 Requisitos del host

- 2 GB libres de disco para las imágenes (la descarga inicial puede superar 1.5 GB).
- Zona horaria del host configurada correctamente (`timedatectl`).
- Acceso de administrador (`sudo`) para ejecutar Docker.
- Para pruebas locales: archivo `/etc/hosts` o DNS con el FQDN que usará cada aplicación.

---

## 7. Despliegue paso a paso

### Paso 1 — Copiar el proyecto al servidor

```bash
# Opción A: clonar el repositorio
git clone <url-del-repositorio> /opt/zammad-snipe

# Opción B: copiar la carpeta
scp -r zammad-snipe usuario@servidor:/opt/zammad-snipe

cd /opt/zammad-snipe
```

### Paso 2 — Revisar y ajustar las variables de entorno

El repo solo trackea plantillas `envs/*.env.example` (sin secretos); los `envs/*.env` reales están ignorados por git (uno por máquina). Créalos antes del primer arranque:

```bash
for f in envs/*.env.example; do cp -n "$f" "${f%.example}"; done
# luego edita cada envs/*.env con passwords/tokens/URLs de este ambiente
```

**En producción se deben cambiar las contraseñas de laboratorio antes del primer arranque.**

| Archivo | Servicio(s) | Contenido |
|---------|-------------|-----------|
| `/Volumes/CRGS-1T/Docker/.env` (externo) | `dbs-postgres`/`dbs-mariadb` | Superusuarios `POSTGRES_PASSWORD`/`MYSQL_ROOT_PASSWORD` (lab: `your_*_here`, ver `*.env.example`) |
| `envs/snipe-db.env(.example)` | referencia para `init-external-dbs.sh` | MariaDB: `snipeit`/`snipe_user` (debe coincidir con `snipe-it.env`) |
| `envs/snipe-it.env(.example)` | `snipe-it` | APP_URL, APP_KEY, conexión DB (`DB_HOST=mariadb` → `dbs-mariadb`), mail |
| `envs/zammad-db.env(.example)` | referencia para `init-external-dbs.sh` | PostgreSQL: `zammad_production`/`zammad_user` (debe coincidir con `zammad-app.env`) |
| `envs/zammad-search.env(.example)` | `zammad-search` | Elasticsearch: single-node, heap |
| `envs/zammad-app.env(.example)` | servicios Zammad | Conexiones PostgreSQL (`POSTGRESQL_HOST=postgres` → `dbs-postgres`), ES, Redis, Memcached |
| `envs/n8n-db.env(.example)` | referencia para `init-external-dbs.sh` | PostgreSQL: `n8n`/`n8n_user` (debe coincidir con `n8n.env`) |
| `envs/n8n.env(.example)` | `n8n` | Timezone, DB (`DB_POSTGRESDB_HOST=postgres` → `dbs-postgres`), entorno |

Ajustes clave en producción:

```bash
# 1) Contraseñas de bases de datos (los valores de laboratorio NO son seguros)
#    - Superusuarios: /Volumes/CRGS-1T/Docker/.env (POSTGRES_PASSWORD, MYSQL_ROOT_PASSWORD)
#    - App users: envs/snipe-it.env / envs/zammad-app.env / envs/n8n.env
#      + envs/snipe-db.env / envs/zammad-db.env / envs/n8n-db.env (referencia, usados por init-external-dbs.sh)
#    Las contraseñas de app (snipe_user/zammad_user/n8n_user) deben coincidir entre el env de la app y la DB creada por init-external-dbs.sh.

# 2) APP_URL de Snipe-IT (envs/snipe-it.env) → apuntar al FQDN o IP de producción
APP_URL=https://snipe.midominio.gob.ec

# 3) Generar un APP_KEY nuevo de Laravel (envs/snipe-it.env)
openssl rand -base64 32   # → pegar como: APP_KEY=base64:<valor>
```

### Paso 3 — Validar la configuración

```bash
docker compose config --quiet   # valida el compose; sin salida = OK
```

### Paso 4 — Levantar toda la infraestructura

```bash
# Prerrequisito externo (una vez, idempotente): crea roles/DBs en dbs-postgres/dbs-mariadb
./scripts/init-external-dbs.sh   # lee POSTGRES_PASSWORD/MYSQL_ROOT_PASSWORD de /Volumes/CRGS-1T/Docker/.env

docker compose up -d
```

Esto levanta los 14 servicios del compose (`snipe-it` + 9 Zammad + `n8n` + 3 infra `search/redis/memcached` + red/volúmenes) más las 2 DBs externas ya corriendo (`dbs-postgres`/`dbs-mariadb`), en el orden de dependencias correcto. El primer arranque descarga las imágenes (varios minutos). Sin `init-external-dbs.sh` previo, `zammad-init` falla con `role does not exist` y `n8n`/`snipe-it` con `Access denied` — no crean el rol/DB, solo migran.

### Paso 5 — Verificar que todo esté sano

```bash
docker compose ps        # estado de todos los servicios
```

Estado esperado: los servicios con healthcheck en `(healthy)` y `zammad-init` en `Exit 0` (termina correctamente tras inicializar la base).

```bash
# Logs de arranque por pila
docker compose logs -f snipe-it
docker compose logs -f zammad-nginx
docker compose logs -f n8n
```

### Paso 6 — Primer arranque de cada aplicación (una sola vez)

| Aplicación | URL | Acción inicial |
|------------|-----|----------------|
| Snipe-IT | `http://<servidor>:8080` | Wizard de instalación: crear cuenta admin, nombre de la organización, idioma |
| Zammad | `http://<servidor>:8000` | Wizard: crear cuenta admin, nombre de la organización, idioma |
| n8n | `http://<servidor>:5678` | Crear cuenta owner (usuario administrador) y contraseña |

> Zammad puede tardar 1–2 minutos en responder la primera vez mientras migra y popula su base de datos. El contenedor `zammad-init` ejecuta las migraciones una sola vez; si se recrea, espera al estado sano de las dependencias y sale con éxito.

### Paso 7 — Provisionar Snipe-IT (categorías, fabricantes, estados y custom fields)

Los seeders de `scripts/` pueblan Snipe-IT vía API una vez que `http://<servidor>:8080` responde. **El orden importa:** el custom field `internal_code` debe existir antes del primer ingest de activos, o el flujo falla a propósito con mensaje accionable (ver §11 y `docs/04` §4.5).

```bash
# 1) Crear token API en Snipe-IT (Admin → Settings → API Tokens) y exportarlo.
#    El token de este ambiente está en envs/n8n.env local (SNIPEIT_TOKEN, ver .env.example).
export SNIPE_URL="http://localhost:8080"
export API_TOKEN="eyJ0..."   # o: export API_TOKEN=$(grep SNIPEIT_TOKEN envs/n8n.env | cut -d= -f2-)

# 2) Seeders base (idempotentes a nivel práctico; duplicados devuelven HTTP 422 sin abortar)
./scripts/snipe-it_categories.sh
./scripts/snipe-it_manufacturer.sh
./scripts/snipe-it_status_labels.sh

# 3) Custom field + fieldset para activos Tryton (idempotente, verifica antes de crear)
./scripts/snipe-it_custom_fields.sh
# Crea: custom field "internal_code" (text, ANY) → db_column _snipeit_internal_code_2
#       fieldset "Activos Tryton" (id 2 esperado, referenciado por models.fieldset_id=2)
#       asociación field → fieldset vía POST /api/v1/fields/{id}/associate
# Si el id no es 2 (p.ej. campo/fieldset borrado antes), el script advierte y explica cómo ajustar
# el payload del workflow (Create/Update snipe-IT asset) o limpiar huérfanos en lab.
```

> **Guarda del workflow:** `Tryton sync snipe-IT assets ingest (batch)` hace pre-flight `GET /api/v1/fields` → `Has internal_code field?` (db_column `_snipeit_internal_code_2`). Si falta, el sub-workflow entra en `Fail: missing custom field` (Stop and Error, ~1 s) con el mensaje `Falta custom field 'internal_code' … Ejecute ./scripts/snipe-it_custom_fields.sh`. Tras el loop, `Has API errors?` (api_errors>0) lleva a `Fail: ingest had API errors` para que la ejecución quede en `error` en n8n en vez de `success` engañoso (caso 2026-09-01: 6314 errores pero 0 assets). Ver `docs/04` §4.5 y spec `.ai/specs/tryton-activos.md`.

---

## 8. Tokens de acceso y usuarios de integración

Los tokens y usuarios de integración conectan los sistemas entre sí (n8n → Snipe-IT, n8n → Tryton, etc.) y **deben ser cuentas de servicio**, no administradores personales.

### 8.1 Snipe-IT — Token API (Bearer)

1. Iniciar sesión como administrador en `http://<servidor>:8080`.
2. Ir a **Admin → Settings → API Tokens**.
3. Clic en **Generate Token**.
4. Copiar el token (un JWT). **Solo se muestra una vez.**
5. Usarlo en las llamadas a la API REST:

```bash
curl -H "Authorization: Bearer <TOKEN>" http://<servidor>:8080/api/v1/categories
```

6. En n8n, registrar el token como credencial **SnipeIT API** (ver 8.3).

Recomendaciones:

- Crear el token desde un **usuario de servicio** de Snipe-IT con permisos mínimos (solo los módulos que la integración requiere), no desde el admin.
- Los tokens dependen de las llaves RSA de Laravel Passport (`oauth-*.key`) que viven en `./snipe-data/snipeit/keys/`. **Si ese volumen se pierde, todos los API tokens quedan inválidos** (respuestas `500 Invalid key supplied`) y hay que regenerarlos. El volumen es parte crítica del backup.

### 8.2 Zammad — Token de API

1. Crear el usuario de integración: **Admin → Usuarios → Nuevo usuario** con rol restringido (p. ej. solo lectura de tickets y usuarios).
2. Con el usuario de integración logueado: avatar (menú de usuario) → **Token Access** → crear un token con los permisos necesarios (p. ej. `ticket.read`, `user.read`).
3. Usarlo en las llamadas a la API:

```bash
curl -H "Authorization: Token token=<TOKEN>" http://<servidor>:8000/api/v1/tickets
```

> El token se muestra una sola vez al crearlo; guardarlo directamente en la credencial de n8n.

### 8.3 n8n — Credenciales de integración

n8n guarda las credenciales **cifradas** con una clave propia. **Se debe definir antes del primer arranque**, porque si se agrega después, las credenciales ya guardadas no podrán descifrarse.

1. Generar la clave de cifrado:

```bash
openssl rand -hex 16
```

2. Agregarla en `envs/n8n.env`:

```bash
N8N_ENCRYPTION_KEY=<valor-generado>
```

3. Reiniciar n8n y crear las credenciales en **Credencials → Add credential**:

| Credencial | Tipo | Contenido |
|------------|------|-----------|
| Snipe-IT | SnipeIT API | URL (`http://snipe-it:80` desde n8n) + token Bearer |
| Zammad | HTTP Request (auth token) | Header `Authorization: Token token=...` |
| Tryton | HTTP Request (header custom) | Header `Authorization: Session <base64(...)>` (ver 8.4) |

### 8.4 Tryton — Usuario de servicio `svc_n8n`

| Campo | Valor |
|-------|-------|
| Usuario | `svc_n8n` |
| Grupo | `integracion_n8n` |
| Permisos | Solo lectura (activos, empleados, terceros) |
| Autenticación | Sesión JSON-RPC (`Authorization: Session <base64(user:uid:session)>`) |

Procedimiento de creación (detalle completo en `docs/01-tryton-usuario-permisos.md`):

1. En Tryton: **Administración → Usuarios → Grupos** → crear grupo `integracion_n8n` con permisos **solo lectura (R)** sobre: `asset`, `asset.category`, `asset.depreciation.line`, `company.employee`, `company.department`, `party.party`, `party.address`, `party.contact_mechanism`.
2. **Administración → Usuarios → Usuarios** → crear usuario `svc_n8n`, asignar al grupo `integracion_n8n` y definir su contraseña.
3. La autenticación es **por sesión** (el endpoint JSON-RPC de Tryton no acepta bearer tokens): login con `common.db.login`, luego cada request autenticado lleva el header de sesión. Protocolo completo en `docs/02-tryton-protocolo-jsonrpc.md`.

```bash
# Verificación del login (devuelve [uid, session_token])
curl -X POST "http://<tryton_host>:8000/<database>/" \
  -H "Content-Type: application/json" \
  -d '{"id": 0, "method": "common.db.login",
       "params": ["svc_n8n", {"password": "<pass>", "device_cookie": null}, "es"]}'
```

> **Rate limit:** el servidor de producción Tryton tiene rate limit agresivo (bloqueos largos). Respetar máximo 1 request cada 3 segundos.

---

## 9. Operación diaria

### 9.1 Comandos de uso frecuente

```bash
# Estado de todos los servicios
docker compose ps

# Logs en vivo de una pila
docker compose logs -f zammad-nginx        # Zammad
docker compose logs -f snipe-it            # Snipe-IT
docker compose logs -f n8n                 # n8n

# Reiniciar un servicio específico
docker compose restart n8n

# Detener/levantar todo
docker compose stop
docker compose start
```

### 9.2 Mantenimiento de Zammad

```bash
# Aplicar migraciones pendientes / reiniciar el railsserver
docker compose exec zammad-railsserver zammad run rails db:migrate
docker compose restart zammad-railsserver
```

### 9.3 Sincronización Tryton → Snipe-IT (incremental)

Desde 2026-09-06 el orquestador (`Tryton sync snipe-IT assets orchestrator v2`) es **incremental**: `Get last sync` lee `MAX(finished_at) - 2h` de `tryton_snipe_run_summary` y `Search assets` / `Read Owned Assets` filtran `OR(write_date, create_date) >= since`. Sin cambios, el run completo tarda segundos (7.5s medidos) y `Run summary` registra `total_tryton=0`. Con `Has assets?` se saltan los sub-workflows de catálogos cuando no hay filas.

- **Operación normal:** programar el orquestador a diario en horario nocturno (ej. 02:00, trigger Schedule en n8n). Solo los deltas generan llamadas a Snipe-IT (techo 50/min por el throttle 1/1200ms).
- **Full semanal:** una vez por semana (ej. domingo) forzar barrido completo para recalcular `deleted_in_tryton` (el incremental lo reporta en 0) y reconciliar derivas: fijar `TRYTON_FULL_SYNC=true` en `envs/n8n.env`, recrear n8n (`docker compose up -d n8n`), ejecutar el orquestador, y volver a `false` + recrear. Un full de 9518 assets tarda ~3.2h por el cap de Snipe-IT.
- **Primera ejecución** (tabla `tryton_snipe_run_summary` vacía): hace full automáticamente.

### 9.3 Actualización de versiones

Al publicar una nueva versión oficial de un vendor:

1. Cambiar la etiqueta de la imagen en `docker-compose.yml` (ej. `ghcr.io/zammad/zammad:7.1.1-0000` → `7.2.x`).
2. **Respaldar antes** (ver sección 10).
3. Recrear los servicios:

```bash
docker compose pull
docker compose up -d
```

> Consultar las guías de actualización del vendor antes de saltar de versión mayor. Las imágenes oficiales de Zammad ejecutan las migraciones de BD automáticamente en el arranque (`zammad-init`).

---

## 10. Backups y restauración

### 10.1 Qué respaldar

| Componente | Ubicación | Método |
|------------|-----------|--------|
| Snipe-IT (DB + uploads + llaves Passport) | `/Volumes/CRGS-1T/Docker/data/mariadb` + `./snipe-data/uploads` + `./snipe-data/snipeit` | `mariadb-dump` desde `dbs-mariadb` + copia de bind mounts |
| Zammad (DB + adjuntos) | `/Volumes/CRGS-1T/Docker/data/postgres` (`zammad_production`) + `zammad-storage` | `zammad-backup` o `pg_dump` desde `dbs-postgres` |
| n8n (DB + config/workflows) | `/Volumes/CRGS-1T/Docker/data/postgres` (`n8n`) + `n8n-home-data` | `pg_dump` desde `dbs-postgres` + copia de volume |

### 10.2 Backup automático de Zammad

El stack incluye el servicio `zammad-backup` (imagen oficial, corre como root), que ejecuta el backup de la base de datos y del storage en el volume named `zammad-backup` (`/var/tmp/zammad`). Los backups generados deben copiarse periódicamente fuera del host (NFS, S3, otro servidor):

```bash
# Listar backups generados
docker run --rm -v zammad-snipe_zammad-backup:/backup alpine ls -la /backup
```

### 10.3 Dumps manuales de bases de datos (DBs externas `dbs-*` en red `docker_net`)

```bash
# Snipe-IT (MariaDB en dbs-mariadb)
docker exec dbs-mariadb mariadb-dump -u snipe_user -p'your_snipe_password_here' snipeit > snipeit_$(date +%F).sql  # ver envs/snipe-db.env

# Zammad (PostgreSQL en dbs-postgres)
docker exec dbs-postgres pg_dump -U zammad_user zammad_production > zammad_$(date +%F).sql

# n8n (PostgreSQL en dbs-postgres)
docker exec dbs-postgres pg_dump -U n8n_user n8n > n8n_$(date +%F).sql
```

> Los nombres de contenedor pueden variar; verificar con `docker compose ps`.

### 10.4 Restauración

Para restaurar el stack completo: detener servicios (`docker compose stop`), restaurar los archivos de los volúmenes o importar los dumps, y volver a levantar. **Regla crítica:** si se restaura `./snipe-data/` parcialmente (por ejemplo solo la BD sin la carpeta `keys/`), los API tokens de Snipe-IT quedarán inválidos; restaurar siempre el árbol completo.

---

## 11. Integración con Tryton (resumen)

El stack incluye una integración documentada y operativa entre el ERP **Tryton** y **Snipe-IT** vía **n8n**, que extrae los activos de informática del ERP y los sincroniza en Snipe-IT.

- **Workflows n8n:** `flows/` contiene los 5 workflows (`Tryton login` en `flows/tryton/`, `Tryton sync categories`, `Tryton sync models`, `Tryton sync statuses`, `Tryton sync assets`) — importables en n8n (Workflows → Import).
- **Protocolo JSON-RPC de Tryton:** autenticación por sesión (`Authorization: Session <base64(user:uid:session)>`), método `model.asset.search_read`, ~19,339 activos (~9,565 de informática). Detalle en `docs/02-tryton-protocolo-jsonrpc.md`.
- **Usuario/permisos:** `svc_n8n` (grupo `integracion_n8n`, solo lectura). Detalle en `docs/01-tryton-usuario-permisos.md`.
- **Specs:** `.ai/specs/tryton-activos.md` (arquitectura, contratos de los 5 workflows, tablas de mapeo, errores conocidos).

> Para el despliegue de esta integración en el nuevo ambiente: crear el usuario de servicio en Tryton (sección 8.4), importar los workflows en n8n, configurar las credenciales (8.3) y validar el rate limit del servidor de producción.

---

## 12. Notas de producción

Este repositorio es un **entorno de laboratorio** y requiere ajustes antes de producción:

1. **Cambiar todas las contraseñas** de `envs/*.env` locales (creados desde `*.env.example`; los valores de laboratorio nunca se commitean). Regenerar también `APP_KEY` de Snipe-IT.
2. **TLS / reverse proxy:** exponer solo los puertos 8000, 8080 y 5678 detrás de un reverse proxy (Caddy, Nginx, Traefik) con certificado TLS. Actualizar `APP_URL` (Snipe-IT) y el hostname público (Zammad) para que los enlaces se generen con HTTPS.
3. **No exponer las bases de datos:** quitar los puertos `3307` y `5432` del `docker-compose.yml` en producción (los servicios internos se comunican por la red `net`).
4. **Mail saliente:** el laboratorio usa `MAIL_MAILER=log` (no envía correos). Configurar un SMTP real en `envs/snipe-it.env` (local, ver `.example`) y en Zammad (Admin → Channels → Email).
5. **n8n task runners (opcional pero recomendado):** descomentar el servicio `n8n-runner` y las variables `N8N_RUNNERS_*` comentadas en el compose y en `envs/n8n.env` (local, ver `.example`) para ejecutar código JS/Python aislado.
6. **Elasticsearch:** en producción habilitar `xpack.security.enabled=true` y proteger el puerto 9200 (actualmente `false`/sin autenticación).
7. **Zona horaria:** `GENERIC_TIMEZONE=America/Guayaquil` (n8n) y zona del host correcta.
8. **Monitorización:** configurar alertas de disco/RAM (los 16 GB recomendados no incluyen crecimiento de backups) y verificar los healthchecks del stack (`docker compose ps`).
9. **Registro de imágenes con tag fijo:** en producción, fijar versiones exactas (ej. `zammad:7.1.1-0000` en vez de `snipe-it:latest-alpine`) para reproducibilidad; el tag `latest` se cambia deliberadamente con control de cambios.
