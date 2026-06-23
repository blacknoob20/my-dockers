#!/bin/bash

# ================================
# CONFIGURACIÓN
# ================================
SNIPE_URL="http://localhost:8080"         # <-- Cambia esto
API_TOKEN="eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.eyJhdWQiOiIxIiwianRpIjoiYTAwODEzMWIzYWU4NjJmMjY1ZGJjN2I2YjQ5YmQ4ZTMyNjcxNmM3MWUzNjYwYjgyNzA3ZmMwZTAxMDhlODU3ZDhhZjdiNzdjNjAyZWQxNzAiLCJpYXQiOjE3ODE3OTM2NTguNzkwNjQsIm5iZiI6MTc4MTc5MzY1OC43OTA2NDIsImV4cCI6MjQxMjk0NTY1OC43NjIyNTEsInN1YiI6IjEiLCJzY29wZXMiOltdfQ.56-cbYIfh4s8k9Uru4Q9rmMbuEJ9EB7mC-ZMFANVmuELk9c8odm6S_jL_t6upU4pEXlZlLll5QUaSS7xILVC0Gln7ego2SC_W08XYm9uIjpTnn8uXbI75HtFuwtl_-DFjq4jRxIOth2alcYGrwfZmoeYHnSaSKKXNkumG4ikvEHbtO-HuOHoPpHGcesQoUNT7sUn9QLo7K7xLzrSKk6YQft5cNj_HqrcgfVQ440mW_skZ8yPM8rfyqG2JUyGf2fVBQUMV6MLQKN_lvqEIiesoy_ojcvYOfDDCJDOBnMHiA8ExEW9ftd8dJa-Hwl3iwcwXIyInB5IKmC-pYhmcsX3mkykbF6ro-ULWmiObVxXXZNUbJoAc_lA_sPgjMWZSXQvMNJw0_imt2_of7Sv0RsvpiJE0QMGoCndGUfgTxP8fIJ89nY2gKH2Mqf5gXguWBUQd5LmvkIPz79hFdUx8oJGzx-RSSeIekhpgkIuhMvh8bWAkPQV-zvup2zRm0C882F8dQ0GbDK0epYJjQVt6HaSmuQepW33xCDhlhz9Ow3Vqt_YLn3fuPuHYZ7CM-GCI0V0d1fYZNtySkO5Tr_k4gLWERaGvD28bCrWHDM3ad31aerwddl99BEQX28JL9q34uglMgLXLM5tEuDyAr97nrdolKHRdAfTpcASv5Kle1-0_sw"             # <-- Cambia esto

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
