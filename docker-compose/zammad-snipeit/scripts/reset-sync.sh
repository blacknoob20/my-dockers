#!/bin/bash
# ============================================================
# RESET SYNC — Sync Tryton → Snipe-IT
#
# Limpia los datos generados por el flujo n8n "Tryton sync assets"
# para poder re-ejecutarlo y certificar la sincronización:
#
#   1. Snipe-IT (MySQL): borra los MODELOS, CATEGORÍAS y STATUS LABELS
#      creados por el flujo. Los modelos se identifican por su categoría
#      (captura también huérfanos como "NG500", creados por una
#      corrida fallida y no registrados en el map); los status labels
#      por su snipe_name en tryton_snipe_status_map. Preserva los 3
#      status labels built-in (Pending, Ready to Deploy, Archived).
#   2. n8n (PostgreSQL): trunca tryton_snipe_model_map,
#      tryton_snipe_category_map, tryton_snipe_status_map,
#      staging_tryton_assets, tryton_snipe_asset_map,
#      tryton_snipe_run_summary, staging_titular, snipe_titular_map,
#      snipe_titular_user_map e integration_sync_log (reinicia secuencias).
#
# NO toca: usuarios, assets, ni la categoría por defecto (id 1).
#
# Uso:  ./reset-sync.sh [-y]
#       -y  omite la confirmación
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _env in snipe-db.env n8n-db.env; do
  if [[ ! -f "$SCRIPT_DIR/../envs/$_env" ]]; then
    echo "ERROR: falta envs/$_env (ignorado por git). Cópialo desde el ejemplo y edítalo:" >&2
    echo "  cp envs/${_env}.example envs/$_env && nano envs/$_env" >&2
    exit 1
  fi
done
source "$SCRIPT_DIR/../envs/snipe-db.env"
source "$SCRIPT_DIR/../envs/n8n-db.env"

SNIPE_DB_CONT="${SNIPE_DB_CONT:-docker-mariadb-1}"
N8N_DB_CONT="${N8N_DB_CONT:-docker-postgres-1}"

mysql_q() {
  docker exec "$SNIPE_DB_CONT" mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -N -B -e "$1" 2>/dev/null
}
psql_q() {
  docker exec "$N8N_DB_CONT" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c "$1"
}

# ---- Plan ----
CAT_IDS=()
while IFS= read -r id; do
  [[ -n "$id" ]] && CAT_IDS+=("$id")
done < <(psql_q "SELECT DISTINCT snipe_category_id FROM tryton_snipe_category_map WHERE snipe_category_id IS NOT NULL;")

