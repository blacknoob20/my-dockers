#!/usr/bin/env bash
# zammad-ticket-objects.sh — provisioning de objetos custom del ticket para el
# flujo "Zammad enrich ticket assets" (consulta live Snipe-IT al crear ticket).
#
# Crea (una sola vez por instancia Zammad):
#   snipe_asset_count   (integer)  — n. de activos asignados al cliente
#   snipe_asset_tags    (textarea) — asset_tags separados por coma
#   snipe_asset_summary (textarea) — resumen legible por el tecnico
#
# Requiere token con permiso admin.object (usuario svc-zammad-prov).
# Tras crear atributos ejecuta las migraciones de Object Manager
# (POST /api/v1/object_manager_attributes_execute_migrations) y luego es
# OBLIGATORIO reiniciar los workers de Zammad (ver mensaje final).
#
# Uso:
#   ./scripts/zammad-ticket-objects.sh
#   ./scripts/zammad-ticket-objects.sh --check   # solo verifica presencia
#   ZAMMAD_URL=http://localhost:8000 ZAMMAD_TOKEN_PROV=xxx ./scripts/zammad-ticket-objects.sh
#   # o lee ZAMMAD_TOKEN_PROV (fallback ZAMMAD_TOKEN) de envs/n8n.env si existe
#
# Idempotente: si el atributo ya existe no lo duplica (lo reporta y sigue).

set -euo pipefail

# ── Configuración ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then CHECK_ONLY=1; fi

if [[ -z "${ZAMMAD_URL:-}" ]]; then
  ZAMMAD_URL="http://localhost:8000"
fi
ZAMMAD_URL="$(printf '%s' "$ZAMMAD_URL" | cut -d' ' -f1)"
if [[ -z "${ZAMMAD_TOKEN_PROV:-}" ]]; then
  if [[ -f "$PROJECT_DIR/envs/n8n.env" ]]; then
    # cut -d' ' -f1: ignora comentarios inline " # ..." (forman parte del
    # valor para cut -d= -f2- y romperían el header Authorization).
    _tok=$(grep -E '^ZAMMAD_TOKEN_PROV=' "$PROJECT_DIR/envs/n8n.env" | cut -d= -f2- | cut -d' ' -f1 || true)
    if [[ -z "$_tok" ]]; then
      _tok=$(grep -E '^ZAMMAD_TOKEN=' "$PROJECT_DIR/envs/n8n.env" | cut -d= -f2- | cut -d' ' -f1 || true)
    fi
    if [[ -n "$_tok" ]]; then
      ZAMMAD_TOKEN_PROV="$_tok"
    fi
  fi
fi
if [[ -z "${ZAMMAD_TOKEN_PROV:-}" ]]; then
  echo "✖ ZAMMAD_TOKEN_PROV no configurado. Define la variable o crea envs/n8n.env desde envs/n8n.env.example." >&2
  echo "  El token debe ser del usuario svc-zammad-prov (rol Administrar, permiso admin.object)." >&2
  exit 1
fi

# Sanitizar CRLF/espacios (un \r en el header Authorization rompe la auth).
ZAMMAD_TOKEN_PROV="$(printf '%s' "$ZAMMAD_TOKEN_PROV" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
ZAMMAD_URL="$(printf '%s' "$ZAMMAD_URL" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

command -v jq >/dev/null 2>&1 || { echo "✖ Falta jq (brew install jq / sudo apt-get install -y jq)." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "✖ Falta curl." >&2; exit 1; }

AUTH_HEADER="Authorization: Token token=$ZAMMAD_TOKEN_PROV"

api_get() {
  curl -s --max-time 30 -H "$AUTH_HEADER" -H "Accept: application/json" "$ZAMMAD_URL$1"
}

api_post() {
  curl -s --max-time 60 -X POST -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    -d "$2" "$ZAMMAD_URL$1"
}

require_json() {
  local what="$1" resp="$2" first
  first=$(printf '%s' "$resp" | sed -e 's/^[[:space:]]*//' | cut -c1)
  if [[ "$first" != "{" && "$first" != "[" ]]; then
    echo "  ✖ $what: la API no devolvió JSON (¿Zammad caído, URL mal o token inválido?)." >&2
    echo "    Respuesta (300 chars): $(printf '%s' "$resp" | tr -d '\r\n' | cut -c1-300)" >&2
    echo "    Revisa ZAMMAD_URL=$ZAMMAD_URL y el token (longitud ${#ZAMMAD_TOKEN_PROV})." >&2
    exit 1
  fi
}

