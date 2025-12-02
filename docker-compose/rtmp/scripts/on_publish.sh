#!/bin/sh

# Script ejecutado cuando un stream inicia en nginx-rtmp
# Se llama con: exec_publish /opt/scripts/on_publish.sh $name;

STREAM_NAME=$1
LOG_FILE="/var/log/nginx/rtmp.log"

# Asegurar que el log existe y es escribible
touch "$LOG_FILE" 2>/dev/null || true

log_msg() {
    echo "[$(date)] $1" >> "$LOG_FILE" 2>/dev/null || echo "[$(date)] $1"
}

log_msg "Stream started: $STREAM_NAME"

# Leer Facebook key desde archivo de configuración
FACEBOOK_KEY_FILE="/opt/config/facebook.key"
if [ -f "$FACEBOOK_KEY_FILE" ]; then
    FACEBOOK_KEY=$(cat "$FACEBOOK_KEY_FILE" | tr -d '\n\r ')
    log_msg "Facebook key loaded from config file"
else
    log_msg "ERROR: Facebook key file not found at $FACEBOOK_KEY_FILE"
    exit 0
fi

# URL del stream local
RTMP_URL="rtmp://127.0.0.1:1935/stream/${STREAM_NAME}"

# Directorio HLS
HLS_DIR="/opt/data/hls/${STREAM_NAME}"
mkdir -p "$HLS_DIR" 2>/dev/null || true

# Facebook RTMPS URL
FACEBOOK_URL="rtmps://live-api-s.facebook.com:443/rtmp/${FACEBOOK_KEY}"

# Iniciar restream a Facebook en background con nohup
log_msg "Starting Facebook restream for $STREAM_NAME"
nohup ffmpeg -i "$RTMP_URL" \
    -c:v copy -c:a aac -b:a 128k \
    -f flv "$FACEBOOK_URL" \
    </dev/null >/var/log/nginx/ffmpeg_facebook.log 2>&1 &
FACEBOOK_PID=$!
log_msg "Facebook FFmpeg PID: $FACEBOOK_PID"

# Iniciar transcodificación HLS en background con nohup
log_msg "Starting HLS transcoding for $STREAM_NAME"
nohup ffmpeg -i "$RTMP_URL" \
    -filter_complex "[0:v]split=4[v1][v2][v3][v4]; \
        [v1]scale=1280:720[720p]; \
        [v2]scale=854:480[480p]; \
        [v3]scale=640:360[360p]; \
        [v4]scale=426:240[240p]" \
    -map "[720p]" -c:v:0 libx264 -b:v:0 2800k -preset veryfast \
    -map "[480p]" -c:v:1 libx264 -b:v:1 1400k -preset veryfast \
    -map "[360p]" -c:v:2 libx264 -b:v:2 800k -preset veryfast \
    -map "[240p]" -c:v:3 libx264 -b:v:3 400k -preset veryfast \
    -map a:0 -c:a:0 aac -b:a:0 128k \
    -map a:0 -c:a:1 aac -b:a:1 128k \
    -map a:0 -c:a:2 aac -b:a:2 64k \
    -map a:0 -c:a:3 aac -b:a:3 64k \
    -f hls \
    -hls_time 4 \
    -hls_list_size 5 \
    -hls_flags delete_segments \
    -var_stream_map "v:0,a:0 v:1,a:1 v:2,a:2 v:3,a:3" \
    -master_pl_name master.m3u8 \
    -hls_segment_filename "${HLS_DIR}/v%v/segment%d.ts" \
    "${HLS_DIR}/v%v/playlist.m3u8" \
    </dev/null >/var/log/nginx/ffmpeg_hls.log 2>&1 &
HLS_PID=$!
log_msg "HLS FFmpeg PID: $HLS_PID"

log_msg "All processes started successfully"
exit 0