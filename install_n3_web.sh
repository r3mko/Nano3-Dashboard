#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

HANDLER_SRC="$SCRIPT_DIR/tools/app/cgminer_api_proxy_handler.sh"
HANDLER_DST="/mnt/heater/app/cgminer_api_proxy_handler.sh"

INIT_SRC="$SCRIPT_DIR/tools/init_d/S92cgminer_api_proxy.sh"
INIT_DST="/etc/init.d/S92cgminer_api_proxy.sh"

WEB_SRC_DIR="$SCRIPT_DIR/src"
WEB_DST_DIR="/mnt/heater/www/html"
WEB_BACKUP="/mnt/heater/www/html_backup.tar"

log() {
  printf '[install] %s\n' "$1"
}

require_file() {
  if [ ! -f "$1" ]; then
    printf '[install] ERROR: missing file: %s\n' "$1" >&2
    exit 1
  fi
}

require_dir() {
  if [ ! -d "$1" ]; then
    printf '[install] ERROR: missing directory: %s\n' "$1" >&2
    exit 1
  fi
}

require_file "$HANDLER_SRC"
require_file "$INIT_SRC"
require_dir "$WEB_SRC_DIR"
require_dir "$WEB_DST_DIR"

log "Installing cgminer API proxy handler -> $HANDLER_DST"
cp "$HANDLER_SRC" "$HANDLER_DST"
chmod 755 "$HANDLER_DST"
chown admin:admin "$HANDLER_DST" 2>/dev/null || true

log "Installing init script -> $INIT_DST"
cp "$INIT_SRC" "$INIT_DST"
chmod 644 "$INIT_DST"
chown root:root "$INIT_DST" 2>/dev/null || true

log "Starting proxy service"
if ! sh "$INIT_DST" start; then
  log "Start failed, trying restart"
  sh "$INIT_DST" restart
fi

log "Backing up web root -> $WEB_BACKUP"
tar -cf "$WEB_BACKUP" -C "$(dirname "$WEB_DST_DIR")" "$(basename "$WEB_DST_DIR")"

log "Copying HTML files -> $WEB_DST_DIR"
COPIED=0
for SRC in "$WEB_SRC_DIR"/*.html; do
  [ -e "$SRC" ] || continue
  NAME=$(basename "$SRC")
  cp "$SRC" "$WEB_DST_DIR/$NAME"
  chown admin:admin "$WEB_DST_DIR/$NAME" 2>/dev/null || true
  COPIED=$((COPIED + 1))
done

log "Copied $COPIED HTML files"
log "Done"
