#!/bin/bash

# ============================================================
# TRYTON API — Listado de Activos via JSON-RPC
# ============================================================
# Descubierto analizando el cliente SAO (tryton-sao.min.js)
#
# Protocolo correcto:
#   Content-Type: application/json
#   URL: POST /<database>/
#   Auth: Authorization: Session <base64(user:uid:session)>
#
# Modelo: asset (NO account.asset)
# Total: ~19,339 activos
# ============================================================

# --- CONFIGURACIÓN ---
TRYTON_URL="${TRYTON_URL:-http://192.168.56.102:8000}"
TRYTON_DB="${TRYTON_DB:-dbegoblocal}"
TRYTON_USER="${TRYTON_USER:-svc_n8n}"
TRYTON_PASS="${TRYTON_PASS:-12345678}"
DELAY=2

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

tryton_rpc() {
  local method="$1" params="$2" auth="$3"
  local args=(-s --connect-timeout 5 --max-time 15 -w "\n%{http_code}"
    -X POST "${TRYTON_URL}/${TRYTON_DB}/"
    -H "Content-Type: application/json"
    -d "{\"id\":0,\"method\":\"${method}\",\"params\":${params}}")
  [ -n "$auth" ] && args+=(-H "Authorization: Session ${auth}")
  curl "${args[@]}"
}

echo "============================================"
echo "  TRYTON API — Listado de Activos"
echo "============================================"
echo ""

# --- LOGIN ---
echo -e "${YELLOW}[1/4]${NC} Login..."
RESP=$(tryton_rpc "common.db.login" \
  "[\"${TRYTON_USER}\",{\"password\":\"${TRYTON_PASS}\",\"device_cookie\":null},\"es\"]")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

if [ "$CODE" != "200" ]; then
  echo -e "${RED}ERROR HTTP $CODE${NC}"; echo "$BODY"; exit 1
fi

USER_ID=$(echo "$BODY" | jq -r '.result[0]')
SESSION=$(echo "$BODY" | jq -r '.result[1]')

if [ "$USER_ID" == "null" ] || [ -z "$USER_ID" ]; then
  echo -e "${RED}Login fallido:${NC}"; echo "$BODY" | jq .; exit 1
fi

AUTH=$(echo -n "${TRYTON_USER}:${USER_ID}:${SESSION}" | base64 -w0)
echo -e "${GREEN}OK${NC} — User ID: $USER_ID"
sleep "$DELAY"

# --- CONTEO ---
echo ""
echo -e "${YELLOW}[2/4]${NC} Contando activos..."
RESP=$(tryton_rpc "model.asset.search_read" \
  "[[],0,null,null,[\"id\"],{}]" "$AUTH")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
TOTAL=$(echo "$BODY" | jq '.result | length')
echo -e "${GREEN}OK${NC} — Total: $TOTAL activos"
sleep "$DELAY"

# --- ESTADOS ---
echo ""
echo -e "${YELLOW}[3/4]${NC} Distribución por estado..."
RESP=$(tryton_rpc "model.asset.search_read" \
  "[[],0,null,null,[\"id\",\"asset_state\"],{}]" "$AUTH")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

if [ "$CODE" == "200" ]; then
  echo "$BODY" | jq -r '.result[].asset_state' | sort | uniq -c | sort -rn
fi
sleep "$DELAY"

# --- MUESTRA ---
echo ""
echo -e "${YELLOW}[4/4]${NC} Muestra de 5 activos..."
RESP=$(tryton_rpc "model.asset.search_read" \
  "[[],0,5,null,[\"id\",\"code\",\"name\",\"asset_state\",\"asset_type_new\",\"actual_value\",\"category.rec_name\",\"company.rec_name\",\"current_owner.rec_name\"],{}]" "$AUTH")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

if [ "$CODE" == "200" ]; then
  echo "$BODY" | jq -r '.result[] | "[\(.code)] \(.name) | Estado: \(.asset_state) | Valor: $\(.actual_value.decimal) | Titular: \(.["current_owner."].rec_name // "N/A")"'
fi

echo ""
echo "============================================"
echo "  FIN"
echo "============================================"
