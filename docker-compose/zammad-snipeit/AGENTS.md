# AGENTS.md — Instrucciones para Asistentes de Código

## Regla Principal

**NO guardar nada en Engram.** Este proyecto no utiliza memoria persistente. No ejecutes `mem_save`, `mem_session_summary`, ni ninguna otra herramienta de engram bajo ninguna circunstancia.

---

## Arquitectura del Stack

Este repositorio contiene un entorno Docker Compose con tres pilas de servicios separadas:

### 1. Snipe-IT — Gestión de Activos (Puerto `8080`)

| Servicio        | Imagen                        | Puerto | Base de datos        |
|-----------------|-------------------------------|--------|----------------------|
| `snipe-db`      | `mariadb`                    | —      | MySQL (snipeit)      |
| `snipe-it`      | `snipe/snipe-it:latest-alpine` | 8080  | Conecta a `snipe-db` |

### 2. Zammad — Mesa de Ayuda (Puerto `8000`)

| Servicio              | Imagen                                              | Puerto | Base de datos        |
|-----------------------|-----------------------------------------------------|--------|----------------------|
| `zammad-db`           | `postgres:15-alpine`                                | —      | PostgreSQL (zammad)  |
| `zammad-search`       | `elasticsearch-wolfi:8.16.0`                        | —      | Elasticsearch        |
| `zammad-redis`        | `redis:7-alpine`                                    | —      | Redis                |
| `zammad-memcached`    | `memcached:1.6.42-alpine`                           | —      | Caché de objetos     |
| `zammad-init`         | `ghcr.io/zammad/zammad:7.1.1-0000`                 | —      | —                    |
| `zammad-railsserver`  | `ghcr.io/zammad/zammad:7.1.1-0000`                 | —      | —                    |
| `zammad-scheduler`    | `ghcr.io/zammad/zammad:7.1.1-0000`                 | —      | —                    |
| `zammad-websocket`    | `ghcr.io/zammad/zammad:7.1.1-0000`                 | —      | —                    |
| `zammad-nginx`        | `ghcr.io/zammad/zammad:7.1.1-0000`                 | 8000   | —                    |
| `zammad-backup`       | `ghcr.io/zammad/zammad:7.1.1-0000`                 | —      | Backups automáticos  |

### 3. n8n — Automatización (Puerto `5678`)

| Servicio   | Imagen                             | Puerto | Base de datos      |
|------------|------------------------------------|--------|--------------------|
| `n8n-db`   | `postgres:15-alpine`              | —      | PostgreSQL (n8n)   |
| `n8n`      | `docker.n8n.io/n8nio/n8n`        | 5678   | Conecta a `n8n-db` |

Todas las redes usan un bridge llamado `net`.

---

## Archivos `.sh` — Seeders de Snipe-IT

Los scripts `.sh` en la raíz del repositorio son **seeders de datos iniciales** para Snipe-IT. No son servicios ni scripts de infraestructura; se ejecutan manualmente contra la API de Snipe-IT una vez que el contenedor `snipe-it` está levantado y accesible en `http://localhost:8080`.

### Cómo funciona cada seeder

| Archivo                      | Qué crea                                                  |
|------------------------------|-----------------------------------------------------------|
| `snipe-it_categories.sh`    | 10 categorías de activos (Computadoras, Laptops, UPS, Switches, etc.) |
| `snipe-it_manufacturer.sh`  | ~35 fabricantes organizados por vertical: red, impresión, telefonía IP, UPS, videovigilancia, servidores, periféricos, biometría |
| `snipe-it_status_labels.sh` | 9 estados de activo con sus tipos (`deployable`, `assigned`, `pending`, `archived`) |

### Formato de los seeders
- Cada script tiene una sección de configuración con `SNIPE_URL` y `API_TOKEN`.
- Los datos están definidos en arrays/associativos de Bash.
- Cada registro se envía vía `curl` POST a la API REST de Snipe-IT (`/api/v1/...`).
- El token API se repite en los tres scripts; al actualizarlo, hay que cambiarlo en todos.

### Ejecución

```bash
./snipe-it_categories.sh
./snipe-it_manufacturer.sh
./snipe-it_status_labels.sh
```

---

## Scripts de operación

| Archivo | Qué hace |
|---------|----------|
| `scripts/reset-sync.sh` | Limpia los datos del flujo n8n "Tryton sync assets" para re-ejecutarlo: borra modelos, categorías y status labels creados en Snipe-IT (MySQL, `models` y `categories`; los modelos se identifican por su `category_id` del map, capturando también huérfanos de corridas fallidas; los status labels por su `snipe_name` en `tryton_snipe_status_map`) y trunca `tryton_snipe_model_map`, `tryton_snipe_category_map`, `tryton_snipe_status_map` e `integration_sync_log` (PostgreSQL de n8n) reiniciando secuencias. Preserva los 3 status labels built-in de Snipe-IT (Pending, Ready to Deploy, Archived; `AUTO_INCREMENT` a 4) y no toca la categoría por defecto, usuarios ni assets. Uso: `./scripts/reset-sync.sh -y` |

