# AGENTS.md — Instrucciones para Asistentes de Código

## Regla Principal

**Usa Engram como base primaria de conocimiento para ahorrar tokens en tareas agénticas.**

- Al iniciar sesión o tras compactación: `mem_context` primero; antes de abrir `flows/*.json` (2000+ líneas), `sql/`, `docs/04*` o `execution_data`, hacer `mem_search` con 2-3 keywords (ej. `Users Ready timeout`, `Bulk Save DISTINCT ON`, `execution pruning`).
- Tras cada decisión/bugfix/descubrimiento/config: `mem_save` inmediato con formato **What / Why / Where / Learned**, `scope: project`, y `topic_key` estable para upsert (no duplicar).
- Al cerrar o decir "listo": `mem_session_summary` obligatorio con Goal / Instructions / Discoveries / Accomplished / Next Steps / Relevant Files.
- **Prohibición total de secretos:** nunca guardar valores de `TRYTON_PASS`, `SNIPEIT_TOKEN`, `MAIL_TOKEN`, `DB_*_PASSWORD`, llaves Passport ni emails de titulares; referenciar solo por nombre (`envs/n8n.env`, `httpBearerAuth PipxV96bF9YxckC4`).
- Specs canónicos siguen en `.ai/specs/tryton-activos.md` + espejo `docs/04-workflows-sincronizacion.md` (regla raíz `AGENTS.md` intacta); Engram es índice/cache, no sustituto. No guardar runs exitosos sin aprendizaje ni dumps de `execution_data`.

---

## Arquitectura del Stack

Este repositorio contiene un entorno Docker Compose con tres pilas de servicios separadas. Las bases de datos (PostgreSQL y MariaDB) corren en contenedores Docker externos compartidos.

### 1. Snipe-IT — Gestión de Activos (Puerto `8080`)

| Servicio        | Imagen                        | Puerto | Base de datos        |
|-----------------|-------------------------------|--------|----------------------|
| `snipe-it`      | `snipe/snipe-it:latest-alpine` | 8080  | `dbs-mariadb` (externo) |

### 2. Zammad — Mesa de Ayuda (Puerto `8000`)

| Servicio              | Imagen                                              | Puerto | Base de datos        |
|-----------------------|-----------------------------------------------------|--------|----------------------|
| `zammad-search`       | `elasticsearch-wolfi:8.16.0`                        | —      | Elasticsearch        |
| `zammad-redis`        | `redis:7-alpine`                                    | —      | Redis                |
| `zammad-memcached`    | `memcached:1.6.42-alpine`                           | —      | Caché de objetos     |
| `zammad-init`         | `ghcr.io/zammad/zammad:latest`                     | —      | `dbs-postgres` (externo) |
| `zammad-railsserver`  | `ghcr.io/zammad/zammad:latest`                     | —      | —                    |
| `zammad-scheduler`    | `ghcr.io/zammad/zammad:latest`                     | —      | —                    |
| `zammad-websocket`    | `ghcr.io/zammad/zammad:latest`                     | —      | —                    |
| `zammad-nginx`        | `ghcr.io/zammad/zammad:latest`                     | 8000   | —                    |
| `zammad-backup`       | `ghcr.io/zammad/zammad:latest`                     | —      | Backups automáticos  |

### 3. n8n — Automatización (Puerto `5678`)

| Servicio   | Imagen                             | Puerto | Base de datos      |
|------------|------------------------------------|--------|--------------------|
| `n8n`      | `docker.n8n.io/n8nio/n8n`        | 5678   | `dbs-postgres` (externo) |

### Redes

| Red | Tipo | Propósito |
|-----|------|-----------|
| `net` | bridge | Comunicación entre servicios del stack |
| `docker_net` | externa | Conexión con contenedores de DB externos (`dbs-postgres`, `dbs-mariadb`) |

### Bases de Datos Externas

| Contenedor | Puerto | DBs alojadas |
|------------|--------|--------------|
| `dbs-postgres` | `5432` | `zammad_production`, `n8n` |
| `dbs-mariadb` | `3306` | `snipeit` |

