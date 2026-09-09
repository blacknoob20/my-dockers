#!/bin/bash

# ================================
# CONFIGURACIÓN
# ================================
SNIPE_URL="http://localhost:8080"        # <-- Cambia esto
API_TOKEN="${API_TOKEN:-your_snipeit_token_here}"  # <-- Cambia esto o exporta API_TOKEN (ver envs/n8n.env.example SNIPEIT_TOKEN)

# ================================
# LISTA DE FABRICANTES A CREAR
# ================================
fabricantes=(
  # Equipos de red
  "Cisco"
  "MikroTik"
  "Ubiquiti"
  "TP-Link"
  "D-Link"
  "Fortinet"
  "Juniper"
  "Aruba"

  # Impresión y digitalización
  "Epson"
  "Brother"
  "Canon"
  "Kyocera"
  "Xerox"
  "Ricoh"
  "Lexmark"

  # Telefonía IP y videoconferencia
  "Yealink"
  "Grandstream"
  "Fanvil"
  "Avaya"
  # Polycom ya existe

  # UPS y energía
  "APC"
  "Forza"
  "CDP"
  "Eaton"
  "Tripp Lite"

  # Videovigilancia
  "Hikvision"
  "Dahua"
  "Axis"
  "Uniview"

  # Servidores y almacenamiento
  "HPE"
  # Dell y Lenovo ya existen
  "Supermicro"
  "Synology"
  "QNAP"
  "NetApp"

  # Monitores y periféricos
  "ViewSonic"
  "AOC"
  "BenQ"
  "Logitech"
  "Genius"

  # Equipos biométricos y control de acceso
  "ZKTeco"
  "Suprema"
  "Anviz"
)

# ================================
# CREACIÓN MASIVA
# ================================
echo "Creando fabricantes en Snipe-IT..."
echo "--------------------------------"

for nombre in "${fabricantes[@]}"; do
  echo -n "Creando fabricante: $nombre... "

  response=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$SNIPE_URL/api/v1/manufacturers" \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"$nombre\"
    }")

  if [ "$response" == "200" ] || [ "$response" == "201" ]; then
    echo "✔ OK"
  else
    echo "✖ Error (HTTP $response)"
  fi
done

echo "--------------------------------"
echo "Proceso completado."
