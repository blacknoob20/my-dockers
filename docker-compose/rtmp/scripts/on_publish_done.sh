#!/bin/sh
STREAM_NAME=$1
LOG_DIR="/var/log/nginx"
PID_DIR="/var/log/nginx"

echo "[$(date)] Stream stopped: $STREAM_NAME" >> ${LOG_DIR}/rtmp.log

# Detener FFmpeg de Facebook
if [ -f ${PID_DIR}/ffmpeg_facebook_${STREAM_NAME}.pid ]; then
    PID=$(cat ${PID_DIR}/ffmpeg_facebook_${STREAM_NAME}.pid)
    if kill -0 $PID 2>/dev/null; then
        kill $PID
        echo "[$(date)] Stopped Facebook FFmpeg PID: $PID" >> ${LOG_DIR}/rtmp.log
    fi
    rm -f ${PID_DIR}/ffmpeg_facebook_${STREAM_NAME}.pid
fi

# Detener FFmpeg de HLS
if [ -f ${PID_DIR}/ffmpeg_hls_${STREAM_NAME}.pid ]; then
    PID=$(cat ${PID_DIR}/ffmpeg_hls_${STREAM_NAME}.pid)
    if kill -0 $PID 2>/dev/null; then
        kill $PID
        echo "[$(date)] Stopped HLS FFmpeg PID: $PID" >> ${LOG_DIR}/rtmp.log
    fi
    rm -f ${PID_DIR}/ffmpeg_hls_${STREAM_NAME}.pid
fi

echo "[$(date)] Cleanup completed for $STREAM_NAME" >> ${LOG_DIR}/rtmp.log