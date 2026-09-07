#!/usr/bin/env bash
# n8n-remap.sh — remapea IDs de credenciales en snapshots de n8n (casa <-> trabajo)
# y opcionalmente los publica (push) en el n8n vivo por DB directa.
#
# Compatible con bash 3.2 (macOS de fabrica) y Linux. Solo usa: bash, jq,
# mktemp, diff, uname, docker (+ uuidgen o python3 solo en modo push).
# No usa arrays asociativos, mapfile ni sed -i.
#
# Modo remap (default): reescribe credentials.{postgres,httpBearerAuth}.
#   {id,name} y los workflowId del orquestador en copias bajo /tmp
#   (el repo no se modifica).
# Modo push: remapea + UPDATE workflow_entity (nodes/connections/settings)
#   + INSERT workflow_history + bump versionId, con backup previo a /tmp.
#   No toca queries ni secretos (viven cifrados en cada ambiente).
#   Nunca ejecuta sudo.
#
# Mapas (solo IDs, seguros para git): envs/n8n-creds.example.json
#                                     envs/n8n-workflows.example.json (plantillas).
#   Los reales envs/n8n-{creds,workflows}.{casa,trabajo}.json están ignorados
#   por git (cada máquina guarda los suyos).

set -u

VERSION="1.2.1"

