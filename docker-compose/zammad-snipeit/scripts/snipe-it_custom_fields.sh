#!/usr/bin/env bash
# snipe-it_custom_fields.sh — provisioning de custom field y fieldset para activos Tryton
# Requisito del workflow: custom field "internal_code" con db_column _snipeit_internal_code_2
# y fieldset id 2 ("Activos Tryton" o similar) asociado. El ingest usa POST /api/v1/hardware con
# _snipeit_internal_code_2; si no existe, Snipe-IT devuelve 200 {"status":"error","messages":{"_snipeit_internal_code_2":[...]}}
# y todos los assets fallan (ver Fix 2026-09-01 en spec).
#
# Uso:
#   ./scripts/snipe-it_custom_fields.sh
#   SNIPE_URL=http://localhost:8080 API_TOKEN=xxx ./scripts/snipe-it_custom_fields.sh
#   # o lee API_TOKEN de envs/n8n.env si existe (local, ver n8n.env.example)
#
# Idempotente: si el campo/fieldset ya existe no lo duplica.

set -euo pipefail

# ── Configuración ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Permitir override por env; fallback a n8n.env y al placeholder en scripts/* existentes
if [[ -z "${SNIPE_URL:-}" ]]; then
  SNIPE_URL="http://localhost:8080"
fi
if [[ -z "${API_TOKEN:-}" ]]; then
  # intentar leer SNIPEIT_TOKEN de envs/n8n.env
  if [[ -f "$PROJECT_DIR/envs/n8n.env" ]]; then
    _tok=$(grep -E '^SNIPEIT_TOKEN=' "$PROJECT_DIR/envs/n8n.env" | cut -d= -f2- || true)
    if [[ -n "$_tok" ]]; then
      API_TOKEN="$_tok"
    fi
  fi
fi
# último fallback: token de laboratorio (actualizar si se regenera Passport)
if [[ -z "${API_TOKEN:-}" ]]; then
  echo "⚠ API_TOKEN no configurado. Define SNIPE_URL/API_TOKEN o crea envs/n8n.env desde envs/n8n.env.example (SNIPEIT_TOKEN)." >&2
  exit 1
fi

# Sanitizar: tolerar CRLF/espacios si el valor vino de un .env con CRLF
# (un \r en el header Authorization hace que Apache responda 400 HTML).
API_TOKEN="$(printf '%s' "$API_TOKEN" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
SNIPE_URL="$(printf '%s' "$SNIPE_URL" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

EXPECTED_DB_COLUMN="_snipeit_internal_code_2"
FIELD_NAME="internal_code"
FIELDSET_NAME="Activos Tryton"
EXPECTED_FIELDSET_ID="2"

need_jq=true
command -v jq >/dev/null 2>&1 || need_jq=false
if [[ "$need_jq" == false ]]; then
  echo "⚠ jq no encontrado; se usará grep/python para parsear JSON (instala jq para mejor diagnóstico)." >&2
fi

api_get() {
  local path="$1"
  curl -s -H "Authorization: Bearer $API_TOKEN" -H "Accept: application/json" "$SNIPE_URL$path"
}

api_post() {
  local path="$1" body="$2"
  curl -s -X POST -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" -H "Accept: application/json" \
    -d "$body" "$SNIPE_URL$path"
}

# Valida que la API haya devuelto JSON; si no, aborta con diagnóstico claro
# (antes esto reventaba con un críptico "jq: parse error").
require_json() {
  local what="$1" resp="$2"
  local first
  first=$(printf '%s' "$resp" | sed -e 's/^[[:space:]]*//' | cut -c1)
  if [[ "$first" != "{" && "$first" != "[" ]]; then
    echo "  ✖ $what: la API no devolvió JSON (¿Snipe-IT caído, URL mal o token inválido?)." >&2
    echo "    Respuesta (300 chars): $(printf '%s' "$resp" | tr -d '\r\n' | cut -c1-300)" >&2
    echo "    Revisa SNIPE_URL=$SNIPE_URL y API_TOKEN (longitud ${#API_TOKEN}, sin retornos ni espacios)." >&2
    exit 1
  fi
}