MOD_IDS=()
if [[ ${#CAT_IDS[@]} -gt 0 ]]; then
  ID_LIST=$(IFS=,; echo "${CAT_IDS[*]}")
  while IFS= read -r id; do
    [[ -n "$id" ]] && MOD_IDS+=("$id")
  done < <(mysql_q "SELECT id FROM models WHERE category_id IN ($ID_LIST);")
fi

MAP_MODELS=$(psql_q "SELECT COUNT(*) FROM tryton_snipe_model_map;")
MAP_CATS=$(psql_q "SELECT COUNT(*) FROM tryton_snipe_category_map;")
LOG_COUNT=$(psql_q "SELECT COUNT(*) FROM integration_sync_log;")
STAGING_COUNT=$(psql_q "SELECT COUNT(*) FROM staging_tryton_assets;")
MAP_ASSETS=$(psql_q "SELECT COUNT(*) FROM tryton_snipe_asset_map;")
SUMMARY_COUNT=$(psql_q "SELECT COUNT(*) FROM tryton_snipe_run_summary;")
STAGING_TITULAR_COUNT=$(psql_q "SELECT COUNT(*) FROM staging_titular;")
MAP_TITULAR_COUNT=$(psql_q "SELECT COUNT(*) FROM snipe_titular_map;")
MAP_TITULAR_USER_COUNT=$(psql_q "SELECT COUNT(*) FROM snipe_titular_user_map;")

STATUS_NAMES=()
while IFS= read -r name; do
  [[ -n "$name" ]] && STATUS_NAMES+=("$name")
done < <(psql_q "SELECT DISTINCT snipe_name FROM tryton_snipe_status_map WHERE snipe_name IS NOT NULL;")

STATUS_IDS=()
if [[ ${#STATUS_NAMES[@]} -gt 0 ]]; then
  NAMES_QUOTED=$(printf "'%s'," "${STATUS_NAMES[@]}")
  NAMES_QUOTED="${NAMES_QUOTED%,}"
  while IFS= read -r id; do
    [[ -n "$id" ]] && STATUS_IDS+=("$id")
  done < <(mysql_q "SELECT id FROM status_labels WHERE name IN ($NAMES_QUOTED);")
fi

MAP_STATUS=$(psql_q "SELECT COUNT(*) FROM tryton_snipe_status_map;")

echo "==> Plan de limpieza:"
echo "    - Snipe-IT:  $((${#MOD_IDS[@]})) modelo(s) a borrar       [${MOD_IDS[*]:-ninguno}]"
echo "    - Snipe-IT:  $((${#CAT_IDS[@]})) categoría(s) a borrar    [${CAT_IDS[*]:-ninguna}]"
echo "    - Snipe-IT:  $((${#STATUS_IDS[@]})) status_label(s) a borrar [${STATUS_IDS[*]:-ninguno}]"
echo "    - n8n:       $MAP_MODELS fila(s) en tryton_snipe_model_map"
echo "    - n8n:       $MAP_CATS fila(s) en tryton_snipe_category_map"
echo "    - n8n:       $MAP_STATUS fila(s) en tryton_snipe_status_map"
echo "    - n8n:       $STAGING_COUNT fila(s) en staging_tryton_assets"
echo "    - n8n:       $MAP_ASSETS fila(s) en tryton_snipe_asset_map"
echo "    - n8n:       $SUMMARY_COUNT fila(s) en tryton_snipe_run_summary"
echo "    - n8n:       $STAGING_TITULAR_COUNT fila(s) en staging_titular"
echo "    - n8n:       $MAP_TITULAR_COUNT fila(s) en snipe_titular_map"
echo "    - n8n:       $MAP_TITULAR_USER_COUNT fila(s) en snipe_titular_user_map"
echo "    - n8n:       $LOG_COUNT fila(s) en integration_sync_log"

if [[ "${1:-}" != "-y" ]]; then
  read -r -p "¿Continuar? [s/N] " resp
  [[ "$resp" =~ ^[sSyY]$ ]] || { echo "Cancelado."; exit 0; }
fi

# ---- 0. Snipe-IT (MySQL): assets (LAB ONLY, irreversible, sin respaldo) ----
# Sin este paso el guard de modelos aborta (assets referencian modelos).
ASSET_COUNT=$(mysql_q "SELECT COUNT(*) FROM assets;")
echo "==> Snipe-IT paso 0 (LAB ONLY): $ASSET_COUNT asset(s) a borrar (todos)."
mysql_q "DELETE FROM assets;" >/dev/null
mysql_q "ALTER TABLE assets AUTO_INCREMENT = 1;" >/dev/null
echo "==> Snipe-IT: eliminados de assets -> todos ($ASSET_COUNT); AUTO_INCREMENT reiniciado a 1."
echo "    Assets restantes: $(mysql_q "SELECT COUNT(*) FROM assets;")"

# ---- 1. Snipe-IT (MySQL): modelos ----
if [[ ${#MOD_IDS[@]} -gt 0 ]]; then
  MOD_LIST=$(IFS=,; echo "${MOD_IDS[*]}")
  USED=$(mysql_q "SELECT COUNT(*) FROM assets WHERE model_id IN ($MOD_LIST);")
  if [[ "$USED" != "0" ]]; then
    echo "ERROR: $USED asset(s) usan esos modelos. No se puede borrar." >&2
    exit 1
  fi
  mysql_q "DELETE FROM models WHERE id IN ($MOD_LIST);" >/dev/null
  echo "==> Snipe-IT: eliminados de models -> id $MOD_LIST"
  mysql_q "ALTER TABLE models AUTO_INCREMENT = 1;" >/dev/null
  echo "==> Snipe-IT: AUTO_INCREMENT de models reiniciado a 1"
else
  echo "==> Snipe-IT: nada que borrar en models."
fi

# ---- 2. Snipe-IT (MySQL): categorías ----
if [[ ${#CAT_IDS[@]} -gt 0 ]]; then
  CAT_LIST=$(IFS=,; echo "${CAT_IDS[*]}")
  USED=$(mysql_q "SELECT COUNT(*) FROM models WHERE category_id IN ($CAT_LIST);")
  if [[ "$USED" != "0" ]]; then
    echo "ERROR: $USED modelo(s) usan esas categorías. No se puede borrar." >&2
    exit 1
  fi
  mysql_q "DELETE FROM categories WHERE id IN ($CAT_LIST);" >/dev/null
  echo "==> Snipe-IT: eliminadas de categories -> id $CAT_LIST"
  # id 1 = "Misc Software" (categoría default); el flujo creará desde id 2.
  mysql_q "ALTER TABLE categories AUTO_INCREMENT = 2;" >/dev/null
  echo "==> Snipe-IT: AUTO_INCREMENT de categories reiniciado a 2"
else
  echo "==> Snipe-IT: nada que borrar en categories."
fi

# ---- 3. Snipe-IT (MySQL): status labels ----
if [[ ${#STATUS_IDS[@]} -gt 0 ]]; then
  STATUS_LIST=$(IFS=,; echo "${STATUS_IDS[*]}")
  USED=$(mysql_q "SELECT COUNT(*) FROM assets WHERE status_id IN ($STATUS_LIST);")
  if [[ "$USED" != "0" ]]; then
    echo "ERROR: $USED asset(s) usan esos status labels. No se puede borrar." >&2
    exit 1
  fi
  mysql_q "DELETE FROM status_labels WHERE id IN ($STATUS_LIST);" >/dev/null
  echo "==> Snipe-IT: eliminados de status_labels -> id $STATUS_LIST"
  # ids 1-3 = "Pending", "Ready to Deploy", "Archived" (built-ins);
  # el flujo/seeder creará desde id 4.
  mysql_q "ALTER TABLE status_labels AUTO_INCREMENT = 4;" >/dev/null
  echo "==> Snipe-IT: AUTO_INCREMENT de status_labels reiniciado a 4"
else
  echo "==> Snipe-IT: nada que borrar en status_labels."
fi

# ---- 4. n8n (PostgreSQL) ----
psql_q "TRUNCATE TABLE tryton_snipe_model_map RESTART IDENTITY;" >/dev/null
psql_q "TRUNCATE TABLE tryton_snipe_category_map RESTART IDENTITY;" >/dev/null
psql_q "TRUNCATE TABLE tryton_snipe_status_map RESTART IDENTITY;" >/dev/null
psql_q "TRUNCATE TABLE staging_tryton_assets RESTART IDENTITY;" >/dev/null
psql_q "TRUNCATE TABLE tryton_snipe_asset_map RESTART IDENTITY;" >/dev/null
psql_q "TRUNCATE TABLE tryton_snipe_run_summary RESTART IDENTITY;" >/dev/null
psql_q "TRUNCATE TABLE staging_titular RESTART IDENTITY;" >/dev/null
psql_q "TRUNCATE TABLE snipe_titular_map RESTART IDENTITY;" >/dev/null
psql_q "TRUNCATE TABLE snipe_titular_user_map RESTART IDENTITY;" >/dev/null
psql_q "TRUNCATE TABLE integration_sync_log RESTART IDENTITY;" >/dev/null
echo "==> n8n: tablas truncadas, secuencias reiniciadas."

# ---- Verificación ----
echo "==> Verificación:"
echo "    Map models:     $(psql_q "SELECT COUNT(*) FROM tryton_snipe_model_map;")"
echo "    Map categories: $(psql_q "SELECT COUNT(*) FROM tryton_snipe_category_map;")"
echo "    Map status:     $(psql_q "SELECT COUNT(*) FROM tryton_snipe_status_map;")"
echo "    Staging:        $(psql_q "SELECT COUNT(*) FROM staging_tryton_assets;")"
echo "    Asset map:      $(psql_q "SELECT COUNT(*) FROM tryton_snipe_asset_map;")"
echo "    Run summary:    $(psql_q "SELECT COUNT(*) FROM tryton_snipe_run_summary;")"
echo "    Staging titular: $(psql_q "SELECT COUNT(*) FROM staging_titular;")"
echo "    Titular map:    $(psql_q "SELECT COUNT(*) FROM snipe_titular_map;")"
echo "    Titular user map: $(psql_q "SELECT COUNT(*) FROM snipe_titular_user_map;")"
echo "    Log rows:       $(psql_q "SELECT COUNT(*) FROM integration_sync_log;")"
echo "    Snipe models:   $(mysql_q "SELECT COUNT(*) FROM models;")"
echo "    Snipe cats:     $(mysql_q "SELECT COUNT(*) FROM categories;")"
echo "    Snipe status:   $(mysql_q "SELECT COUNT(*) FROM status_labels;") (3 = solo built-ins)"

echo "Listo. Re-ejecuta el flujo 'Tryton sync assets' en n8n."