> **Nota:** Ejecutar `./scripts/init-external-dbs.sh` una vez antes del primer `docker compose up` para crear las bases de datos y usuarios.

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
| `scripts/init-external-dbs.sh` | Crea bases de datos y usuarios en los contenedores Docker externos (`dbs-postgres`, `dbs-mariadb` en red `docker_net`). Lee el password de superusuario desde `/Volumes/CRGS-1T/Docker/.env` (`POSTGRES_PASSWORD`/`MYSQL_ROOT_PASSWORD`) con fallback `changeme_*`; aliases `postgres`/`mariadb` resuelven a `dbs-*`. Ejecutar una vez antes del primer `docker compose up` (idempotente). |
| `scripts/reset-sync.sh` | Limpia los datos del flujo n8n "Tryton sync assets" para re-ejecutarlo: **paso 0 (LAB ONLY)** borra todos los assets en Snipe-IT (`DELETE FROM assets`, sin FKs entre assets/models/categories/status_labels, no toca usuarios); luego borra modelos, categorías y status labels creados (modelos por su `category_id` del map, status por `snipe_name`) y trunca `tryton_snipe_model_map`, `tryton_snipe_category_map`, `tryton_snipe_status_map`, `staging_tryton_assets`, `tryton_snipe_asset_map`, `tryton_snipe_run_summary`, `staging_titular`, `snipe_titular_map`, `snipe_titular_user_map` e `integration_sync_log` (PostgreSQL de n8n) reiniciando secuencias. DBs en `dbs-postgres`/`dbs-mariadb` (defaults `SNIPE_DB_CONT`/`N8N_DB_CONT`); lee `envs/snipe-db.env` + `envs/n8n-db.env` locales (ver `*.env.example`, aborta con ayuda si faltan); sanitiza `\r` de los `.env` (CRLF). Preserva los 3 status labels built-in (AUTO_INCREMENT a 4), categoría default y users. Uso: `./scripts/reset-sync.sh -y` |
| `scripts/n8n-remap.sh` | Remapea IDs de credenciales y `workflowId` del orquestador en snapshots (`flows/**/*.json`) entre ambientes casa/trabajo para importar sin re-seleccionar a mano: `./scripts/n8n-remap.sh --to trabajo "flows/flujos-dev/Tryton sync snipe-IT status.json"` (salida a `/tmp/n8n-remap/<env>`, no se commitea; `--dry-run`, `--help`/`-h`, `--install` solo brew/macOS, nunca `sudo`). Mapas solo-IDs (sin secretos) en `envs/n8n-creds.example.json` / `envs/n8n-workflows.example.json` como plantilla; los reales `envs/n8n-{creds,workflows}.{casa,trabajo}.json` están ignorados por git (cada máquina guarda los suyos). Credenciales (`postgres` → `pg_n8n`, salvo `Query Active Employees` → `pg_tryton`; `httpBearerAuth` → `bearer_snipe`) + fase 3 `workflowIds` (6 `Execute` del orquestador por nombre exacto de nodo → id del sub-workflow destino, actualiza `value`/`cachedResultUrl`/`cachedResultName`; conteo `wf:N`, validación `wf_fuera:0` en push). Modo `push` publica al n8n vivo por DB directa (`UPDATE workflow_entity` + `INSERT workflow_history` primero por FK `activeVersionId` + bump `versionId`; backup a `/tmp/n8n-push/<env>`, confirmación salvo `--yes`, `--restart` con espera a `/healthz`): `./scripts/n8n-remap.sh push --to trabajo --dry-run flows/...` Mapas lógico→live-ID en `envs/n8n-workflows.casa.json` / `n8n-workflows.trabajo.json` (locales, ignorados, incluyen `orchestrator`: casa `BFfvossXQY8Ck5zh`, trabajo `3hh7DBsrq8A1rIQg`); se niega si el live-ID no existe, el nombre no coincide o está archivado. Fix 2026-09-07: el duplicado `Tryton sync snipe-IT status 1OYIdFnCkg9YJgrP` (3 PG a credencial Tryton) archivado (`isArchived=true`, reversible); canónico `DFYH9aXY2QE6uJzl` republicado vía push. Fix 2026-09-07 (fase 3): `PFlL1vCJhhGR6qAr` (orquestador con `workflowIds` mezclados casa/trabajo) archivado; `3hh7DBsrq8A1rIQg` (v2 batch, 6 IDs trabajo) renombrado al nombre canónico y actualizado vía push al snapshot incremental (22 nodos, `tryton_snipe_run_summary`). Fix 2026-09-07 (v1.2.1, rename snipe-IT): flujo `users` → `Tryton sync snipe-IT users assets` y nodo `Execute Tryton sync snipe-IT users assets` (mapa `NODOS_WF` actualizado; el push valida por nombre y se niega si el vivo aún tiene el viejo). |