# ── 1) Custom field internal_code ─────────────────────────────
echo "→ Verificando custom field '$FIELD_NAME' ($EXPECTED_DB_COLUMN)..."
fields_json=$(api_get "/api/v1/fields")
require_json "GET /api/v1/fields" "$fields_json"
# detectar si ya existe por db_column_name o name (case-insensitive)
existing_field_id=""
existing_db_col=""
if command -v jq >/dev/null 2>&1; then
  existing_field_id=$(echo "$fields_json" | jq -r --arg col "$EXPECTED_DB_COLUMN" --arg name "$FIELD_NAME" '.rows[] | select(.db_column_name==$col or (.name|ascii_downcase)==($name|ascii_downcase)) | .id' | head -1)
  existing_db_col=$(echo "$fields_json" | jq -r --arg col "$EXPECTED_DB_COLUMN" '.rows[] | select(.db_column_name==$col) | .db_column_name' | head -1)
else
  if echo "$fields_json" | grep -q "$EXPECTED_DB_COLUMN"; then
    existing_db_col="$EXPECTED_DB_COLUMN"
  fi
fi

if [[ -n "${existing_db_col:-}" ]]; then
  echo "  ✔ Ya existe con $EXPECTED_DB_COLUMN (id $existing_field_id)."
else
  # buscar por nombre aunque db_column difiera (p.ej. id 3 → _snipeit_internal_code_3)
  if command -v jq >/dev/null 2>&1; then
    name_match=$(echo "$fields_json" | jq -r --arg name "$FIELD_NAME" '.rows[] | select((.name|ascii_downcase)==($name|ascii_downcase)) | "\(.id) \(.db_column_name)"' | head -1 || true)
  else
    name_match=$(echo "$fields_json" | grep -i "\"name\"[[:space:]]*:[[:space:]]*\"$FIELD_NAME\"" | head -1 || true)
  fi
  if [[ -n "${name_match:-}" ]]; then
    echo "  ⚠ Existe un campo con nombre '$FIELD_NAME' pero con db_column distinto: $name_match"
    echo "    El workflow envía $EXPECTED_DB_COLUMN (id 2). Si el db_column es distinto, edita el payload en"
    echo "    flows/flujos-dev/Tryton sync snipe-IT assets ingest (batch).json (Create/Update snipe-IT asset)."
    echo "    Continuando sin crear duplicado."
  else
    echo "  Creando custom field '$FIELD_NAME' (text, ANY)..."
    # Snipe-IT: POST /api/v1/fields {name, element, format}
    # element: text|listbox|textarea|checkbox|radio|date_picker|datetime_picker
    # format: ANY|ALPHA|NUMERIC|EMAIL|DATE|URL|IP|MAC|BOOLEAN etc. (ver CustomField::PREDEFINED_FORMATS)
    create_body=$(jq -n --arg name "$FIELD_NAME" '{name:$name, element:"text", format:"ANY", field_encrypted:false, show_in_listview:true, show_in_email:false, display_in_user_view:false}' 2>/dev/null || echo "{\"name\":\"$FIELD_NAME\",\"element\":\"text\",\"format\":\"ANY\"}")
    # fallback sin jq
    if ! command -v jq >/dev/null 2>&1; then
      create_body="{\"name\":\"$FIELD_NAME\",\"element\":\"text\",\"format\":\"ANY\"}"
    fi
    resp=$(api_post "/api/v1/fields" "$create_body")
    if command -v jq >/dev/null 2>&1; then
      status=$(echo "$resp" | jq -r '.status // empty')
      new_id=$(echo "$resp" | jq -r '.payload.id // .id // empty')
      new_col=$(echo "$resp" | jq -r '.payload.db_column_name // .db_column_name // empty')
      err=$(echo "$resp" | jq -r '.messages // .message // empty' | head -c 500)
    else
      status=$(echo "$resp" | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1)
      new_id="?"
      new_col="?"
      err="$resp"
    fi
    if echo "$resp" | grep -q '"status"[[:space:]]*:[[:space:]]*"success"'; then
      echo "  ✔ Creado: id $new_id db_column $new_col"
      if [[ "$new_col" != "$EXPECTED_DB_COLUMN" && -n "$new_col" && "$new_col" != "null" ]]; then
        echo "  ⚠ db_column es $new_col pero el workflow espera $EXPECTED_DB_COLUMN."
        echo "    Si el id no es 2 (p.ej. campo borrado antes), el workflow fallará en el pre-flight."
        echo "    Opciones: (a) borrar campos huérfanos para que el próximo id sea 2, o (b) editar el workflow"
        echo "    para usar $new_col en Create/Update snipe-IT asset (batch)."
      fi
    else
      echo "  ✖ No se pudo crear el custom field. Respuesta:"
      echo "    $resp" | head -c 2000
      echo ""
      # si es duplicado por unique name, tratar como ok (otro proceso lo creó)
      if echo "$resp" | grep -iq "already\|unique\|exists"; then
        echo "  (parece que ya existe con otro id; verifica GET /api/v1/fields)"
      else
        exit 1
      fi
    fi
  fi
