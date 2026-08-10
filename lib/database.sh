#!/usr/bin/env bash
# The logs database: a dedicated Postgres container, loopback-only.
#
# Dedicated rather than a database inside an existing application Postgres, so
# that log write volume, WAL and disk accounting never touch production data, and
# uninstall is a container removal reporting exact bytes freed.

set -euo pipefail
. /opt/ai-terminal-logs/lib/common.sh

install_db() {
  local created=0
  if docker ps -a --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
    log "logs database container exists"
    docker start "$PG_CONTAINER" >/dev/null 2>&1 || true
  else
    created=1
    local pass
    # No `head -c` at the end of the pipeline: it closes the pipe as soon as it
    # has enough bytes, so `base64`/`tr` take SIGPIPE and `pipefail` aborts the
    # install at random. Trim with a parameter expansion instead.
    pass=$(head -c 48 /dev/urandom | base64 | tr -d '/+=\n')
    pass=${pass:0:24}

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
  local i state
  for i in $(seq 1 90); do
    docker exec "$PG_CONTAINER" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1 && break

    # A container that has already exited will never become ready, so stop
    # waiting the moment that is true rather than burning the full 90 seconds
    # and then reporting a timeout for what was an immediate crash.
    state=$(docker inspect -f '{{.State.Status}}' "$PG_CONTAINER" 2>/dev/null || echo missing)
    case "$state" in
      exited|dead|missing) break ;;
    esac
    sleep 1
  done

  docker exec "$PG_CONTAINER" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1 && return 0

  # Print the evidence here. The installer is usually run from the app over SSH,
  # where "check: docker logs …" is a dead end — the operator sees the failure in
  # a panel and has no shell in front of them. Whatever killed Postgres has to
  # arrive in the same stream as the error.
  local oom
  oom=$(docker inspect -f '{{.State.OOMKilled}}' "$PG_CONTAINER" 2>/dev/null || echo unknown)

  warn "postgres did not become ready — container state below"
  docker inspect -f \
    'state={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}' \
    "$PG_CONTAINER" >&2 2>/dev/null || true
  echo "--- docker logs $PG_CONTAINER (last 40 lines) ---" >&2
  docker logs --tail 40 "$PG_CONTAINER" >&2 2>&1 || true
  echo "--- end ---" >&2

  # Clean up a container and volume this run created, so a re-run starts from
  # scratch instead of hitting the same half-initialised data directory forever.
  # Only when `created=1`: an existing database holds collected logs, and losing
  # those to an automatic retry would be far worse than a failed install.
  if [ "$created" -eq 1 ]; then
    docker rm -f "$PG_CONTAINER"  >/dev/null 2>&1 || true
    docker volume rm "$PG_VOLUME" >/dev/null 2>&1 || true
    warn "removed the partially created database — re-running the installer is safe"
  fi

  # OOM is the one cause worth naming outright: the memory cap is ours, the box
  # is small, and the generic message would send someone hunting a Postgres bug.
  if [ "$oom" = "true" ]; then
    die "postgres was killed by the 512 MB container memory limit.
     Free memory or add swap, then re-run the installer."
  fi
  die "postgres did not become ready — see the container log above"
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