> **Nota Passport Snipe-IT:** las llaves RSA de Laravel Passport (`oauth-*.key`) viven en `./snipe-data/snipeit/keys/` (bind mount desde `docker-compose.yml`). Si el contenedor se recrea sin ese volumen, toda la API responde 500 `Invalid key supplied`. Si el volumen se regenera con `php artisan passport:keys` como root, corregir permisos con `chown apache:apache /var/lib/snipeit/keys/*`. Los API tokens quedan inválidos tras regenerar llaves (regenerarlos en Admin → API Tokens y actualizar la credencial `Bearer Auth account` / `httpBearerAuth` id `PipxV96bF9YxckC4` en n8n).

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
| `./snipe-data/uploads`           | `/var/www/html/public/uploads`              | Uploads de activos                 |
| `./snipe-data/snipeit`           | `/var/lib/snipeit`                          | Datos internos Snipe-IT (llaves Passport) |

> **Nota:** Elasticsearch, Zammad y n8n corren como uid 1000 y usan named volumes para evitar problemas de permisos (los bind mounts se crean como root → `Permission denied`/`EACCES`). Docker gestiona el ownership automáticamente con named volumes.

> **Nota DBs externas:** Los datos de bases de datos viven en los contenedores externos (`dbs-postgres`, `dbs-mariadb` en red `docker_net` desde `/Volumes/CRGS-1T/Docker/docker-compose.yml`), no en este compose. Volumenes en `/Volumes/CRGS-1T/Docker/data/postgres` y `/data/mariadb`.

---

## Credenciales (Entorno de Laboratorio)

> **⚠ No usar en producción.** Estas credenciales son únicamente para el entorno de laboratorio local.

Los secretos reales viven en archivos **`envs/*.env` locales, ignorados por git**. El repo solo trackea plantillas **`envs/*.env.example`** (sin secretos) + `envs/n8n-{creds,workflows}.example.json`. El `docker-compose.yml` los referencia con `env_file:` (lee los `.env` reales).

Setup en cada máquina (casa/trabajo):

```bash
cp envs/n8n.env.example envs/n8n.env
cp envs/snipe-it.env.example envs/snipe-it.env
cp envs/zammad-app.env.example envs/zammad-app.env
cp envs/zammad-search.env.example envs/zammad-search.env
cp envs/snipe-db.env.example envs/snipe-db.env
cp envs/zammad-db.env.example envs/zammad-db.env
cp envs/n8n-db.env.example envs/n8n-db.env
# luego edita passwords/tokens/URLs por ambiente
```

> **Nota historial 2026-09-07:** los `*.env` con secretos se des-trackearon (`git rm --cached` + `.gitignore`) y el historial se purgó con `filter-repo`; si tu clon aún los muestra trackeados, re-clona y rota secretos.

### Contenedores externos (DBs)

| Contenedor | Credenciales (definidas en `/Volumes/CRGS-1T/Docker/.env`) |
|------------|--------------|
| `dbs-postgres` (`postgres`) | User: `postgres`, Password: `POSTGRES_PASSWORD` (lab: `changeme_root_pg`) |
| `dbs-mariadb` (`mariadb`) | Root: `MYSQL_ROOT_PASSWORD` (lab: `changeme_root`) |

### Archivos .env del compose (plantilla `.env.example` en git, real `.env` local ignorado)

| Archivo | Servicio(s) | Contenido |
|---------|------------|-----------|
| `envs/snipe-it.env(.example)` | `snipe-it` | App URL, APP_KEY, DB connection (`DB_HOST=mariadb`), mail config, API throttle (`API_THROTTLE_PER_MINUTE=600`, default vendor 120; aplicar con `php artisan config:cache`) |
| `envs/zammad-search.env(.example)` | `zammad-search` | Elasticsearch: single-node, xpack, JVM heap |
| `envs/zammad-app.env(.example)` | `zammad-init`, `zammad-railsserver`, `zammad-scheduler`, `zammad-websocket`, `zammad-nginx`, `zammad-backup` | PostgreSQL (`POSTGRESQL_HOST=postgres`), Elasticsearch, Redis, Memcached connection |
| `envs/n8n.env(.example)` | `n8n` | Timezone, NODE_ENV, DB connection (`DB_POSTGRESDB_HOST=postgres`, `DB_POSTGRESDB_POOL_SIZE=10`), Tryton connection (`TRYTON_URL`, `TRYTON_DB`, `TRYTON_USER`, `TRYTON_PASS`), Mail notifications (`MAIL_FROM`, `MAIL_TO`, `MAIL_TOKEN`), Runner limits (`N8N_RUNNERS_MAX_OLD_SPACE_SIZE=4096`, `N8N_RUNNERS_TASK_TIMEOUT=3600`), Pruning (`EXECUTIONS_DATA_PRUNE=true`, `MAX_AGE=168h`, `MAX_COUNT=500`) |