print_usage() {
  cat <<USAGE
Uso remap: $(basename "$0") --to {casa|trabajo} [opciones] <flujo.json> [...]
Uso push:  $(basename "$0") push --to {casa|trabajo} [opciones] <flujo.json> [...]

Remapea los IDs de credenciales y workflowIds del orquestador al ambiente destino.
En modo push ademas publica el resultado en el n8n vivo (DB directa).

Opciones remap:
  --to ENV        Ambiente destino: casa | trabajo (obligatorio).
  --out-dir DIR   Directorio de salida (default: /tmp/n8n-remap/ENV).
  --dry-run       No escribe; muestra conteo por archivo.
  --install       Si falta jq e intenta instalarlo: solo en macOS con
                  brew (no usa sudo). En Linux siempre imprime el
                  comando para que lo ejecutes tu con sudo.

Opciones push (suman a --to y --dry-run):
  --yes           Omite la confirmacion interactiva.
  --restart       Reinicia n8n al final y espera a que responda /healthz.
  --db-cont NAME  Contenedor postgres de n8n (default: docker-postgres-1).

  -h, --help      Muestra esta ayuda.

Ejemplos:
  $(basename "$0") --to trabajo "flows/flujos-dev/Tryton sync snipe-IT status.json"
  $(basename "$0") push --to trabajo --dry-run flows/flujos-dev/"Tryton sync snipe-IT status.json"
  $(basename "$0") push --to trabajo --restart flows/flujos-dev/*.json

Reglas de mapeo (solo IDs):
  postgres (todos los nodos)  -> pg_n8n del destino,
    salvo "Query Active Employees" -> pg_tryton del destino.
  httpBearerAuth              -> bearer_snipe del destino.
  workflowId (6 Execute del orquestador, por nombre de nodo)
                              -> id del sub-workflow destino
    (ver NODOS_WF abajo); actualiza value, cachedResultUrl y
    cachedResultName. Otros tipos de credencial no se tocan.

NODOS_WF (nombre exacto -> clave del mapa n8n-workflows):
  "Execute login"                          -> login
  "Execute Tryton sync snipeIT categories" -> categories
  "Execute Tryton sync snipeIT status"     -> status
  "Execute Tryton sync snipeIT models"     -> models
  "Execute Tryton sync snipe-IT assets"    -> assets
  "Execute Tryton sync snipe-IT users assets" -> users

Seguridad push: backup del row vivo a /tmp/n8n-push/ENV antes de cada
UPDATE; se niega si el live-ID no existe, el nombre no coincide o el
workflow esta archivado; confirmacion salvo --yes.

Version: $VERSION
USAGE
}

fail() {
  echo "n8n-remap: $1" >&2
  exit "${2:-1}"
}

# ---------- modo ----------
MODE="remap"
if [ "${1:-}" = "push" ]; then
  MODE="push"
  shift
fi

# ---------- parsing manual (compatible bash 3.2, con --opt=val) ----------
TO=""
OUT_DIR=""
DRY_RUN=0
DO_INSTALL=0
DO_YES=0
DO_RESTART=0
DB_CONT="docker-postgres-1"

while [ $# -gt 0 ]; do
  case "$1" in
    --to)
      [ $# -ge 2 ] || fail "falta valor para --to" 2
      TO="$2"; shift 2 ;;
    --to=*)
      TO="${1#--to=}"; shift ;;
    --out-dir)
      [ $# -ge 2 ] || fail "falta valor para --out-dir" 2
      OUT_DIR="$2"; shift 2 ;;
    --out-dir=*)
      OUT_DIR="${1#--out-dir=}"; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    --install)
      DO_INSTALL=1; shift ;;
    --yes)
      DO_YES=1; shift ;;
    --restart)
      DO_RESTART=1; shift ;;
    --db-cont)
      [ $# -ge 2 ] || fail "falta valor para --db-cont" 2
      DB_CONT="$2"; shift 2 ;;
    --db-cont=*)
      DB_CONT="${1#--db-cont=}"; shift ;;
    -h|--help)
      print_usage; exit 0 ;;
    --)
      shift; break ;;
    -*)
      echo "n8n-remap: opcion desconocida: $1" >&2
      print_usage >&2; exit 2 ;;
    *)
      break ;;
  esac
done

[ -n "$TO" ] || { echo "n8n-remap: falta --to {casa|trabajo}" >&2; print_usage >&2; exit 2; }
case "$TO" in
  casa|trabajo) ;;
  *) fail "--to debe ser casa o trabajo (fue: $TO)" 2 ;;
esac
[ $# -ge 1 ] || { echo "n8n-remap: indica al menos un archivo .json" >&2; print_usage >&2; exit 2; }

# ---------- dependencia jq (sin sudo nunca) ----------
if ! command -v jq >/dev/null 2>&1; then
  if [ "$DO_INSTALL" -eq 1 ]; then
    OS_NAME="$(uname -s)"
    case "$OS_NAME" in
      Darwin)
        if command -v brew >/dev/null 2>&1; then
          brew install jq || fail "brew no pudo instalar jq"
        else
          fail "no hay brew. Instalalo y luego: brew install jq"
        fi
        command -v jq >/dev/null 2>&1 || fail "jq sigue sin estar disponible tras brew install"
        ;;
      *)
        fail "instalacion automatica solo en macOS (brew). En Linux ejecuta tu: sudo apt-get install -y jq (o dnf/yum/pacman/apk segun tu distro)"
        ;;
    esac
  else
    OS_NAME="$(uname -s)"
    case "$OS_NAME" in
      Darwin)
        fail "falta jq. Instala con: brew install jq  (o repite con --install para intentarlo)"
        ;;
      *)
        fail "falta jq. Instalalo tu con sudo, ej: sudo apt-get install -y jq"
        ;;
    esac
  fi
fi

# ---------- mapas ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENVS_DIR="$STACK_DIR/envs"
CASA_CREDS="$ENVS_DIR/n8n-creds.casa.json"
TRABAJO_CREDS="$ENVS_DIR/n8n-creds.trabajo.json"
CASA_WF="$ENVS_DIR/n8n-workflows.casa.json"
TRABAJO_WF="$ENVS_DIR/n8n-workflows.trabajo.json"

[ -f "$CASA_CREDS" ] || fail "no existe $CASA_CREDS"
[ -f "$TRABAJO_CREDS" ] || fail "no existe $TRABAJO_CREDS"

for m in "$CASA_CREDS" "$TRABAJO_CREDS"; do
  jq -e '.pg_n8n.id and .pg_tryton.id and .bearer_snipe.id' "$m" >/dev/null 2>&1 \
    || fail "mapa invalido (faltan roles pg_n8n/pg_tryton/bearer_snipe): $m"
done

if [ "$TO" = "casa" ]; then
  TGT_CREDS="$CASA_CREDS"
  TGT_WF="$CASA_WF"
else
  TGT_CREDS="$TRABAJO_CREDS"
  TGT_WF="$TRABAJO_WF"
fi

CASA_PG="$(jq -r '.pg_n8n.id' "$CASA_CREDS")"
CASA_TRYTON="$(jq -r '.pg_tryton.id' "$CASA_CREDS")"
TRABAJO_PG="$(jq -r '.pg_n8n.id' "$TRABAJO_CREDS")"
TRABAJO_TRYTON="$(jq -r '.pg_tryton.id' "$TRABAJO_CREDS")"
TGT_PG_ID="$(jq -r '.pg_n8n.id' "$TGT_CREDS")"
TGT_PG_NAME="$(jq -r '.pg_n8n.name' "$TGT_CREDS")"
TGT_TRYTON_ID="$(jq -r '.pg_tryton.id' "$TGT_CREDS")"
TGT_TRYTON_NAME="$(jq -r '.pg_tryton.name' "$TGT_CREDS")"
TGT_BEARER_ID="$(jq -r '.bearer_snipe.id' "$TGT_CREDS")"
TGT_BEARER_NAME="$(jq -r '.bearer_snipe.name' "$TGT_CREDS")"

# ---------- mapa de workflows destino (fase 3: workflowIds) ----------
[ -f "$TGT_WF" ] || fail "no existe $TGT_WF (mapa de workflows destino)"
jq -e '.login.id and .categories.id and .status.id and .models.id and .assets.id and .users.id' "$TGT_WF" >/dev/null 2>&1 \
  || fail "mapa invalido (faltan claves login/categories/status/models/assets/users): $TGT_WF"
TGT_WF_LOGIN_ID="$(jq -r '.login.id' "$TGT_WF")"
TGT_WF_LOGIN_NAME="$(jq -r '.login.name' "$TGT_WF")"
TGT_WF_CATEGORIES_ID="$(jq -r '.categories.id' "$TGT_WF")"
TGT_WF_CATEGORIES_NAME="$(jq -r '.categories.name' "$TGT_WF")"
TGT_WF_STATUS_ID="$(jq -r '.status.id' "$TGT_WF")"
TGT_WF_STATUS_NAME="$(jq -r '.status.name' "$TGT_WF")"
TGT_WF_MODELS_ID="$(jq -r '.models.id' "$TGT_WF")"
TGT_WF_MODELS_NAME="$(jq -r '.models.name' "$TGT_WF")"
TGT_WF_ASSETS_ID="$(jq -r '.assets.id' "$TGT_WF")"
TGT_WF_ASSETS_NAME="$(jq -r '.assets.name' "$TGT_WF")"
TGT_WF_USERS_ID="$(jq -r '.users.id' "$TGT_WF")"
TGT_WF_USERS_NAME="$(jq -r '.users.name' "$TGT_WF")"

# Reescribe credenciales del snapshot $1 al ambiente destino en $2.
remap_creds() {
  jq --arg casa_pg "$CASA_PG" --arg trabajo_pg "$TRABAJO_PG" \
     --arg casa_tryton "$CASA_TRYTON" --arg trabajo_tryton "$TRABAJO_TRYTON" \
     --arg tgt_pg_id "$TGT_PG_ID" --arg tgt_pg_name "$TGT_PG_NAME" \
     --arg tgt_tryton_id "$TGT_TRYTON_ID" --arg tgt_tryton_name "$TGT_TRYTON_NAME" \
     --arg tgt_bearer_id "$TGT_BEARER_ID" --arg tgt_bearer_name "$TGT_BEARER_NAME" \
   '.nodes |= map(
      . as $n
      | if (.credentials | type) != "object" then .
        else .credentials |= with_entries(
          if .key == "postgres" then
            (.value.id) as $cid
            | if $cid == $casa_pg or $cid == $trabajo_pg then
                .value.id = $tgt_pg_id | .value.name = $tgt_pg_name
              elif $cid == $casa_tryton or $cid == $trabajo_tryton then
                .value.id = $tgt_tryton_id | .value.name = $tgt_tryton_name
              elif $n.name == "Query Active Employees" then
                .value.id = $tgt_tryton_id | .value.name = $tgt_tryton_name
              else
                .value.id = $tgt_pg_id | .value.name = $tgt_pg_name
              end
          elif .key == "httpBearerAuth" then
            .value.id = $tgt_bearer_id | .value.name = $tgt_bearer_name
          else . end
        )
        end
    )' "$1" > "$2"
}

count_cred() {
  # $1=archivo $2=rol(pg_n8n|pg_tryton|bearer) -> numero
  case "$2" in
    pg_n8n)
      jq --arg a "$CASA_TRYTON" --arg b "$TRABAJO_TRYTON" \
        '[.nodes[]? | select(.credentials.postgres?) | select(.credentials.postgres.id != $a and .credentials.postgres.id != $b and .name != "Query Active Employees")] | length' "$1" ;;
    pg_tryton)
      jq --arg a "$CASA_TRYTON" --arg b "$TRABAJO_TRYTON" \
        '[.nodes[]? | select(.credentials.postgres?) | select(.credentials.postgres.id == $a or .credentials.postgres.id == $b or .name == "Query Active Employees")] | length' "$1" ;;
    bearer)
      jq '[.nodes[]? | select(.credentials.httpBearerAuth?)] | length' "$1" ;;
  esac
}

# Reescribe los workflowId de los 6 Execute del orquestador ($1) al
# ambiente destino en $2 (por nombre exacto de nodo, ver NODOS_WF).
remap_wf() {
  jq --arg login_id "$TGT_WF_LOGIN_ID" --arg login_name "$TGT_WF_LOGIN_NAME" \
     --arg categories_id "$TGT_WF_CATEGORIES_ID" --arg categories_name "$TGT_WF_CATEGORIES_NAME" \
     --arg status_id "$TGT_WF_STATUS_ID" --arg status_name "$TGT_WF_STATUS_NAME" \
     --arg models_id "$TGT_WF_MODELS_ID" --arg models_name "$TGT_WF_MODELS_NAME" \
     --arg assets_id "$TGT_WF_ASSETS_ID" --arg assets_name "$TGT_WF_ASSETS_NAME" \
     --arg users_id "$TGT_WF_USERS_ID" --arg users_name "$TGT_WF_USERS_NAME" \
    '.nodes |= map(
       if (.parameters.workflowId.value? // null) == null then .
       elif .name == "Execute login" then
         .parameters.workflowId.value = $login_id
         | .parameters.workflowId.cachedResultUrl = ("/workflow/" + $login_id)
         | .parameters.workflowId.cachedResultName = $login_name
       elif .name == "Execute Tryton sync snipeIT categories" then
         .parameters.workflowId.value = $categories_id
         | .parameters.workflowId.cachedResultUrl = ("/workflow/" + $categories_id)
         | .parameters.workflowId.cachedResultName = $categories_name
       elif .name == "Execute Tryton sync snipeIT status" then
         .parameters.workflowId.value = $status_id
         | .parameters.workflowId.cachedResultUrl = ("/workflow/" + $status_id)
         | .parameters.workflowId.cachedResultName = $status_name
       elif .name == "Execute Tryton sync snipeIT models" then
         .parameters.workflowId.value = $models_id
         | .parameters.workflowId.cachedResultUrl = ("/workflow/" + $models_id)
         | .parameters.workflowId.cachedResultName = $models_name
       elif .name == "Execute Tryton sync snipe-IT assets" then
         .parameters.workflowId.value = $assets_id
         | .parameters.workflowId.cachedResultUrl = ("/workflow/" + $assets_id)
         | .parameters.workflowId.cachedResultName = $assets_name
       elif .name == "Execute Tryton sync snipe-IT users assets" then
         .parameters.workflowId.value = $users_id
         | .parameters.workflowId.cachedResultUrl = ("/workflow/" + $users_id)
         | .parameters.workflowId.cachedResultName = $users_name
       else .
       end
     )' "$1" > "$2"
}

count_wf() {
  # $1=archivo -> numero de Execute con nombre conocido (NODOS_WF)
  jq '[.nodes[]?
       | select((.parameters.workflowId.value? // null) != null)
       | select(.name == "Execute login"
             or .name == "Execute Tryton sync snipeIT categories"
             or .name == "Execute Tryton sync snipeIT status"
             or .name == "Execute Tryton sync snipeIT models"
             or .name == "Execute Tryton sync snipe-IT assets"
             or .name == "Execute Tryton sync snipe-IT users assets")] | length' "$1"
}

# ================= MODO REMAP =================
if [ "$MODE" = "remap" ]; then
  if [ -z "$OUT_DIR" ]; then
    OUT_DIR="/tmp/n8n-remap/$TO"
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$OUT_DIR" || fail "no se pudo crear $OUT_DIR"
  fi

  TOTAL=0
  CHANGED=0
  for SRC in "$@"; do
    [ -f "$SRC" ] || { echo "n8n-remap: no existe, se omite: $SRC" >&2; continue; }
    TOTAL=$((TOTAL + 1))

    PG_N="$(count_cred "$SRC" pg_n8n)"
    TRYTON_N="$(count_cred "$SRC" pg_tryton)"
    BEARER_N="$(count_cred "$SRC" bearer)"
    WF_N="$(count_wf "$SRC")"

    TMP_OUT="$(mktemp "${TMPDIR:-/tmp}/n8n-remap.XXXXXX")" || fail "no se pudo crear temporal"
    TMP_MID="$(mktemp "${TMPDIR:-/tmp}/n8n-remap.XXXXXX")" || { rm -f "$TMP_OUT"; fail "no se pudo crear temporal"; }
    remap_creds "$SRC" "$TMP_MID" || { rm -f "$TMP_OUT" "$TMP_MID"; fail "jq fallo con: $SRC"; }
    remap_wf "$TMP_MID" "$TMP_OUT" || { rm -f "$TMP_OUT" "$TMP_MID"; fail "jq fallo (workflows) con: $SRC"; }
    rm -f "$TMP_MID"

    if diff -q "$SRC" "$TMP_OUT" >/dev/null 2>&1; then
      echo "[sin cambios] $SRC (pg_n8n:$PG_N pg_tryton:$TRYTON_N bearer:$BEARER_N wf:$WF_N)"
      rm -f "$TMP_OUT"
    else
      CHANGED=$((CHANGED + 1))
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] $SRC -> pg_n8n:$PG_N pg_tryton:$TRYTON_N bearer:$BEARER_N wf:$WF_N"
        rm -f "$TMP_OUT"
      else
        BASE="$(basename "$SRC")"
        mv "$TMP_OUT" "$OUT_DIR/$BASE" || { rm -f "$TMP_OUT"; fail "no se pudo escribir $OUT_DIR/$BASE"; }
        echo "[ok] $SRC -> $OUT_DIR/$BASE (pg_n8n:$PG_N pg_tryton:$TRYTON_N bearer:$BEARER_N wf:$WF_N)"
      fi
    fi
  done

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "dry-run: $TOTAL archivo(s), $CHANGED con cambios (nada escrito)."
  else
    echo "listo: $TOTAL archivo(s), $CHANGED remapeado(s) a $TO en $OUT_DIR"
  fi
  exit 0
fi

# ================= MODO PUSH =================
[ -f "$TGT_WF" ] || fail "no existe $TGT_WF (mapa de workflows destino)"
jq -e 'to_entries | length > 0' "$TGT_WF" >/dev/null 2>&1 || fail "mapa vacio: $TGT_WF"

# DB de n8n (auth por trust dentro del contenedor, como reset-sync.sh).
if [ -f "$ENVS_DIR/n8n-db.env" ]; then
  # shellcheck disable=SC1090
  . "$ENVS_DIR/n8n-db.env"
fi
POSTGRES_USER="$(printf '%s' "${POSTGRES_USER:-n8n_user}" | tr -d '\r')"
POSTGRES_DB="$(printf '%s' "${POSTGRES_DB:-n8n}" | tr -d '\r')"
N8N_DB_CONT="${N8N_DB_CONT:-$DB_CONT}"

command -v docker >/dev/null 2>&1 || fail "falta docker"
docker exec "$N8N_DB_CONT" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c "SELECT 1;" >/dev/null 2>&1 \
  || fail "no hay acceso a $N8N_DB_CONT ($POSTGRES_USER/$POSTGRES_DB)"

BACKUP_DIR="/tmp/n8n-push/$TO"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/n8n-push-stage.XXXXXX")" || fail "no se pudo crear staging"
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$BACKUP_DIR" || fail "no se pudo crear $BACKUP_DIR"
fi

psql_q() {
  docker exec "$N8N_DB_CONT" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c "$1"
}

gen_uuid() {
  uuidgen 2>/dev/null || python3 -c 'import uuid,sys; sys.stdout.write(str(uuid.uuid4()))'
}

PLAN_N=0
PLAN_LIST=""
for SRC in "$@"; do
  [ -f "$SRC" ] || { echo "n8n-remap push: no existe, se omite: $SRC" >&2; continue; }
  jq -e '.nodes and .name' "$SRC" >/dev/null 2>&1 || { echo "n8n-remap push: JSON sin .nodes/.name, se omite: $SRC" >&2; continue; }
  PLAN_N=$((PLAN_N + 1))
  PLAN_LIST="$PLAN_LIST
$SRC"
done
[ "$PLAN_N" -ge 1 ] || fail "nada valido para push" 2

if [ "$DO_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  echo "Se publicaran $PLAN_N flujo(s) en $TO (DB $N8N_DB_CONT):$PLAN_LIST"
  printf '%s' "Continuar? [s/N] "
  read -r ANS
  case "$ANS" in
    s|S|y|Y|si|sí|SI) ;;
    *) echo "cancelado (nada escrito)."; rm -rf "$STAGE_DIR"; exit 0 ;;
  esac
fi

OK_N=0
ERR_N=0
PUSHED_IDS=""
for SRC in "$@"; do
  [ -f "$SRC" ] || continue
  jq -e '.nodes and .name' "$SRC" >/dev/null 2>&1 || continue

  SNAP_NAME="$(jq -r '.name' "$SRC")"
  MATCHES="$(jq --arg n "$SNAP_NAME" '[to_entries[] | select(.value.name == $n)] | length' "$TGT_WF")"
  if [ "$MATCHES" != "1" ]; then
    echo "[ERROR] $SRC: '$SNAP_NAME' tiene $MATCHES entradas en $TGT_WF (se exige 1)" >&2
    ERR_N=$((ERR_N + 1)); continue
  fi
  KEY="$(jq -r --arg n "$SNAP_NAME" 'to_entries[] | select(.value.name == $n) | .key' "$TGT_WF")"
  LIVE_ID="$(jq -r --arg k "$KEY" '.[$k].id' "$TGT_WF")"

  LIVE_ROW="$(psql_q "SELECT id || '|' || name || '|' || active || '|' || \"isArchived\" || '|' || \"versionId\" FROM workflow_entity WHERE id='$LIVE_ID';")"
  if [ -z "$LIVE_ROW" ]; then
    echo "[ERROR] $SRC: live-ID $LIVE_ID no existe en $TO" >&2
    ERR_N=$((ERR_N + 1)); continue
  fi
  LIVE_NAME="$(printf '%s' "$LIVE_ROW" | cut -d'|' -f2)"
  LIVE_ACTIVE="$(printf '%s' "$LIVE_ROW" | cut -d'|' -f3)"
  LIVE_ARCH="$(printf '%s' "$LIVE_ROW" | cut -d'|' -f4)"
  OLD_VID="$(printf '%s' "$LIVE_ROW" | cut -d'|' -f5)"
  if [ "$LIVE_NAME" != "$SNAP_NAME" ]; then
    echo "[ERROR] $SRC: el live-ID $LIVE_ID se llama '$LIVE_NAME', no '$SNAP_NAME'" >&2
    ERR_N=$((ERR_N + 1)); continue
  fi
  if [ "$LIVE_ARCH" = "t" ]; then
    echo "[ERROR] $SRC: $LIVE_ID esta archivado, no se toca" >&2
    ERR_N=$((ERR_N + 1)); continue
  fi

  STAGED="$STAGE_DIR/$KEY.json"
  STAGED_MID="$STAGE_DIR/$KEY.mid.json"
  remap_creds "$SRC" "$STAGED_MID" || { echo "[ERROR] $SRC: fallo remap" >&2; ERR_N=$((ERR_N + 1)); continue; }
  remap_wf "$STAGED_MID" "$STAGED" || { echo "[ERROR] $SRC: fallo remap workflows" >&2; ERR_N=$((ERR_N + 1)); continue; }
  rm -f "$STAGED_MID"
  PG_N="$(count_cred "$STAGED" pg_n8n)"
  TRYTON_N="$(count_cred "$STAGED" pg_tryton)"
  BEARER_N="$(count_cred "$STAGED" bearer)"
  WF_N="$(count_wf "$STAGED")"
  BAD_PG="$(jq --arg a "$TGT_PG_ID" --arg b "$TGT_TRYTON_ID" \
    '[.nodes[]? | select(.credentials.postgres?) | select(.credentials.postgres.id != $a and .credentials.postgres.id != $b)] | length' "$STAGED")"
  BAD_BEARER="$(jq --arg a "$TGT_BEARER_ID" \
    '[.nodes[]? | select(.credentials.httpBearerAuth?) | select(.credentials.httpBearerAuth.id != $a)] | length' "$STAGED")"
  BAD_WF="$(jq --arg login "$TGT_WF_LOGIN_ID" --arg categories "$TGT_WF_CATEGORIES_ID" \
    --arg status "$TGT_WF_STATUS_ID" --arg models "$TGT_WF_MODELS_ID" \
    --arg assets "$TGT_WF_ASSETS_ID" --arg users "$TGT_WF_USERS_ID" \
    '[.nodes[]? | select((.parameters.workflowId.value? // null) != null)
      | select(.name == "Execute login"
            or .name == "Execute Tryton sync snipeIT categories"
            or .name == "Execute Tryton sync snipeIT status"
            or .name == "Execute Tryton sync snipeIT models"
            or .name == "Execute Tryton sync snipe-IT assets"
            or .name == "Execute Tryton sync snipe-IT users assets")
      | select(.parameters.workflowId.value != $login
           and .parameters.workflowId.value != $categories
           and .parameters.workflowId.value != $status
           and .parameters.workflowId.value != $models
           and .parameters.workflowId.value != $assets
           and .parameters.workflowId.value != $users)] | length' "$STAGED")"
  if [ "$BAD_PG" != "0" ] || [ "$BAD_BEARER" != "0" ] || [ "$BAD_WF" != "0" ]; then
    echo "[ERROR] $SRC: remapeo incompleto (pg_fuera:$BAD_PG bearer_fuera:$BAD_BEARER wf_fuera:$BAD_WF)" >&2
    ERR_N=$((ERR_N + 1)); continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] $SNAP_NAME ($KEY): live $LIVE_ID active=$LIVE_ACTIVE ver=${OLD_VID:-?} -> nueva | pg_n8n:$PG_N pg_tryton:$TRYTON_N bearer:$BEARER_N wf:$WF_N"
    continue
  fi

  TS="$(date +%Y%m%d-%H%M%S)"
  psql_q "SELECT row_to_json(t) FROM workflow_entity t WHERE id='$LIVE_ID';" > "$BACKUP_DIR/backup-$LIVE_ID-$TS.json" \
    || { echo "[ERROR] $SRC: fallo backup" >&2; ERR_N=$((ERR_N + 1)); continue; }
  cp "$STAGED" "$BACKUP_DIR/staged-$KEY-$TS.json"

  NEWVID="$(gen_uuid)"
  [ -n "$NEWVID" ] || { echo "[ERROR] $SRC: sin uuid (uuidgen/python3)" >&2; ERR_N=$((ERR_N + 1)); continue; }

  # Se pasan los JSON como variables psql (-v) y se citan con :'var':
  # (a mano, el lexer de psql rechaza el SQL con invalid command \...).
  if jq -e '.settings' "$STAGED" >/dev/null 2>&1; then
    HAVE_SETTINGS=1
  else
    HAVE_SETTINGS=0
  fi
  NODES_J="$(jq -c '.nodes // []' "$STAGED")" || { echo "[ERROR] $SRC: fallo jq nodes" >&2; ERR_N=$((ERR_N + 1)); continue; }
  CONNS_J="$(jq -c '.connections // {}' "$STAGED")" || { echo "[ERROR] $SRC: fallo jq conns" >&2; ERR_N=$((ERR_N + 1)); continue; }
  NG_J="$(jq -c '.nodeGroups // []' "$STAGED")" || { echo "[ERROR] $SRC: fallo jq groups" >&2; ERR_N=$((ERR_N + 1)); continue; }
  if [ "$HAVE_SETTINGS" -eq 1 ]; then
    SET_J="$(jq -c '.settings' "$STAGED")" || { echo "[ERROR] $SRC: fallo jq settings" >&2; ERR_N=$((ERR_N + 1)); continue; }
    SET_SQL=", settings = :'stg'::json"
  else
    SET_J="{}"
    SET_SQL=""
  fi
  # NOTA: el historial va PRIMERO por la FK workflow_entity.activeVersionId.
  PUSH_SQL="INSERT INTO workflow_history (\"versionId\", \"workflowId\", authors, \"createdAt\", \"updatedAt\", nodes, connections, name, autosaved, description, \"nodeGroups\") VALUES (:'vid', :'live', 'n8n-remap push', now(), now(), :'nodes'::json, :'conns'::json, :'wname', false, NULL, :'ng'::json); UPDATE workflow_entity SET nodes = :'nodes'::json, connections = :'conns'::json${SET_SQL}, \"versionId\" = :'vid', \"activeVersionId\" = :'vid', \"updatedAt\" = now() WHERE id = :'live';"

  # NOTA: las variables :'var' solo interpolan via stdin, no con -c.
  if printf '%s' "$PUSH_SQL" | docker exec -i "$N8N_DB_CONT" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q \
      -v nodes="$NODES_J" -v conns="$CONNS_J" -v stg="$SET_J" -v ng="$NG_J" \
      -v vid="$NEWVID" -v live="$LIVE_ID" -v wname="$SNAP_NAME" >/dev/null 2>&1; then
    CHECK="$(psql_q "SELECT \"versionId\" FROM workflow_entity WHERE id='$LIVE_ID';")"
    if [ "$CHECK" = "$NEWVID" ]; then
      echo "[ok] $SNAP_NAME ($KEY): live $LIVE_ID active=$LIVE_ACTIVE ${OLD_VID} -> ${NEWVID} | pg_n8n:$PG_N pg_tryton:$TRYTON_N bearer:$BEARER_N wf:$WF_N"
      OK_N=$((OK_N + 1))
      PUSHED_IDS="$PUSHED_IDS $LIVE_ID"
    else
      echo "[ERROR] $SRC: version no cambio (esperaba $NEWVID)" >&2
      ERR_N=$((ERR_N + 1))
    fi
  else
    echo "[ERROR] $SRC: fallo UPDATE (ver backup $BACKUP_DIR/backup-$LIVE_ID-$TS.json)" >&2
    ERR_N=$((ERR_N + 1))
  fi
done

rm -rf "$STAGE_DIR"
echo "--- push $TO: $OK_N actualizado(s), $ERR_N error(es), backups en $BACKUP_DIR ---"

if [ "$DO_RESTART" -eq 1 ] && [ "$OK_N" -ge 1 ]; then
  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      DCC="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
      DCC="docker-compose"
    else
      echo "sin docker compose: reinicia n8n a mano para aplicar." >&2
      DCC=""
    fi
    if [ -n "$DCC" ]; then
      echo "reiniciando n8n..."
      # shellcheck disable=SC2086
      (cd "$STACK_DIR" && $DCC restart n8n) || fail "fallo restart n8n"
      i=0
      while [ "$i" -lt 36 ]; do
        if command -v curl >/dev/null 2>&1 && curl -sf --max-time 5 http://localhost:5678/healthz >/dev/null 2>&1; then
          echo "n8n responde /healthz OK"
          break
        fi
        i=$((i + 1))
        sleep 5
      done
      if [ "$i" -ge 36 ]; then
        echo "aviso: n8n no respondio /healthz en 180s, revisar a mano." >&2
      fi
    fi
  fi
elif [ "$OK_N" -ge 1 ]; then
  echo "nota: reinicia n8n para aplicar (o repite con --restart)."
fi

[ "$ERR_N" -eq 0 ] || exit 1
exit 0
