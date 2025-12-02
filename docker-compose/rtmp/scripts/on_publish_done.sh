#!/bin/sh

STREAM_NAME="$1"
LOG_FILE="/var/log/nginx/rtmp.log"
FACEBOOK_PIDFILE="/var/log/nginx/ffmpeg_facebook_${STREAM_NAME}.pid"
HLS_PIDFILE="/var/log/nginx/ffmpeg_hls_${STREAM_NAME}.pid"
HLS_DIR="/opt/data/hls/${STREAM_NAME}"

log_msg() {
  echo "[$(date)] $1" >> "$LOG_FILE" 2>/dev/null || echo "[$(date)] $1"
}

# Ensure log exists
touch "$LOG_FILE" 2>/dev/null || true

log_msg "Stream stopped: ${STREAM_NAME}"

# Kill facebook process if exists
if [ -f "$FACEBOOK_PIDFILE" ]; then
  PID=$(cat "$FACEBOOK_PIDFILE" 2>/dev/null)
  if [ -n "$PID" ]; then
    if kill -0 "$PID" 2>/dev/null; then
      log_msg "Killing Facebook process PID $PID"
      kill -9 "$PID" 2>/dev/null || true
    else
      log_msg "Facebook process PID $PID not running"
    fi
  fi
  rm -f "$FACEBOOK_PIDFILE" 2>/dev/null || true
fi

# Kill HLS process if exists
if [ -f "$HLS_PIDFILE" ]; then
  PID=$(cat "$HLS_PIDFILE" 2>/dev/null)
  if [ -n "$PID" ]; then
    if kill -0 "$PID" 2>/dev/null; then
      log_msg "Killing HLS process PID $PID"
      kill -9 "$PID" 2>/dev/null || true
    else
      log_msg "HLS process PID $PID not running"
    fi
  fi
  rm -f "$HLS_PIDFILE" 2>/dev/null || true
fi

# Optionally remove HLS files
if [ -d "$HLS_DIR" ]; then
  log_msg "Removing HLS directory $HLS_DIR"
  rm -rf "$HLS_DIR" 2>/dev/null || log_msg "WARN: could not remove $HLS_DIR"
fi

log_msg "on_publish_done completed for ${STREAM_NAME}"
exit 0