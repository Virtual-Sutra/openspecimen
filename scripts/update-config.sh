#!/bin/bash
# OpenSpecimen configuration update script
# Applies the three most frequent configuration changes without a full Ansible re-run.
# Creates a timestamped backup before every change and restarts the service.
#
# Usage: sudo update-config.sh <command> [args]
#
# Commands:
#   status                     Show current heap, pool size, and app URL
#   heap <min> <max>           Update JVM heap  e.g. heap 512m 4096m
#   db-pool <max-active>       Update JDBC pool max-active  e.g. db-pool 150
#   app-url <url>              Update app.url  e.g. app-url https://os.example.com

set -euo pipefail

TOMCAT_HOME=/usr/local/openspecimen/tomcat-as
SETENV=$TOMCAT_HOME/bin/setenv.sh
CONTEXT=$TOMCAT_HOME/conf/context.xml
OS_PROPS=$TOMCAT_HOME/conf/openspecimen.properties
BACKUP_ROOT=/usr/local/openspecimen/backup/config-changes
SERVICE=openspecimen

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "This script must be run as root (sudo $0 $*)"
}

backup_file() {
  local file="$1"
  local ts; ts=$(date '+%Y%m%d_%H%M%S')
  local dest="$BACKUP_ROOT/$ts"
  mkdir -p "$dest"
  cp "$file" "$dest/$(basename "$file")"
  info "Backed up $(basename "$file") → $dest/"
}

restart_service() {
  info "Restarting $SERVICE..."
  systemctl restart "$SERVICE"
  info "$SERVICE restarted"
}

cmd_status() {
  echo ""
  echo "── JVM Heap ($SETENV) ─────────────────────────"
  grep -oP '\-Xm[sx][0-9]+[mMgG]' "$SETENV" | tr '\n' '  ' && echo ""

  echo ""
  echo "── JDBC Pool ($CONTEXT) ────────────────────────"
  grep -oP 'maxActive="\K[^"]+' "$CONTEXT" | xargs -I{} echo "  maxActive={}" 2>/dev/null || true
  grep -oP 'minIdle="\K[^"]+' "$CONTEXT"   | xargs -I{} echo "  minIdle={}" 2>/dev/null || true

  echo ""
  echo "── App URL ($OS_PROPS) ──────────────────────────"
  if grep -q '^app\.url=' "$OS_PROPS" 2>/dev/null; then
    grep '^app\.url=' "$OS_PROPS"
  else
    echo "  app.url = (not set)"
  fi
  echo ""
}

cmd_heap() {
  local min="${1:-}" max="${2:-}"
  [[ -n "$min" && -n "$max" ]] || die "Usage: $0 heap <min> <max>  e.g. heap 512m 4096m"
  [[ "$min" =~ ^[0-9]+[mMgG]$ ]] || die "Invalid min heap value: $min  (expected e.g. 512m)"
  [[ "$max" =~ ^[0-9]+[mMgG]$ ]] || die "Invalid max heap value: $max  (expected e.g. 4096m)"

  backup_file "$SETENV"
  sed -i "s/-Xms[0-9]*[mMgG]/-Xms${min}/g" "$SETENV"
  sed -i "s/-Xmx[0-9]*[mMgG]/-Xmx${max}/g" "$SETENV"
  info "Heap updated: -Xms${min} -Xmx${max}"
  restart_service
}

cmd_dbpool() {
  local max_active="${1:-}"
  [[ -n "$max_active" ]] || die "Usage: $0 db-pool <max-active>  e.g. db-pool 150"
  [[ "$max_active" =~ ^[0-9]+$ ]] || die "Invalid value: $max_active  (expected integer)"

  backup_file "$CONTEXT"
  sed -i "s/maxActive=\"[0-9]*\"/maxActive=\"${max_active}\"/" "$CONTEXT"
  info "JDBC pool maxActive updated to ${max_active}"
  restart_service
}

cmd_appurl() {
  local url="${1:-}"
  [[ -n "$url" ]] || die "Usage: $0 app-url <url>  e.g. app-url https://os.example.com"
  [[ "$url" =~ ^https?:// ]] || die "URL must start with http:// or https://"

  backup_file "$OS_PROPS"
  if grep -q '^app\.url=' "$OS_PROPS"; then
    sed -i "s|^app\.url=.*|app.url=${url}|" "$OS_PROPS"
  else
    echo "app.url=${url}" >> "$OS_PROPS"
  fi
  info "app.url set to ${url}"
  echo ""
  echo "  ⚠️  Also update in the app UI:"
  echo "     Settings → Common → Allowed Request Origins → add ${url}"
  echo ""
  restart_service
}

require_root
case "${1:-}" in
  status)   cmd_status ;;
  heap)     shift; cmd_heap "$@" ;;
  db-pool)  shift; cmd_dbpool "$@" ;;
  app-url)  shift; cmd_appurl "$@" ;;
  *)
    echo "Usage: sudo $0 <command> [args]"
    echo ""
    echo "  status                  Show current heap, pool size, and app URL"
    echo "  heap <min> <max>        Update JVM heap  (e.g. heap 512m 4096m)"
    echo "  db-pool <max-active>    Update JDBC pool max-active  (e.g. db-pool 150)"
    echo "  app-url <url>           Update app.url  (e.g. app-url https://os.example.com)"
    echo ""
    echo "Each change backs up the modified file to $BACKUP_ROOT/<timestamp>/"
    echo "and restarts the openspecimen service automatically."
    exit 1
    ;;
esac
