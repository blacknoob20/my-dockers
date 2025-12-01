#!/bin/bash

# Script para actualizar la IP permitida en el servidor RTMP
# Uso: ./update-rtmp-ip.sh

VPS_USER="crguerrero"
VPS_HOST="74.208.171.187"
NGINX_CONF="/home/crguerrero/rtmp-server/nginx.conf"

# Obtener tu IP pública actual
echo "🔍 Obteniendo tu IP pública actual..."
NEW_IP=$(curl -s ifconfig.me)

if [ -z "$NEW_IP" ]; then
    echo "❌ Error: No se pudo obtener tu IP pública"
    exit 1
fi

echo "📍 Tu IP actual es: $NEW_IP"

# Verificar si la IP ya está configurada
echo "🔄 Conectando al VPS..."
CURRENT_IP=$(ssh ${VPS_USER}@${VPS_HOST} "grep 'allow publish' ${NGINX_CONF} | awk '{print \$3}' | tr -d ';'")

echo "📍 IP configurada en el servidor: $CURRENT_IP"

if [ "$NEW_IP" == "$CURRENT_IP" ]; then
    echo "✅ Tu IP ya está actualizada. No se requieren cambios."
    exit 0
fi

# Actualizar la IP en el archivo de configuración
echo "🔧 Actualizando IP de $CURRENT_IP a $NEW_IP..."
ssh ${VPS_USER}@${VPS_HOST} "sed -i 's/allow publish ${CURRENT_IP};/allow publish ${NEW_IP};/' ${NGINX_CONF}"

# Verificar el cambio
UPDATED_IP=$(ssh ${VPS_USER}@${VPS_HOST} "grep 'allow publish' ${NGINX_CONF} | awk '{print \$3}' | tr -d ';'")

if [ "$NEW_IP" == "$UPDATED_IP" ]; then
    echo "✅ IP actualizada correctamente en nginx.conf"

    # Reiniciar el contenedor
    echo "🔄 Reiniciando contenedor RTMP..."
    ssh ${VPS_USER}@${VPS_HOST} "cd /home/crguerrero/rtmp-server && docker compose restart"

    echo ""
    echo "🎉 ¡Listo! Tu servidor RTMP ahora acepta streams desde: $NEW_IP"
else
    echo "❌ Error: No se pudo actualizar la IP"
    exit 1
fi