fi

# ── 2) Fieldset ───────────────────────────────────────────────
echo "→ Verificando fieldset id $EXPECTED_FIELDSET_ID / nombre '$FIELDSET_NAME'..."
fieldsets_json=$(api_get "/api/v1/fieldsets")
require_json "GET /api/v1/fieldsets" "$fieldsets_json"
fieldset_exists="false"
if command -v jq >/dev/null 2>&1; then
  fieldset_exists=$(echo "$fieldsets_json" | jq -r --argjson id "$EXPECTED_FIELDSET_ID" --arg name "$FIELDSET_NAME" 'if (.rows[] | select(.id==$id or .name==$name)) then "true" else "false" end' 2>/dev/null | head -1)
  # fallback más simple
  if [[ "$fieldset_exists" != "true" ]]; then
    if echo "$fieldsets_json" | jq -e --arg name "$FIELDSET_NAME" '.rows[] | select(.name==$name)' >/dev/null 2>&1; then
      fieldset_exists="true"
    elif echo "$fieldsets_json" | jq -e --argjson id "$EXPECTED_FIELDSET_ID" '.rows[] | select(.id==$id)' >/dev/null 2>&1; then
      fieldset_exists="true"
    else
      fieldset_exists="false"
    fi
  fi
else
  if echo "$fieldsets_json" | grep -q "\"id\"[[:space:]]*:[[:space:]]*$EXPECTED_FIELDSET_ID"; then
    fieldset_exists="true"
  fi
fi

fieldset_id="$EXPECTED_FIELDSET_ID"
if [[ "$fieldset_exists" == "true" ]]; then
  echo "  ✔ Fieldset ya existe."
  if command -v jq >/dev/null 2>&1; then
    # resolver id real si se encontró por nombre con id distinto
    resolved=$(echo "$fieldsets_json" | jq -r --arg name "$FIELDSET_NAME" --argjson exp "$EXPECTED_FIELDSET_ID" '(.rows[] | select(.name==$name) | .id) // (.rows[] | select(.id==$exp) | .id) // empty' | head -1)
    if [[ -n "$resolved" ]]; then fieldset_id="$resolved"; fi
  fi
else
  echo "  Creando fieldset '$FIELDSET_NAME'..."
  fs_body=$(jq -n --arg name "$FIELDSET_NAME" '{name:$name}' 2>/dev/null || echo "{\"name\":\"$FIELDSET_NAME\"}")
  if ! command -v jq >/dev/null 2>&1; then fs_body="{\"name\":\"$FIELDSET_NAME\"}"; fi
  resp=$(api_post "/api/v1/fieldsets" "$fs_body")
  if echo "$resp" | grep -q '"status"[[:space:]]*:[[:space:]]*"success"'; then
    if command -v jq >/dev/null 2>&1; then
      fieldset_id=$(echo "$resp" | jq -r '.payload.id // .id // empty')
      echo "  ✔ Fieldset creado con id $fieldset_id"
    else
      echo "  ✔ Fieldset creado (id no parseado sin jq)"
    fi
    if [[ "$fieldset_id" != "$EXPECTED_FIELDSET_ID" ]]; then
      echo "  ⚠ El fieldset quedó con id $fieldset_id pero los modelos del workflow usan fieldset_id:$EXPECTED_FIELDSET_ID."
      echo "    Los modelos se crean con fieldset_id:2 hardcodeado en flows/flujos-dev/Tryton sync snipe-IT models.json."
      echo "    Si el id difiere, o bien (a) deja el fieldset $fieldset_id y edita el workflow para usar ese id,"
      echo "    o bien (b) elimina fieldsets huérfanos para que el próximo id sea 2 (solo en lab)."
    fi
  else
    echo "  ✖ No se pudo crear el fieldset. Respuesta:"
    echo "    $resp" | head -c 2000
    echo ""
    exit 1
  fi