> **Nota Passport Snipe-IT:** las llaves RSA de Laravel Passport (`oauth-*.key`) viven en `./snipe-data/snipeit/keys/` (bind mount desde `docker-compose.yml`). Si el contenedor se recrea sin ese volumen, toda la API responde 500 `Invalid key supplied` y los API tokens quedan inválidos (hay que regenerarlos en Admin → API Tokens y actualizar la credencial `SnipeIT Auth Token` en n8n).

Los scripts son idempotentes a nivel práctico: si el registro ya existe, la API retorna un error HTTP que el script imprime sin abortar el resto.

---

## Volúmenes

| Named Volume               | Contenedor destino                          | Propósito                          |
|----------------------------------|---------------------------------------------|------------------------------------|
| `zammad-search-data`             | `/usr/share/elasticsearch/data`             | Índices Elasticsearch              |
| `zammad-var-data`                | `/opt/zammad/var`                           | Archivos internos Zammad           |
| `zammad-storage`                 | `/opt/zammad/storage`                       | Adjuntos de tickets                |
| `zammad-backup`                  | `/var/tmp/zammad`                           | Backups del servicio `zammad-backup` |
| `n8n-home-data`                  | `/home/node/.n8n`                           | Configuración n8n                  |

| Ruta local (bind mount)          | Contenedor destino                          | Propósito                          |
|----------------------------------|---------------------------------------------|------------------------------------|
| `./snipe-data/db`                | `/var/lib/mysql` (MariaDB)                  | Datos Snipe-IT                     |
| `./snipe-data/uploads`           | `/var/www/html/public/uploads`              | Uploads de activos                 |
| `./snipe-data/snipeit`           | `/var/lib/snipeit`                          | Datos internos Snipe-IT (llaves Passport) |
| `./zammad-data/db`               | `/var/lib/postgresql/data`                  | Datos Zammad                       |
| `./n8n-data/db`                  | `/var/lib/postgresql/data`                  | Datos n8n                          |

> **Nota:** Elasticsearch, Zammad y n8n corren como uid 1000 y usan named volumes para evitar problemas de permisos (los bind mounts se crean como root → `Permission denied`/`EACCES`). Docker gestiona el ownership automáticamente con named volumes.

---

## Credenciales (Entorno de Laboratorio)

> **⚠ No usar en producción.** Estas credenciales son únicamente para el entorno de laboratorio local.

Las credenciales y variables de entorno están en archivos **`.env`** por servicio dentro de la carpeta **`envs/`**. El `docker-compose.yml` los referencia con `env_file:`.

| Archivo | Servicio(s) | Contenido |
|---------|------------|-----------|
| `envs/snipe-db.env` | `snipe-db` | MariaDB: root password, DB name, user/password |
| `envs/snipe-it.env` | `snipe-it` | App URL, APP_KEY, DB connection, mail config |
| `envs/zammad-db.env` | `zammad-db` | PostgreSQL: user/password, DB name |
| `envs/zammad-search.env` | `zammad-search` | Elasticsearch: single-node, xpack, JVM heap |
| `envs/zammad-app.env` | `zammad-init`, `zammad-railsserver`, `zammad-scheduler`, `zammad-websocket`, `zammad-nginx`, `zammad-backup` | PostgreSQL, Elasticsearch, Redis, Memcached connection |
| `envs/n8n-db.env` | `n8n-db` | PostgreSQL: user/password, DB name |
| `envs/n8n.env` | `n8n` | Timezone, NODE_ENV (variables `N8N_RUNNERS_*` comentadas, activar solo con `n8n-runner` en producción) |

Cámbialo antes de producción.

---

## Puntos Clave

- Snipe-IT depende de que `snipe-db` esté sano (`service_healthy`).
- Zammad tiene una cadena de dependencias: `zammad-db` → `zammad-search` + `zammad-redis` + `zammad-memcached` → `zammad-init` → `zammad-railsserver` / `zammad-scheduler` / `zammad-websocket` → `zammad-nginx`. El servicio `zammad-backup` depende solo de `zammad-db`.
- n8n depende de que `n8n-db` esté sano.
- Elasticsearch arranca con `xpack.security.enabled=false` y 1GB de heap (`-Xms1g -Xmx1g`).
- La zona horaria de n8n está configurada a `America/Guayaquil`.
- El manual de implementación para producción está en `docs/manual-implementacion.md` (hardware, despliegue, tokens de integración, backups).

---

## Integración Tryton (n8n)

### Specs

Los specs de integración están en `.ai/specs/`:

| Archivo | Descripción |
|---------|-------------|
| `.ai/specs/tryton-activos.md` | Spec canónico de sincronización Tryton → Snipe-IT: arquitectura de los 5 workflows, contratos, tablas de mapeo, errores conocidos |

### Servidor Tryton (producción)

| Campo | Valor |
|-------|-------|
| URL | `https://financieroprueba.guayas.gob.ec` |
| Base de datos | `dbegob2bak` |
| Rate limit | Agresivo (429) — usar con precaución |

### Servidor Tryton (local/lab)

| Campo | Valor |
|-------|-------|
| URL | `http://192.168.56.102:8000` |
| Base de datos | `dbegoblocal` |
| Modelo | `asset` (~19,339 registros) |

### Protocolo JSON-RPC

```
Content-Type: application/json
POST /<database>/
Authorization: Session <base64(user:uid:session)>
```

### Scripts

```bash
# Listar activos desde Tryton
./scripts/tryton-listar-activos.sh
```
