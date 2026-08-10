#!/usr/bin/env bash
# The logs database: a dedicated Postgres container, loopback-only.
#
# Dedicated rather than a database inside an existing application Postgres, so
# that log write volume, WAL and disk accounting never touch production data, and
# uninstall is a container removal reporting exact bytes freed.

set -euo pipefail
. /opt/ai-terminal-logs/lib/common.sh

install_db() {
  if docker ps -a --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
    log "logs database container exists"
    docker start "$PG_CONTAINER" >/dev/null 2>&1 || true
  else
    local pass
    pass=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 24)

    log "creating logs database on 127.0.0.1:$PG_PORT"
    # Tuned for a log workload, not OLTP: small buffers, few connections, and a
    # statement timeout so one careless query from the app cannot pin the box.
    docker run -d \
      --name "$PG_CONTAINER" \
      --restart unless-stopped \
      -p "127.0.0.1:$PG_PORT:5432" \
      -v "$PG_VOLUME:/var/lib/postgresql/data" \
      -e POSTGRES_USER="$PG_USER" \
      -e POSTGRES_PASSWORD="$pass" \
      -e POSTGRES_DB="$PG_DB" \
      --memory=512m \
      postgres:17-alpine \
        -c shared_buffers=128MB \
        -c work_mem=8MB \
        -c maintenance_work_mem=64MB \
        -c max_connections=20 \
        -c statement_timeout=30000 \
        -c idle_in_transaction_session_timeout=60000 \
        -c synchronous_commit=off \
      >/dev/null

    install -d -m 700 "$ETC"
    printf '%s' "$pass" > "$ETC/pgpass"
    chmod 600 "$ETC/pgpass"
  fi

  log "waiting for postgres"
  local i
  for i in $(seq 1 90); do
    docker exec "$PG_CONTAINER" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1 && break
    sleep 1
  done
  docker exec "$PG_CONTAINER" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1 \
    || die "postgres did not become ready — check: docker logs $PG_CONTAINER"
}

apply_schema() {
  log "applying schema"
  pgx -f - < "$SQL_DIR/schema.sql" >/dev/null \
    || die "schema failed to apply"

  local v
  v=$(pgq -c "SELECT max(version) FROM schema_version;")
  log "schema version $v"
}

# `if`, not `&&` — see the note in preflight.sh. As the last statement in a
# sourced file the `&&` form returns 1 and silently aborts the caller.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  install_db
  apply_schema
fi
