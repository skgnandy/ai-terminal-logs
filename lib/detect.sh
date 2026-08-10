#!/usr/bin/env bash
# Environment detection. Never assume paths — a wrong guess installs an agent that
# silently collects nothing, which is worse than failing.

set -euo pipefail
. /opt/ai-terminal-logs/lib/common.sh

detect() {
  HOST_NAME=$(hostname)
  TZ_NAME=$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)

  PM2_LOG_DIRS=()
  for d in /root/.pm2/logs /home/*/.pm2/logs; do
    [ -d "$d" ] && PM2_LOG_DIRS+=("$d")
  done

  HAS_DOCKER=0
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then HAS_DOCKER=1; fi

  HAS_JOURNAL=0
  command -v journalctl >/dev/null 2>&1 && HAS_JOURNAL=1

  NGINX_LOG_DIR=""
  [ -d /var/log/nginx ] && NGINX_LOG_DIR=/var/log/nginx

  # Reuse ports an existing install already claimed. Re-running the installer must
  # never silently move the endpoint the app is connected to.
  if [ -f "$ENV_FILE" ] && grep -q '^PG_PORT=' "$ENV_FILE"; then
    PG_PORT=$(grep '^PG_PORT='       "$ENV_FILE" | cut -d= -f2)
    RECEIVER_PORT=$(grep '^RECEIVER_PORT=' "$ENV_FILE" | cut -d= -f2)
    log "reusing ports from existing install: db=$PG_PORT receiver=$RECEIVER_PORT"
  else
    PG_PORT=$(pick_port "${PG_PORT_WANTED:-$PG_PORT_DEFAULT}")
    RECEIVER_PORT=$(pick_port "$RECEIVER_PORT_DEFAULT")
    [ "$PG_PORT" = "${PG_PORT_WANTED:-$PG_PORT_DEFAULT}" ] \
      || warn "port ${PG_PORT_WANTED:-$PG_PORT_DEFAULT} busy — using $PG_PORT"
  fi

  log "host=$HOST_NAME tz=$TZ_NAME docker=$HAS_DOCKER journal=$HAS_JOURNAL pm2_dirs=${#PM2_LOG_DIRS[@]} db_port=$PG_PORT"

  [ "$HAS_DOCKER" -eq 1 ] || die "docker is required — the logs database runs as a container"
  command -v python3 >/dev/null 2>&1 || die "python3 is required (standard library only)"

  if [ ${#PM2_LOG_DIRS[@]} -eq 0 ] && [ "$HAS_JOURNAL" -eq 0 ]; then
    warn "no PM2 log directory and no journald — only Docker logs will be collected"
  fi

  # Cross-machine timelines silently break under clock skew, which is the worst
  # kind of failure: the data looks fine and is wrong.
  if ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
    warn "system clock is not NTP-synchronised — cross-machine timelines will be wrong"
  fi

  export HOST_NAME TZ_NAME HAS_DOCKER HAS_JOURNAL NGINX_LOG_DIR PG_PORT RECEIVER_PORT
}

[ "${BASH_SOURCE[0]}" = "$0" ] && detect
