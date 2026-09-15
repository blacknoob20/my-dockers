#!/bin/bash
# ============================================================
# RESET SYNC — Sync Tryton → Snipe-IT
#
# Limpia los datos generados por el flujo n8n "Tryton sync assets"
# para poder re-ejecutarlo y certificar la sincronización:
#
#   0. Snipe-IT (MySQL): borra TODOS los assets (LAB ONLY, sin
#      respaldo). Se muestra en el plan previo a la confirmación.
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
# NO toca: usuarios, ni la categoría por defecto (id 1).
#
# Uso:  ./reset-sync.sh [-y] [--verbose]
#       -y         omite la confirmación
#       --verbose  lista completa de IDs en pantalla (por defecto,
#                  se vuelcan a /tmp/reset-sync-*.txt)
# ============================================================
set -uo pipefail

VERBOSE=0
for _arg in "$@"; do
  [[ "$_arg" == "--verbose" ]] && VERBOSE=1
done

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

# Contenedores de BD: el mismo repo corre en máquinas con nombres distintos
# (compose Linux: docker-mariadb-1/docker-postgres-1; Mac lab: dbs-*). Se
# auto-detecta el contenedor corriendo; override con SNIPE_DB_CONT/N8N_DB_CONT.
DOCKER_PS=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
_pick_cont() {
  local _try
  for _try in "$@"; do
    if grep -qx "$_try" <<<"$DOCKER_PS"; then
      echo "$_try"
      return 0
    fi
  done
  return 1
}
SNIPE_DB_CONT="${SNIPE_DB_CONT:-$(_pick_cont docker-mariadb-1 dbs-mariadb)}"
N8N_DB_CONT="${N8N_DB_CONT:-$(_pick_cont docker-postgres-1 dbs-postgres)}"
if [[ -z "$SNIPE_DB_CONT" || -z "$N8N_DB_CONT" ]]; then
  echo "ERROR: no encuentro los contenedores de BD corriendo (probé docker-*-1 y dbs-*)." >&2
  echo "       Defínelos con SNIPE_DB_CONT / N8N_DB_CONT o levántalos primero." >&2
  exit 1
fi
for _c in "$SNIPE_DB_CONT" "$N8N_DB_CONT"; do
  grep -qx "$_c" <<<"$DOCKER_PS" || { echo "ERROR: contenedor '$_c' no está corriendo. Revisa SNIPE_DB_CONT/N8N_DB_CONT." >&2; exit 1; }
done

mysql_q() {
  docker exec "$SNIPE_DB_CONT" mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -N -B -e "$1" 2>/dev/null
}
psql_q() {
  docker exec "$N8N_DB_CONT" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c "$1"
}

