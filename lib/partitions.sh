#!/usr/bin/env bash
# Partition maintenance — the mechanism behind retention.
#
# Runs in three situations:
#   immediate  — `logagent set --json '{"days":N}'` calls this directly, so a
#                retention change frees disk at once rather than tomorrow
#   daily      — systemd timer, Persistent=true
#   post-install
#
# Partitions are created SEVEN days ahead, not one. A single failed run must never
# leave a day without a partition, because every insert would then fail and the
# loss would be silent.

set -euo pipefail
. /opt/ai-terminal-logs/lib/common.sh
load_env

AHEAD=7

retention_for() {
  case "$1" in
    log_entries)  json_get "$CONF" days 0 ;;   # user-set, may be null → 0 = keep all
    metrics)      echo 30 ;;                    # ~5 MB/day; long history is free
    host_metrics) echo 90 ;;
    *)            echo 0 ;;
  esac
}

create_ahead() {
  local tbl="$1" i from to suffix
  for i in $(seq 0 "$AHEAD"); do
    suffix=$(date -u -d "+$i day" +%Y_%m_%d)
    from=$(date -u -d "+$i day" +%Y-%m-%d)
    to=$(date -u -d "+$((i + 1)) day" +%Y-%m-%d)
    # UNLOGGED: skipping WAL halves write cost. Losing recent rows on an unclean
    # crash is an acceptable trade for logs; doubling IO on a small VPS is not.
    pgq -c "CREATE UNLOGGED TABLE IF NOT EXISTS ${tbl}_${suffix}
            PARTITION OF ${tbl} FOR VALUES FROM ('${from}') TO ('${to}');" >/dev/null
  done
}

drop_expired() {
  local tbl="$1" keep="$2" cutoff old t
  [ "$keep" -gt 0 ] 2>/dev/null || return 0

  cutoff="${tbl}_$(date -u -d "-${keep} day" +%Y_%m_%d)"
  old=$(pgq -c "SELECT c.relname
                FROM pg_class c
                JOIN pg_inherits i ON i.inhrelid = c.oid
                JOIN pg_class p    ON p.oid = i.inhparent
                WHERE p.relname = '${tbl}' AND c.relname < '${cutoff}'
                ORDER BY c.relname;")

  for t in $old; do
    # DROP, never DELETE: this returns disk immediately. DELETE would leave dead
    # tuples and grow the database before it shrank.
    pgq -c "DROP TABLE IF EXISTS ${t};" >/dev/null
    audit drop_partition "$t"
    log "dropped $t"
  done
}

main() {
  docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" || {
    warn "logs database not running — skipping partition maintenance"
    exit 0
  }

  local tbl keep
  for tbl in log_entries metrics host_metrics; do
    create_ahead "$tbl"
    keep=$(retention_for "$tbl")
    drop_expired "$tbl" "$keep"
  done
}

main "$@"
