#!/usr/bin/env bash
#
# Live tail of every service on this machine — the `pm2 logs` experience, but
# covering Docker containers too and tagging each line with its service.
#
# Deliberately NOT the stored-log path. Nothing here touches the database:
#
#   stored logs   collector -> receiver -> Postgres -> app queries it
#                 history, search, retention, error grouping, alerts
#                 only the services the operator selected
#
#   this          tail -> ssh -> app renders it
#                 no history, no search, nothing kept
#                 EVERY service, including ones never selected
#
# They answer different questions. "What happened at 3am" needs the database.
# "What is this service doing right now" needs this, and needs it for services
# nobody thought to enable before the incident started.
#
#   logagent tail                 every service
#   logagent tail api worker      only those (substring match on the name)
#
# Output is one line per record: <service> TAB <line>. The app splits on the
# first tab; a tab inside the message itself is therefore harmless.

set -uo pipefail   # not -e: one dead tail must not take the whole stream down
. /opt/ai-terminal-logs/lib/common.sh
load_env

FILTERS=("$@")

# Empty filter list means everything. With filters, match a service if any
# filter is a substring of its name — the app passes exact names, but a human
# typing `logagent tail api` should not have to know the full unit name.
wanted() {
  [ ${#FILTERS[@]} -eq 0 ] && return 0
  local f
  for f in "${FILTERS[@]}"; do
    case "$1" in *"$f"*) return 0 ;; esac
  done
  return 1
}

# PM2 writes <name>-out.log and <name>-error.log, plus -<pm_id> in cluster mode.
svc_of_file() {
  basename "$1" | sed -E 's/-(out|error)(-[0-9]+)?\.log$//'
}

PIDS=()

# Kill the whole process group on exit. Without this a dropped SSH channel
# leaves a `tail -F` per log file running forever on a production box — 65 of
# them here — and every reconnect adds another set.
cleanup() {
  trap - EXIT INT TERM
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do
    kill "$p" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# awk rather than `sed -u` for the prefix: fflush() is portable across gawk and
# mawk, whereas -u is GNU-only. Unbuffered matters more than it looks — block
# buffering would hold lines back until 4 KB had accumulated, which on a quiet
# service is minutes, and a "live" view that lags by minutes is worse than none.
stream() {
  local svc="$1"
  awk -v s="$svc" '{ print s "\t" $0; fflush() }'
}

# ── PM2 ──────────────────────────────────────────────────────────────────────
shopt -s nullglob
for dir in /root/.pm2/logs /home/*/.pm2/logs; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*.log; do
    svc=$(svc_of_file "$f")
    wanted "$svc" || continue
    # -n 0: start at the end. A live view must open on what is happening now,
    # not replay a 200 MB file. -F follows across rotation.
    tail -F -n 0 "$f" 2>/dev/null | stream "$svc" &
    PIDS+=($!)
  done
done
shopt -u nullglob

# ── Docker ───────────────────────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$name" = "$PG_CONTAINER" ] && continue   # our own logs database
    wanted "$name" || continue
    # 2>&1 because most containers log to stderr, and a tail that silently drops
    # stderr shows an idle-looking container that is in fact erroring.
    docker logs -f --tail 0 "$name" 2>&1 | stream "$name" &
    PIDS+=($!)
  done < <(docker ps --format '{{.Names}}' 2>/dev/null)
fi

if [ ${#PIDS[@]} -eq 0 ]; then
  echo "__no_sources__	no matching services on this machine"
  exit 0
fi

# Tell the app what it is watching before the first line arrives, so a set of
# genuinely idle services reads as "attached, nothing yet" rather than a hang.
echo "__attached__	${#PIDS[@]}"

wait
