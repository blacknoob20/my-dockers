FROM alpine:3.19

# Instalar dependencias
RUN apk add --no-cache \
  nginx \
  nginx-mod-rtmp \
  ffmpeg \
  ca-certificates \
  openssl \
  && rm -rf /var/cache/apk/*

# Crear directorios necesarios con permisos correctos
RUN mkdir -p /opt/data/hls \
  && mkdir -p /www/static \
  && mkdir -p /var/log/nginx \
  && mkdir -p /run/nginx \
  && mkdir -p /opt/scripts \
  && mkdir -p /opt/config \
  && touch /var/log/nginx/rtmp.log \
  && touch /var/log/nginx/ffmpeg_facebook.log \
  && touch /var/log/nginx/ffmpeg_hls.log \
  && chmod 777 /var/log/nginx \
  && chmod 666 /var/log/nginx/*.log \
  && chmod 777 /opt/data/hls

# Copiar archivo de estadísticas RTMP
COPY stat.xsl /www/static/stat.xsl

# Copiar configuración de nginx
COPY nginx.conf /etc/nginx/nginx.conf

# Copiar scripts
COPY scripts/ /opt/scripts/
RUN chmod +x /opt/scripts/*.sh

# Exponer puertos
EXPOSE 1935 80

# Comando de inicio
CMD ["nginx", "-g", "daemon off;"]