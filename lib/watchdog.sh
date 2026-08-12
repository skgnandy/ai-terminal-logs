#!/usr/bin/env bash
# The two ways collection dies quietly, checked every five minutes: a collector
# stuck past the end of a rotated file, and a disk about to fill.
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

# ── collector position guard ────────────────────────────────────────────────
#
# pm2-logrotate rotates without changing the inode, so the position the
# collector saved for the pre-rotation file survives into the new, smaller one.
# It then stores nothing until that file grows past the old length — for a log
# that rotates daily, never.
#
# Nothing reports this. The unit is active, the config validates, the file is
# being written, the database is healthy, and no error is logged; the only
# symptom is a service that silently stops appearing. It cost a full day of one
# machine's logs before it was found by hand, which is exactly the class of
# failure this timer exists to catch.
#
# Prints the offending file and returns 0 when one is found.
stalled_position() {
  python3 - "$STATE/vector" <<'PY'
import glob, json, os, sys, time

state = sys.argv[1]

doc = None
for root, _dirs, names in os.walk(state):
    if "checkpoints.json" in names:
        try:
            doc = json.load(open(os.path.join(root, "checkpoints.json")))
        except Exception:                          # noqa: BLE001
            doc = None
        break

if not doc:
    raise SystemExit(1)

pos = {}
for entry in doc.get("checkpoints", []):
    pair = (entry.get("fingerprint") or {}).get("device_and_inode")
    if pair and len(pair) == 2:
        pos[(pair[0], pair[1])] = entry.get("position") or 0

now = time.time()
for directory in ["/root/.pm2/logs"] + glob.glob("/home/*/.pm2/logs"):
    for path in glob.glob(os.path.join(directory, "*.log")):
        try:
            st = os.stat(path)
        except OSError:
            continue
        saved = pos.get((st.st_dev, st.st_ino))
        # Only a file being written right now. One sitting idle below its
        # recorded position loses nothing, and restarting the collector over it
        # would throw away every other file's position for no gain.
        if saved is None or now - st.st_mtime > 600:
            continue
        if saved > st.st_size:
            print(f"{path} (reading at {saved}, file is {st.st_size})")
            raise SystemExit(0)

raise SystemExit(1)
PY
}

# Clearing the positions is safe to do unattended: it can only skip forward to
# the end of each file, never replay. And it cannot loop — the condition is the
# saved position itself, which this removes.
recover_position() {
  local stalled="$1"
  systemctl stop vector >/dev/null 2>&1 || true
  find "$STATE/vector" -name 'checkpoints.json*' -type f -delete 2>/dev/null || true
  systemctl start vector >/dev/null 2>&1 || true

  audit rewind "collector stalled past end of file: $stalled"
  log "collector was stalled on $stalled — positions cleared, vector restarted"
  notify "${HOST_NAME:-host}: log collection had stalled after a rotation and was restarted. $stalled"
}

main() {
  docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" || exit 0

  local stalled
  if stalled=$(stalled_position); then
    recover_position "$stalled"
  fi

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