resumen_lista() {
  local -n _arr=$1
  local _max=${2:-10}
  local _n=${#_arr[@]}
  [[ $_n -eq 0 ]] && { printf 'ninguno'; return; }
  local _show=($_n)
  if (( _n > _max )); then
    _show=("${_arr[@]:0:$_max}" "+$((_n - _max)) más")
    printf '%s ' "${_show[@]}"
  else
    printf '%s ' "${_arr[@]}"
  fi
}

nombrar() {
  local -n _ids=$1
  local -n _names=$2
  local _max=${3:-10}
  local _n=${#_ids[@]}
  [[ $_n -eq 0 ]] && { printf 'ninguno'; return; }
  local _i _show=()
  for (( _i=0; _i<_n && _i<_max; _i++ )); do
    _show+=("${_names[$_i]}(${_ids[$_i]})")
  done
  printf '%s ' "${_show[@]}"
  (( _n > _max )) && printf '+%d más' $((_n - _max))
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

ASSET_COUNT=$(mysql_q "SELECT COUNT(*) FROM assets;")

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

# Nombres legibles para categorías, modelos y status (el orden no importa;
# se ordena por id para alinear con los arrays *_IDS que usan DELETE por id).
CAT_NAMES=()
while IFS= read -r name; do
  [[ -n "$name" ]] && CAT_NAMES+=("$name")
done < <(mysql_q "SELECT name FROM categories WHERE id IN ($(IFS=,; echo "${CAT_IDS[*]:-0}")) ORDER BY id;")

MOD_NAMES=()
while IFS= read -r name; do
  [[ -n "$name" ]] && MOD_NAMES+=("$name")
done < <(mysql_q "SELECT name FROM models WHERE id IN ($(IFS=,; echo "${MOD_IDS[*]:-0}")) ORDER BY id;")

STATUS_LABEL_NAMES=()
while IFS= read -r name; do
  [[ -n "$name" ]] && STATUS_LABEL_NAMES+=("$name")
done < <(mysql_q "SELECT name FROM status_labels WHERE id IN ($(IFS=,; echo "${STATUS_IDS[*]:-0}")) ORDER BY id;")

# Resumen de modelos por categoría (top 10)
MODS_PER_CAT=()
while IFS=$'\t' read -r count name; do
  [[ -n "$name" ]] && MODS_PER_CAT+=("${name}=${count}")
done < <(mysql_q "SELECT COUNT(*) AS cnt, c.name FROM models m JOIN categories c ON c.id = m.category_id WHERE m.category_id IN ($(IFS=,; echo "${CAT_IDS[*]:-0}")) GROUP BY c.name ORDER BY cnt DESC, c.name LIMIT 10;")

# Total Snipe-IT en una sola línea
SNIPIT_TOTAL=$((${#MOD_IDS[@]} + ${#CAT_IDS[@]} + ${#STATUS_IDS[@]} + ASSET_COUNT))

# Volcar IDs completos a archivo temporal para auditoría
_IDS_FILE=$(mktemp "/tmp/reset-sync-$(date +%Y%m%d-%H%M%S)-ids-XXXXXX")
{
  echo "CAT_IDS: ${CAT_IDS[*]}"
  echo "MOD_IDS: ${MOD_IDS[*]}"
  echo "STATUS_IDS: ${STATUS_IDS[*]}"
} > "$_IDS_FILE"

echo "==> Plan de limpieza (LAB ONLY, irreversible):"
echo "    Snipe-IT (se borrará):"
printf "      assets:        %d en total (TODOS, paso 0)\n" "$ASSET_COUNT"
printf "      modelos:       %d a borrar (por category_id del map). " "${#MOD_IDS[@]}"
if [[ $VERBOSE -eq 1 ]]; then
  nombrar MOD_IDS MOD_NAMES 10
else
  resumen_lista MOD_IDS 10
fi
printf "\n"
if [[ ${#MODS_PER_CAT[@]} -gt 0 ]]; then
  printf "                       Por categoría: %s\n" "$(IFS=', '; echo "${MODS_PER_CAT[*]}")"
fi
printf "      categorías:    %d a borrar. " "${#CAT_IDS[@]}"
if [[ $VERBOSE -eq 1 ]]; then
  nombrar CAT_IDS CAT_NAMES 10
else
  resumen_lista CAT_IDS 10
fi
printf "\n"
printf "      status labels: %d a borrar (se preservan 1-3 built-in). " "${#STATUS_IDS[@]}"
if [[ $VERBOSE -eq 1 ]]; then
  nombrar STATUS_IDS STATUS_LABEL_NAMES 10
else
  resumen_lista STATUS_IDS 10
fi
printf "\n"
printf "    TOTAL Snipe-IT: %d objetos a borrar.\n" "$SNIPIT_TOTAL"

echo "    n8n Postgres (TRUNCATE + RESTART IDENTITY):"
TOTAL_N8N=$((MAP_MODELS+MAP_CATS+MAP_STATUS+STAGING_COUNT+MAP_ASSETS+SUMMARY_COUNT+STAGING_TITULAR_COUNT+MAP_TITULAR_COUNT+MAP_TITULAR_USER_COUNT+LOG_COUNT))
printf "      %-34s %d\n" "tryton_snipe_model_map:"     "$MAP_MODELS"
printf "      %-34s %d\n" "tryton_snipe_category_map:"  "$MAP_CATS"
printf "      %-34s %d\n" "tryton_snipe_status_map:"    "$MAP_STATUS"
printf "      %-34s %d\n" "staging_tryton_assets:"      "$STAGING_COUNT"
printf "      %-34s %d\n" "tryton_snipe_asset_map:"     "$MAP_ASSETS"
printf "      %-34s %d\n" "tryton_snipe_run_summary:"   "$SUMMARY_COUNT"
printf "      %-34s %d\n" "staging_titular:"            "$STAGING_TITULAR_COUNT"
printf "      %-34s %d\n" "snipe_titular_map:"          "$MAP_TITULAR_COUNT"
printf "      %-34s %d\n" "snipe_titular_user_map:"     "$MAP_TITULAR_USER_COUNT"
printf "      %-34s %d\n" "integration_sync_log:"       "$LOG_COUNT"
printf "      %-34s %d\n" "TOTAL:"                      "$TOTAL_N8N"

echo "    Se preserva: usuarios Snipe-IT, categoría default id 1, status built-in 1-3."
echo "    AUTO_INCREMENT: assets→1, models→1, categories→2, status_labels→4."
echo "    Lista completa de IDs: $_IDS_FILE"

if ! grep -qw -- "-y" <<< "$*"; then
  read -r -p "¿Continuar? [s/N] " resp
  [[ "$resp" =~ ^[sSyY]$ ]] || { echo "Cancelado."; exit 0; }
fi

# ---- 0. Snipe-IT (MySQL): assets (LAB ONLY, irreversible, sin respaldo) ----
# Sin este paso el guard de modelos aborta (assets referencian modelos).
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
