# Spec: Bases de Datos Externas

## Contexto

El stack zammad-snipeit original definía sus propios contenedores de bases de datos (`snipe-db`, `zammad-db`, `n8n-db`). Para consolidar infraestructura, se migraron a contenedores Docker externos pre-existentes.

## Contenedores Externos

| Contenedor | Imagen | Puerto | Red | Alias DNS |
|------------|--------|--------|-----|-----------|
| `docker-postgres-1` | `postgres:17-alpine` | `5432:5432` | `docker_net` | `postgres`, `docker-postgres-1` |
| `docker-mariadb-1` | `mariadb:10.11` | `3306:3306` | `docker_net` | `mariadb`, `docker-mariadb-1` |

## Credenciales de los Contenedores Externos

| Contenedor | Variable | Valor |
|------------|----------|-------|
| `docker-postgres-1` | `POSTGRES_PASSWORD` | `postgres_root_2024` |
| `docker-mariadb-1` | `MYSQL_ROOT_PASSWORD` | `mariadb_root_2024` |

## Bases de Datos y Usuarios Creados

### MariaDB (Snipe-IT)

| Campo | Valor |
|-------|-------|
| DB | `snipeit` |
| User | `snipe_user` |
| Password | `snipe_password_123` |
| Permisos | ALL PRIVILEGES ON `snipeit`.* |

### PostgreSQL (Zammad)

| Campo | Valor |
|-------|-------|
| DB | `zammad_production` |
| User | `zammad_user` |
| Password | `zammad_password_123` |
| Owner | `zammad_user` |

### PostgreSQL (n8n)

| Campo | Valor |
|-------|-------|
| DB | `n8n` |
| User | `n8n_user` |
| Password | `n8n_password_123` |
| Owner | `n8n_user` |

## Archivos Modificados

| Archivo | Cambio |
|---------|--------|
| `docker-compose.yml` | Servicios `snipe-db`, `zammad-db`, `n8n-db` comentados; red `docker_net` agregada como externa |
| `envs/snipe-it.env(.example)` | `DB_HOST=snipe-db` → `DB_HOST=mariadb` |
| `envs/zammad-app.env(.example)` | `POSTGRESQL_HOST=zammad-db` → `POSTGRESQL_HOST=postgres` |
| `envs/n8n.env(.example)` | Agregadas `DB_TYPE=postgresdb`, `DB_POSTGRESDB_HOST=postgres`, `DB_POSTGRESDB_PORT=5432`, `DB_POSTGRESDB_DATABASE=n8n`, `DB_POSTGRESDB_USER=n8n_user`, `DB_POSTGRESDB_PASSWORD=n8n_password_123` |

> **Nota 2026-09-07:** los `envs/*.env` reales están ignorados por git (secretos locales por máquina); el repo trackea solo `*.env.example`.

## Script de Inicialización

`scripts/init-external-dbs.sh` — Crea las bases de datos y usuarios en los contenedores externos. Ejecutar una vez antes del primer `docker compose up`.

```bash
./scripts/init-external-dbs.sh
```

## Red Docker

Los servicios del compose ahora usan dos redes:
- `net` (bridge local) — para comunicación entre servicios del stack
- `docker_net` (externa) — para conexión con contenedores de DB externos

## Para Descomentar las DBs Originales

Si se desea volver a usar las bases de datos internas del compose:

1. Descomentar los servicios `snipe-db`, `zammad-db`, `n8n-db` en `docker-compose.yml`
2. Restaurar `DB_HOST=snipe-db` en `envs/snipe-it.env` local (ver `.env.example`)
3. Restaurar `POSTGRESQL_HOST=zammad-db` en `envs/zammad-app.env` local (ver `.env.example`)
4. Eliminar variables `DB_*` de `envs/n8n.env` local (ver `.env.example`)
5. Restaurar `depends_on` originales de `snipe-it`, `zammad-init`, `zammad-backup`, `n8n`
6. Eliminar `- docker_net` de las listas de networks de cada servicio
7. Eliminar la sección `docker_net:` de networks en `docker-compose.yml`
