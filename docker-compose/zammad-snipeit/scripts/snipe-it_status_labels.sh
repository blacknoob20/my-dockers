#!/bin/bash

# ================================
# CONFIGURACIÓN
# ================================
SNIPE_URL="http://localhost:8080"         # <-- Cambia esto
API_TOKEN="${API_TOKEN:-your_snipeit_token_here}"  # <-- Cambia esto o exporta API_TOKEN (ver envs/n8n.env.example SNIPEIT_TOKEN)

# ================================
# LISTA DE ESTADOS A CREAR
# ================================
declare -A estados=(
  ["Disponible"]="deployable"
  ["Asignado"]="assigned"
  ["En reparación"]="pending"
  ["En mantenimiento"]="pending"
  ["Prestado"]="pending"
  ["Pendiente de baja"]="pending"
  ["Dado de baja"]="archived"
  ["Extraviado"]="pending"
  ["En bodega"]="deployable"
)

# ================================
# CREACIÓN MASIVA
# ================================
echo "Creando estados en Snipe-IT..."
echo "--------------------------------"

for nombre in "${!estados[@]}"; do
  tipo="${estados[$nombre]}"

  echo -n "Creando estado: $nombre ($tipo)... "

  response=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$SNIPE_URL/api/v1/statuslabels" \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"$nombre\",
      \"type\": \"$tipo\"
    }")

  if [ "$response" == "200" ] || [ "$response" == "201" ]; then
    echo "✔ OK"
  else
    echo "✖ Error (HTTP $response)"
  fi
done

echo "--------------------------------"
echo "Proceso completado."