# Pantallas mínimas: el flujo escribe por API; el agente solo ve/edita.
# create_middle oculto para no interferir con el formulario de creación.
SCREENS='{"create_middle":{"ticket.agent":{"shown":false},"ticket.customer":{"shown":false}},"edit":{"ticket.agent":{"shown":true,"required":false}},"view":{"ticket.agent":{"shown":true},"ticket.customer":{"shown":false}}}'

# ── 1) Listar atributos actuales ───────────────────────────────
echo "→ Listando object_manager_attributes..."
attrs_json=$(api_get "/api/v1/object_manager_attributes")
require_json "GET /api/v1/object_manager_attributes" "$attrs_json"
if echo "$attrs_json" | jq -e 'has("error")' >/dev/null 2>&1; then
  echo "  ✖ Zammad respondió error (¿token sin admin.object?):" >&2
  echo "    $attrs_json" | head -c 500 >&2
  exit 1
fi

attr_exists() {
  echo "$attrs_json" | jq -e --arg n "$1" \
    '[.[] | select(.object=="Ticket" and .name==$n)] | length > 0' >/dev/null 2>&1
}

attr_active() {
  echo "$attrs_json" | jq -r --arg n "$1" \
    '[.[] | select(.object=="Ticket" and .name==$n) | .active] | first // empty'
}

CREATED=0

ensure_attr() {
  # $1=name $2=display $3=data_type $4=data_option_json $5=position
  local name="$1" display="$2" dtype="$3" dopt="$4" pos="$5"
  if attr_exists "$name"; then
    local act
    act=$(attr_active "$name")
    if [[ "$act" == "true" ]]; then
      echo "  ✔ $name ya existe y está activo."
    else
      echo "  ⚠ $name existe pero está INACTIVO: actívalo en Admin → Objetos → Ticket (no se auto-muta por seguridad)."
    fi
    return 0
  fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo "  ✖ $name FALTA."
    return 1
  fi
  echo "  Creando $name ($dtype)..."
  local body resp
  body=$(jq -n --arg name "$name" --arg display "$display" --arg dt "$dtype" \
    --argjson dopt "$dopt" --argjson pos "$pos" --argjson screens "$SCREENS" \
    '{name:$name, object:"Ticket", display:$display, active:true, position:$pos, data_type:$dt, data_option:$dopt, screens:$screens}')
  resp=$(api_post "/api/v1/object_manager_attributes" "$body")
  require_json "POST /api/v1/object_manager_attributes ($name)" "$resp"
  if echo "$resp" | jq -e '.id' >/dev/null 2>&1; then
    echo "  ✔ $name creado (id $(echo "$resp" | jq -r '.id'))."
    CREATED=$((CREATED + 1))
  else
    echo "  ✖ No se pudo crear $name. Respuesta:" >&2
    echo "    $resp" | head -c 1000 >&2
    if echo "$resp" | grep -iq "already\|exists\|taken"; then
      echo "  (parece duplicado concurrente; re-ejecuta para verificar)"
    else
      exit 1
    fi
  fi
}

# ── 2) Asegurar los 3 atributos ────────────────────────────────
echo "→ Verificando atributos del ticket..."
MISSING=0
ensure_attr "snipe_asset_count" "Activos Snipe-IT (conteo)" "integer" '{"min":0,"max":999999}' 1600 || MISSING=$((MISSING + 1))
ensure_attr "snipe_asset_tags" "Activos Snipe-IT (tags)" "textarea" '{"maxlength":20000}' 1610 || MISSING=$((MISSING + 1))
ensure_attr "snipe_asset_summary" "Activos Snipe-IT (resumen)" "textarea" '{"maxlength":20000}' 1620 || MISSING=$((MISSING + 1))

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  if [[ "$MISSING" -eq 0 ]]; then echo "✔ Los 3 atributos existen."; else echo "✖ Faltan $MISSING atributo(s)."; exit 1; fi
  exit 0
fi

# ── 3) Migraciones ─────────────────────────────────────────────
if [[ "$CREATED" -gt 0 ]]; then
  echo "→ Ejecutando migraciones de Object Manager ($CREATED nuevo(s))..."
  mig_resp=$(api_post "/api/v1/object_manager_attributes_execute_migrations" "{}")
  require_json "POST ..._execute_migrations" "$mig_resp"
  echo "  ✔ Migraciones ejecutadas."
else
  echo "→ Sin cambios, no se ejecutan migraciones."
fi

echo ""
echo "✔ Listo. REINICIO OBLIGATORIO de Zammad para aplicar cambios de esquema:"
echo "  cd $PROJECT_DIR && docker compose restart zammad-railsserver zammad-scheduler zammad-websocket"
echo "Verificación: ./scripts/zammad-ticket-objects.sh --check"