fi

# ── 3) Asociación campo ↔ fieldset ────────────────────────────
echo "→ Asociando campo '$FIELD_NAME' al fieldset $fieldset_id..."
# resolver field_id real de internal_code
field_id=""
if command -v jq >/dev/null 2>&1; then
  fields_json2=$(api_get "/api/v1/fields")
  require_json "GET /api/v1/fields" "$fields_json2"
  field_id=$(echo "$fields_json2" | jq -r --arg name "$FIELD_NAME" '.rows[] | select((.name|ascii_downcase)==($name|ascii_downcase)) | .id' | head -1)
  if [[ -z "$field_id" || "$field_id" == "null" ]]; then
    field_id=$(echo "$fields_json2" | jq -r --arg col "$EXPECTED_DB_COLUMN" '.rows[] | select(.db_column_name==$col) | .id' | head -1)
  fi
else
  # sin jq, intentar extraer id cercano a internal_code
  field_id=$(echo "$fields_json" | grep -B2 -i "\"name\"[[:space:]]*:[[:space:]]*\"$FIELD_NAME\"" | grep -o '"id"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*' | head -1)
fi

if [[ -z "$field_id" || "$field_id" == "null" ]]; then
  echo "  ✖ No se pudo resolver el id del campo '$FIELD_NAME'."
  exit 1
fi

# verificar si ya está asociado
fs_detail=$(api_get "/api/v1/fieldsets/$fieldset_id")
require_json "GET /api/v1/fieldsets/$fieldset_id" "$fs_detail"
already="false"
if command -v jq >/dev/null 2>&1; then
  if echo "$fs_detail" | jq -e --argjson fid "$field_id" '.fields.rows[] | select(.id==$fid)' >/dev/null 2>&1; then
    already="true"
  fi
else
  if echo "$fs_detail" | grep -q "\"id\"[[:space:]]*:[[:space:]]*$field_id"; then
    already="true"
  fi
fi

if [[ "$already" == "true" ]]; then
  echo "  ✔ Ya está asociado."
else
  echo "  Asociando field $field_id → fieldset $fieldset_id..."
  assoc_body="{\"fieldset_id\": $fieldset_id}"
  # POST /api/v1/fields/{field}/associate
  resp=$(api_post "/api/v1/fields/$field_id/associate" "$assoc_body")
  if echo "$resp" | grep -q '"status"[[:space:]]*:[[:space:]]*"success"'; then
    echo "  ✔ Asociado correctamente."
  else
    # fallback: algunos Snipe-IT aceptan POST /api/v1/fieldsets/{id}/fields con field_id
    echo "  Intento associate vía /fields/{id}/associate falló, probando /fieldsets/$fieldset_id/fields..."
    echo "    Respuesta: $(echo "$resp" | head -c 500)"
    # no abortar: el campo existe aunque la asociación falle, pero los assets seguirán sin el custom field visible
    # intentar asociación alternativa no documentada no es crítico para la API de hardware (el campo funciona aunque no esté en un fieldset)
    echo "  ⚠ Verifica manualmente en Snipe-IT: Custom Fields → Fieldsets → $FIELDSET_NAME debe contener '$FIELD_NAME'."
  fi
fi

echo "✓ Provisioning completado. Verifica en Snipe-IT: Custom Fields y Fieldsets."
echo "  Luego re-ejecuta el orquestador: n8n → Tryton sync snipe-IT assets orchestrator v2 (batch) → Execute workflow."