### Archivos .env de DBs (plantilla en git, real local ignorado; referenciados por init-external-dbs.sh)

| Archivo | Contenido |
|---------|-----------|
| `envs/snipe-db.env(.example)` | MariaDB: root password, DB name, user/password |
| `envs/zammad-db.env(.example)` | PostgreSQL: user/password, DB name |
| `envs/n8n-db.env(.example)` | PostgreSQL: user/password, DB name |

Cámbialo antes de producción.

---

## Puntos Clave

- Las bases de datos corren en contenedores externos compartidos (`dbs-postgres`, `dbs-mariadb` con alias `postgres`/`mariadb` en red `docker_net` desde `/Volumes/CRGS-1T/Docker/docker-compose.yml`).
- Ejecutar `./scripts/init-external-dbs.sh` antes del primer `docker compose up` (lee `POSTGRES_PASSWORD`/`MYSQL_ROOT_PASSWORD` de `/Volumes/CRGS-1T/Docker/.env`).
- Snipe-IT se conecta a `mariadb` (alias de `dbs-mariadb`, red `docker_net`).
- Zammad y n8n se conectan a `postgres` (alias de `dbs-postgres`, red `docker_net`).
- Zammad tiene una cadena de dependencias: `zammad-search` + `zammad-redis` + `zammad-memcached` → `zammad-init` → `zammad-railsserver` / `zammad-scheduler` / `zammad-websocket` → `zammad-nginx`.
- Elasticsearch arranca con `xpack.security.enabled=false` y 1GB de heap (`-Xms1g -Xmx1g`).
- La zona horaria de n8n está configurada a `America/Guayaquil`.
- Task runner JS sin `N8N_RUNNERS_TASK_TIMEOUT` usa 300 s por defecto (n8n 2.36.7 `TaskBroker.handleTaskTimeout`); con titular-activo el fan-out `Create Snipe User` → `Users Ready` lo supera. Fix 2026-09-03: `N8N_RUNNERS_TASK_TIMEOUT=3600` en `envs/n8n.env` (igual que `executionTimeout:3600` del workflow).
- `execution_data` con `jsonSizeBytes` 35 MB (1497) + 197 `rejected by Runner` + 14 `timeout exceeded when trying to connect` colgaban UI y host. Fix 2026-09-03: `EXECUTIONS_DATA_PRUNE=true`, `MAX_AGE=168`, `MAX_COUNT=500`, `PRUNE_HARD_DELETE_INTERVAL=15`, `PRUNE_INTERVAL=60`, `DB_POSTGRESDB_POOL_SIZE=5` en `envs/n8n.env` (subido a 10 el 2026-09-05 con la unificación de throttle 1/1200); poda manual `DELETE FROM execution_data WHERE octet_length(data::text)>5MB` (36→152 kB) + `VACUUM`. Sin esto el navegador intenta renderizar 35 MB y el pool PG se satura.
- El manual de implementación para producción está en `docs/manual-implementacion.md` (hardware, despliegue, tokens de integración, backups).
- Para volver a usar las DBs internas del compose, ver `.ai/specs/external-databases.md`.

---

## Integración Tryton (n8n)

### Specs

Los specs de integración están en `.ai/specs/`:

| Archivo | Descripción |
|---------|-------------|
| `.ai/specs/tryton-activos.md` | Spec canónico de sincronización Tryton → Snipe-IT: arquitectura de los 6 workflows, contratos, tablas de mapeo, errores conocidos |
| `.ai/specs/external-databases.md` | Configuración de bases de datos externas: contenedores, credenciales, DBs/usuarios creados, paso a paso para volver a DBs internas |

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
