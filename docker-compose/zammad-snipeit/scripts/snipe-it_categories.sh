#!/bin/bash

# ================================
# CONFIGURACIÓN
# ================================
SNIPE_URL="http://localhost:8080"          # <-- Cambia esto
API_TOKEN="${API_TOKEN:-your_snipeit_token_here}"  # <-- Cambia esto o exporta API_TOKEN (ver envs/n8n.env.example SNIPEIT_TOKEN)

# ================================
# LISTA DE CATEGORÍAS A CREAR
# ================================
categorias=(
  "Computadoras"
  "Laptops"
  "Impresoras"
  "Escáneres"
  "UPS"
  "Switches"
  "Routers"
  "Cámaras"
  "Monitores"
  "Telefonía IP"
)

# ================================
# CREACIÓN MASIVA
# ================================
echo "Creando categorías en Snipe-IT..."
echo "--------------------------------"

for nombre in "${categorias[@]}"; do
  echo -n "Creando categoría: $nombre... "

  response=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$SNIPE_URL/api/v1/categories" \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"$nombre\",
      \"category_type\": \"asset\"
    }")

  if [ "$response" == "200" ] || [ "$response" == "201" ]; then
    echo "✔ OK"
  else
    echo "✖ Error (HTTP $response)"
  fi
done

echo "--------------------------------"
echo "Proceso completado."
