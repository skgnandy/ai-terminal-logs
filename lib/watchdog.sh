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

# Where pm2 keeps its logs. A variable, and unquoted at every use so the glob
# expands, because the recovery paths below are worth testing against a fixture
# directory instead of only on a machine that is already broken.
PM2_DIRS=${AI_TERMINAL_PM2_DIRS:-"/root/.pm2/logs /home/*/.pm2/logs"}

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
  python3 - "$STATE/vector" "$PM2_DIRS" <<'PY'
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
for pattern in sys.argv[2].split():
    for directory in sorted(glob.glob(pattern)) or [pattern]:
        for path in glob.glob(os.path.join(directory, "*.log")):
            try:
                st = os.stat(path)
            except OSError:
                continue
            saved = pos.get((st.st_dev, st.st_ino))
            # Only a file being written right now. One sitting idle below its
            # recorded position loses nothing, and restarting the collector over
            # it would throw away every other file's position for no gain.
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

# The outcome check, and the one that matters.
#
# The position guard above catches one mechanism — the one that had already
# happened. The next rotation broke collection a different way: ~106 files were
# created at once, the collector discovered them, and five seconds later it was
# reading nothing at all, holding no position for the live files it had been
# following. `position > size` was never true, so nothing fired, and it stayed
# down for eight hours.
#
# So this asks the question the mechanism-specific check cannot: is a service we
# are supposed to be collecting writing to its log right now and storing nothing?
# That is true of every way this can fail, including the ones not yet seen.
silent_while_writing() {
  local svc esc rows newest age now
  now=$(date +%s)

  while IFS= read -r svc; do
    # A stray carriage return survives into the filename patterns below and
    # silently matches nothing, which would switch this check off for that
    # service while looking like it ran. The name comes from a JSON file the app
    # writes, so it is not ours to assume clean.
    svc=${svc%$'\r'}
    [ -n "$svc" ] || continue
    esc=$(printf '%s' "$svc" | sed "s/'/''/g")

    # </dev/null: pgq is `docker exec -i`, which drains the loop's stdin.
    rows=$(pgq -c "SELECT count(*) FROM log_entries
                   WHERE service = '$esc' AND ts > now() - interval '15 minutes';" \
                 </dev/null 2>/dev/null || echo 1)
    [ "${rows:-1}" -eq 0 ] || continue

    newest=$(find $PM2_DIRS -maxdepth 1 -type f \
               \( -name "$svc-out*.log" -o -name "$svc-error*.log" -o -name "$svc.log" \) \
               -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
    [ -n "$newest" ] || continue

    # Two minutes, not ten. A service that logs in bursts can be quiet for a
    # while legitimately; one written to within the last two minutes that has
    # stored nothing for fifteen is not quiet, it is not being collected.
    age=$(( now - ${newest%%.*} ))
    [ "$age" -lt 120 ] || continue

    printf '%s\n' "$svc"
  done < <(python3 - "$CONF" <<'PY' 2>/dev/null || true
import json, sys
try:
    for s in (json.load(open(sys.argv[1])).get("logServices") or []):
        if s:
            print(s)
except Exception:                                  # noqa: BLE001
    pass
PY
  )
}

# Restarting the collector is cheap and safe — it resumes from its saved
# positions — but it must not become a loop. Half an hour between attempts means
# a genuine, unfixable fault is reported by the notification rather than hidden
# behind a restart every five minutes.
RECOVER_STAMP="$STATE/last-collector-recovery"

recover_collector() {
  local services="$1" last=0 now
  now=$(date +%s)
  [ -f "$RECOVER_STAMP" ] && last=$(cat "$RECOVER_STAMP" 2>/dev/null || echo 0)

  if [ $(( now - ${last:-0} )) -lt 1800 ]; then
    warn "collection still silent for: $services (restarted recently, not retrying yet)"
    return 0
  fi

  printf '%s' "$now" > "$RECOVER_STAMP"
  systemctl restart vector >/dev/null 2>&1 || true

  audit collector_restart "silent while writing: $services"
  log "restarted vector — writing but storing nothing: $services"
  notify "${HOST_NAME:-host}: log collection had stopped for $services and the collector was restarted"
}

main() {
  docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" || exit 0

  # Position first: it needs the checkpoints cleared, which a restart alone
  # would not do, and it would otherwise be misread as the general case below.
  local stalled silent
  if stalled=$(stalled_position); then
    recover_position "$stalled"
  elif silent=$(silent_while_writing) && [ -n "$silent" ]; then
    recover_collector "$(printf '%s' "$silent" | tr '\n' ' ')"
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
