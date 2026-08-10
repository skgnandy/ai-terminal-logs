#!/usr/bin/env bash
# Emergency disk guard.
#
# Time-based retention cannot stop a sudden log flood: a single misbehaving
# service can fill the remaining disk long before the daily timer runs. This is
# the backstop that guarantees the agent degrades — shedding old data, then
# stopping — instead of taking the machine down with it.
#
# A monitoring tool that causes an outage is worse than no monitoring tool.

set -euo pipefail
. /opt/ai-terminal-logs/lib/common.sh
load_env

THRESH_TRIM=15   # % free — drop one partition
THRESH_HARD=10   # % free — drop two
THRESH_STOP=8    # % free — stop collecting entirely

pct_free() {
  local used
  used=$(df --output=pcent / | tail -1 | tr -dc '0-9')
  echo $((100 - used))
}

oldest_partition() {
  pgq -c "SELECT c.relname
          FROM pg_class c
          JOIN pg_inherits i ON i.inhrelid = c.oid
          JOIN pg_class p    ON p.oid = i.inhparent
          WHERE p.relname = 'log_entries'
          ORDER BY c.relname ASC LIMIT 1;"
}

drop_oldest() {
  local t
  t=$(oldest_partition)
  [ -n "$t" ] || return 1
  pgq -c "DROP TABLE IF EXISTS ${t};" >/dev/null
  audit emergency_drop "$t"
  log "emergency drop: $t"
  echo "$t"
}

main() {
  docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" || exit 0

  local free dropped
  free=$(pct_free)

  if [ "$free" -lt "$THRESH_STOP" ]; then
    systemctl stop vector >/dev/null 2>&1 || true
    python3 - "$CONF" <<'PY' || true
import json, sys
p = sys.argv[1]
c = json.load(open(p)); c["paused"] = True
json.dump(c, open(p, "w"), indent=2)
PY
    audit paused "disk ${free}% free"
    notify "CRITICAL: ${HOST_NAME:-host} disk ${free}% free — log collection PAUSED"

  elif [ "$free" -lt "$THRESH_HARD" ]; then
    dropped=$(drop_oldest || true)
    dropped="$dropped $(drop_oldest || true)"
    notify "${HOST_NAME:-host} disk ${free}% free — dropped log partitions:${dropped}"

  elif [ "$free" -lt "$THRESH_TRIM" ]; then
    dropped=$(drop_oldest || true)
    [ -n "$dropped" ] && notify "${HOST_NAME:-host} disk ${free}% free — dropped log partition ${dropped}"
  fi
}

main "$@"
