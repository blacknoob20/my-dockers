# AGENTS.md — Instrucciones para Asistentes de Código

## Regla Principal

**NO guardar nada en Engram.** Este proyecto no utiliza memoria persistente. No ejecutes `mem_save`, `mem_session_summary`, ni ninguna otra herramienta de engram bajo ninguna circunstancia.

---

## Arquitectura del Stack

Este repositorio contiene un entorno Docker Compose con tres pilas de servicios separadas:

### 1. Snipe-IT — Gestión de Activos (Puerto `8080`)

| Servicio        | Imagen                        | Puerto | Base de datos        |
|-----------------|-------------------------------|--------|----------------------|
| `snipe-db`      | `mariadb:10.11`              | —      | MySQL (snipeit)      |
| `snipe-it`      | `snipe/snipe-it:latest-alpine` | 8080  | Conecta a `snipe-db` |

### 2. Zammad — Mesa de Ayuda (Puerto `8000`)

| Servicio              | Imagen                                              | Puerto | Base de datos        |
|-----------------------|-----------------------------------------------------|--------|----------------------|
| `zammad-db`           | `postgres:15-alpine`                                | —      | PostgreSQL (zammad)  |
| `zammad-search`       | `elasticsearch-wolfi:8.16.0`                        | —      | Elasticsearch        |
| `zammad-redis`        | `redis:7-alpine`                                    | —      | Redis                |
| `zammad-init`         | `zammad/zammad:6.2.0-28`                           | —      | —                    |
| `zammad-railsserver`  | `zammad/zammad:6.2.0-28`                           | —      | —                    |
| `zammad-scheduler`    | `zammad/zammad:6.2.0-28`                           | —      | —                    |
| `zammad-websocket`    | `zammad/zammad:6.2.0-28`                           | —      | —                    |
| `zammad-nginx`        | `zammad/zammad:6.2.0-28`                           | 8000   | —                    |

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

Los scripts son idempotentes a nivel práctico: si el registro ya existe, la API retorna un error HTTP que el script imprime sin abortar el resto.

---

## Volúmenes

| Ruta local                       | Contenedor destino                          | Propósito                          |
|----------------------------------|---------------------------------------------|------------------------------------|
| `./snipe-data/db`                | `/var/lib/mysql` (MariaDB)                  | Datos Snipe-IT                     |
| `./snipe-data/uploads`           | `/var/www/html/public/uploads`              | Uploads de activos                 |
| `./zammad-data/db`               | `/var/lib/postgresql/data`                  | Datos Zammad                       |
| `./zammad-data/search`           | `/usr/share/elasticsearch/data`             | Índices Elasticsearch              |
| `./zammad-data/zammad-var`       | `/opt/zammad/var`                           | Archivos internos Zammad           |
| `./n8n-data/db`                  | `/var/lib/postgresql/data`                  | Datos n8n                          |
| `./n8n-data/home`                | `/home/node/.n8n`                           | Configuración n8n                  |

---

## Credenciales (Entorno de Laboratorio)

> **⚠ No usar en producción.** Estas credenciales son únicamente para el entorno de laboratorio local.

| Servicio   | Usuario / DB         | Contraseña                |
|------------|----------------------|---------------------------|
| MariaDB    | `snipe_user`         | `snipe_password_123`      |
| PostgreSQL (Zammad) | `zammad_user` | `zammad_password_123` |
| PostgreSQL (n8n) | `n8n_user`     | `n8n_password_123`        |

El `APP_KEY` de Snipe-IT está hardcodeado en el compose; cámbialo antes de producción.

---

## Puntos Clave

- Snipe-IT depende de que `snipe-db` esté sano (`service_healthy`).
- Zammad tiene una cadena de dependencias: `zammad-db` → `zammad-search` + `zammad-redis` → `zammad-init` → `zammad-railsserver` / `zammad-scheduler` / `zammad-websocket` → `zammad-nginx`.
- n8n depende de que `n8n-db` esté sano.
- Elasticsearch arranca con `xpack.security.enabled=false` y 1GB de heap (`-Xms1g -Xmx1g`).
- La zona horaria de n8n está configurada a `America/Guayaquil`.
