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

# Shared with the metric collector — see common.sh. Not redefined here: the two
# must agree on what a service is called, or the same process appears twice in
# the app under names that differ by a rotation stamp.
svc_of_file() { svc_of_pm2_file "$1"; }

# PM2 processes that exist right now. Empty when pm2 is absent or reports
# nothing, in which case the file list is used unfiltered — a tail that shows
# too much is recoverable, one that shows nothing is not.
LIVE_PM2=$(pm2_live_names | sort -u)

is_live_pm2() {
  [ -z "$LIVE_PM2" ] && return 0
  printf '%s\n' "$LIVE_PM2" | grep -qxF "$1"
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
#
# ONE tail over every file, not one tail per file.
#
# `tail -F` holds an inotify instance per process, and fs.inotify.max_user_
# instances defaults to 128. This machine has 65 PM2 logs; add the collector's
# own file watches and Docker's, and a tail-per-file run silently gets nothing
# past the limit. It reported "attached to 101 streams" and then never emitted a
# line, because the failures went to the /dev/null this used to redirect to.
#
# With several files tail announces each switch as "==> path <==", so one
# process still attributes every line correctly — including continuation lines,
# which belong to whichever file is currently selected.
FILES=()
shopt -s nullglob
for dir in /root/.pm2/logs /home/*/.pm2/logs; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*.log; do
    # pm2-logrotate archives. Nothing will ever append to them, so tailing one
    # holds a watch forever for no output — and with 65 files on this machine
    # the archives were the majority of them.
    is_rotated_log "$f" && continue

    svc=$(svc_of_file "$f")
    # Only processes PM2 currently has. A deleted or renamed app leaves its logs
    # behind indefinitely, so the file list drifts further from reality the
    # longer a machine lives.
    is_live_pm2 "$svc" || continue
    wanted "$svc" || continue
    FILES+=("$f")
  done
done
shopt -u nullglob

if [ ${#FILES[@]} -gt 0 ]; then
  # -n 0: start at the end. A live view opens on what is happening now, not on a
  # replay of a 200 MB file. -F follows across rotation.
  #
  # stderr is kept and tagged rather than discarded. Hiding it is what made the
  # inotify exhaustion above invisible.
  tail -F -n 0 "${FILES[@]}" 2>&1 | awk '
    # Mirrors svc_of_pm2_file in common.sh — the rotation stamp has to come off
    # before the stream suffix, or an archive reads as its own service.
    function svcname(p,  b) {
      b = p
      sub(/^.*\//, "", b)
      sub(/__[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/, "", b)
      sub(/-(out|error)(-[0-9]+)?\.log$/, "", b)
      return b
    }
    /^==> .* <==$/ {
      p = $0; sub(/^==> /, "", p); sub(/ <==$/, "", p)
      svc = svcname(p); next
    }
    /^$/ { next }
    /^tail:/ { print "__warn__\t" $0; fflush(); next }
    { print (svc == "" ? "pm2" : svc) "\t" $0; fflush() }
  ' &
  PIDS+=($!)
fi

# ── Docker ───────────────────────────────────────────────────────────────────
CONTAINERS=0
WATCHED_CONTAINERS=()
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$name" = "$PG_CONTAINER" ] && continue   # our own logs database
    wanted "$name" || continue
    # One process per container is unavoidable — `docker logs -f` takes a single
    # container — but there are a handful of these, not dozens, so the inotify
    # pressure that forced the PM2 tails into one process does not apply.
    #
    # 2>&1 because most containers log to stderr, and dropping it shows an
    # idle-looking container that is in fact erroring.
    docker logs -f --tail 0 "$name" 2>&1 | stream "$name" &
    PIDS+=($!)
    CONTAINERS=$((CONTAINERS + 1))
    WATCHED_CONTAINERS+=("$name")
  done < <(docker ps --format '{{.Names}}' 2>/dev/null)
fi

if [ ${#PIDS[@]} -eq 0 ]; then
  echo "__no_sources__	no matching services on this machine"
  exit 0
fi

# Report what is being watched, not how many processes are doing the watching.
# The previous count was the process count, which after collapsing the PM2 tails
# into one would have reported "2 streams" for a machine with 65 log files.
echo "__attached__	$(( ${#FILES[@]} + CONTAINERS ))"

# The full roster, so the app can offer every watched service straight away.
#
# Deriving the picker from lines already seen means a service that has not
# spoken yet cannot be selected — and on a quiet box that is most of them. It is
# also backwards: the reason to filter to one service is usually that it has
# gone silent and you want to confirm it.
#
# Deduplicated because -out.log and -error.log are the same service, and cluster
# mode adds a -<pm_id> file per worker.
printf '__services__\t%s\n' "$(
  { for f in ${FILES[@]+"${FILES[@]}"}; do svc_of_file "$f"; done
    printf '%s\n' ${WATCHED_CONTAINERS[@]+"${WATCHED_CONTAINERS[@]}"}
  } | grep -v '^$' | sort -u | paste -sd, -
)"

wait
