#!/usr/bin/env bash
# init-external-dbs.sh — Crea bases de datos y usuarios en contenedores Docker externos
#
# Contenedores esperados:
#   docker-mariadb-1  (red docker_net, alias "mariadb")  → Snipe-IT
#   docker-postgres-1 (red docker_net, alias "postgres") → Zammad + n8n
#
# Uso: ./scripts/init-external-dbs.sh
# Ejecutar ANTES de docker compose up por primera vez.

set -euo pipefail

MARIA_CONT="docker-mariadb-1"
POSTGRES_CONT="docker-postgres-1"

# Lee secretos desde /Volumes/CRGS-1T/Docker/.env si existe; fallback solo placeholder (reemplazar en local)
if [[ -f "/Volumes/CRGS-1T/Docker/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "/Volumes/CRGS-1T/Docker/.env"; set +a
fi
MARIA_ROOT_PASS="${MYSQL_ROOT_PASSWORD:-your_mysql_root_password_here}"
PG_USER="postgres"
PG_PASS="${POSTGRES_PASSWORD:-your_postgres_password_here}"

# Snipe-IT (MariaDB)
SNIPE_DB="snipeit"
SNIPE_USER="snipe_user"
SNIPE_PASS="${SNIPE_PASSWORD:-your_snipe_password_here}"

# Zammad (PostgreSQL)
ZAMMAD_DB="zammad_production"
ZAMMAD_USER="zammad_user"
ZAMMAD_PASS="${ZAMMAD_PASSWORD:-your_zammad_password_here}"

# n8n (PostgreSQL)
N8N_DB="n8n"
N8N_USER="n8n_user"
N8N_PASS="${N8N_PASSWORD:-your_n8n_password_here}"

echo "=== Inicializando bases de datos en contenedores externos ==="

# ---------- MariaDB (Snipe-IT) ----------
echo ""
echo "--- MariaDB: creando DB '${SNIPE_DB}' y usuario '${SNIPE_USER}' ---"

docker exec "$MARIA_CONT" mariadb -uroot -p"$MARIA_ROOT_PASS" -e "
  CREATE DATABASE IF NOT EXISTS \`${SNIPE_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER IF NOT EXISTS '${SNIPE_USER}'@'%' IDENTIFIED BY '${SNIPE_PASS}';
  GRANT ALL PRIVILEGES ON \`${SNIPE_DB}\`.* TO '${SNIPE_USER}'@'%';
  FLUSH PRIVILEGES;
" && echo "  ✓ MariaDB listo" || echo "  ✗ Error en MariaDB"

# ---------- PostgreSQL (Zammad) ----------
echo ""
echo "--- PostgreSQL: creando DB '${ZAMMAD_DB}' y usuario '${ZAMMAD_USER}' ---"

docker exec "$POSTGRES_CONT" psql -U "$PG_USER" -tc "SELECT 1 FROM pg_roles WHERE rolname='${ZAMMAD_USER}'" | grep -q 1 || \
  docker exec "$POSTGRES_CONT" psql -U "$PG_USER" -c "
    CREATE USER ${ZAMMAD_USER} WITH PASSWORD '${ZAMMAD_PASS}' CREATEDB;
  "
# Asegurar CREATEDB si el usuario ya existía sin el privilegio
docker exec "$POSTGRES_CONT" psql -U "$PG_USER" -c "ALTER USER ${ZAMMAD_USER} CREATEDB;"

docker exec "$POSTGRES_CONT" psql -U "$PG_USER" -tc "SELECT 1 FROM pg_database WHERE datname='${ZAMMAD_DB}'" | grep -q 1 || \
docker exec "$POSTGRES_CONT" psql -U "$PG_USER" -c "CREATE DATABASE ${ZAMMAD_DB} OWNER ${ZAMMAD_USER};"
docker exec "$POSTGRES_CONT" psql -U "$PG_USER" -d "${ZAMMAD_DB}" -c "GRANT ALL PRIVILEGES ON DATABASE ${ZAMMAD_DB} TO ${ZAMMAD_USER};"

echo "  ✓ Zammad DB listo"

# ---------- PostgreSQL (n8n) ----------
echo ""
echo "--- PostgreSQL: creando DB '${N8N_DB}' y usuario '${N8N_USER}' ---"

docker exec "$POSTGRES_CONT" psql -U "$PG_USER" -tc "SELECT 1 FROM pg_roles WHERE rolname='${N8N_USER}'" | grep -q 1 || \
  docker exec "$POSTGRES_CONT" psql -U "$PG_USER" -c "
    CREATE USER ${N8N_USER} WITH PASSWORD '${N8N_PASS}';
  "

docker exec "$POSTGRES_CONT" psql -U "$PG_USER" -tc "SELECT 1 FROM pg_database WHERE datname='${N8N_DB}'" | grep -q 1 || \
docker exec "$POSTGRES_CONT" psql -U "$PG_USER" -c "CREATE DATABASE ${N8N_DB} OWNER ${N8N_USER};"
docker exec "$POSTGRES_CONT" psql -U "$PG_USER" -d "${N8N_DB}" -c "GRANT ALL PRIVILEGES ON DATABASE ${N8N_DB} TO ${N8N_USER};"

echo "  ✓ n8n DB listo"

echo ""
echo "=== ¡Bases de datos inicializadas! ==="
echo "Ahora ejecuta: docker compose up -d"
