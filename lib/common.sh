#!/usr/bin/env bash
# Shared helpers, paths and constants. Sourced by every other script.
#
# Everything here must stay side-effect free — sourcing this file must never
# change machine state, because the CLI sources it on every invocation.

ETC=/etc/ai-terminal
CONF="$ETC/logagent.conf"
ENV_FILE="$ETC/env"
CHANNELS="$ETC/channels.json"
LIB_DIR=/opt/ai-terminal-logs/lib
SQL_DIR=/opt/ai-terminal-logs/sql
UNIT_DIR=/opt/ai-terminal-logs/systemd
STATE=/var/lib/ai-terminal
VECTOR_CONF=/etc/vector/vector.toml

PG_CONTAINER=ai-terminal-logs
PG_VOLUME=ai-terminal-logs-data
PG_DB=logs
PG_USER=logagent

# 5432-5434 are routinely taken by application databases. Start clear of that
# range and probe upward rather than assuming anything is free.
PG_PORT_DEFAULT=5499
RECEIVER_PORT_DEFAULT=9080

log()  { printf '\033[36m[logagent]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[logagent] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[logagent] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"; }

# `set -a` is load-bearing, not tidiness. The env file holds bare `PG_PORT=5499`
# assignments, so plain sourcing makes them shell variables — invisible to the
# python3 and psql subprocesses that actually read them. `logagent status` then
# reported dbPort 0, and the app dutifully tunnelled to 127.0.0.1:0 and showed
# "the underlying socket to Postgres was closed".
#
# `|| true` is load-bearing too: without it the function returns 1 whenever the
# env file does not exist yet, and every caller runs under `set -e` — so status
# on a part-installed machine exited 1 printing nothing, which reads as "agent
# broken" rather than "agent not configured yet".
load_env() {
  set -a
  [ -f "$ENV_FILE" ] && . "$ENV_FILE" || true
  set +a
}

# systemd gives a service a minimal PATH — /usr/local/sbin:/usr/local/bin:
# /usr/sbin:/usr/bin:/sbin:/bin — and nothing else. A pm2 installed through nvm
# or a versioned node lives outside all of it, so `command -v pm2` finds nothing
# under a timer while working perfectly over SSH. Look where node version
# managers actually put things before giving up.
find_pm2() {
  local p
  p=$(command -v pm2 2>/dev/null) && { echo "$p"; return 0; }
  for p in /usr/local/bin/pm2 /usr/bin/pm2 \
           /root/.nvm/versions/node/*/bin/pm2 \
           /root/.volta/bin/pm2 \
           /usr/local/n/versions/node/*/bin/pm2 \
           /home/*/.nvm/versions/node/*/bin/pm2; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

# Names of the PM2 processes that exist right now, one per line.
#
# PM2_HOME must be explicit for the same reason as the PATH search above, and
# every home is tried because PM2 under a non-root user is normal on shared
# machines.
pm2_live_names() {
  local bin home
  bin=$(find_pm2) || return 0
  for home in /root/.pm2 /home/*/.pm2; do
    [ -d "$home" ] || continue
    PM2_HOME="$home" "$bin" jlist 2>/dev/null | python3 -c '
import json, sys
try:
    for p in json.load(sys.stdin):
        name = p.get("name")
        if name:
            print(name)
except Exception:
    pass
' 2>/dev/null || true
  done
}

# Service name for a PM2 log file.
#
# Strips the pm2-logrotate stamp before the stream suffix: a rotated file is
# named <service>-error__2026-08-11_00-00-00.log, so removing only the suffix
# leaves the date attached and every archive looks like its own service.
svc_of_pm2_file() {
  basename "$1" | sed -E 's/__[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}//; s/-(out|error)(-[0-9]+)?\.log$//'
}

# True for a pm2-logrotate archive: a file nothing will ever append to again.
is_rotated_log() {
  case "$(basename "$1")" in
    *__[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*) return 0 ;;
    *.gz|*.zip) return 0 ;;
  esac
  return 1
}

free_bytes() { df -B1 --output=avail / | tail -1 | tr -d ' '; }
gb()         { echo $(( ${1:-0} / 1024 / 1024 / 1024 )); }

# psql inside the logs container. Quiet, tuple-only, unaligned — parseable output.
#
# pg_run keeps stderr; pgq is the same thing with stderr discarded, which is what
# most callers want because they parse the output and a warning would corrupt it.
#
# The split exists because the discard is not free: the metrics collector piped
# its INSERTs through pgq and tried to capture failures with `2>&1` on the
# outside, which cannot work — pgq had already sent stderr to /dev/null inside.
# Statements that failed for every row were therefore indistinguishable from a
# collector with nothing to insert.
pg_run() { docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -qtAX "$@"; }
pgq()    { pg_run "$@" 2>/dev/null; }
# Same, but fails the script on SQL error. Use for migrations and DDL.
pgx()  { docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 "$@"; }

json_get() {
  # json_get <file> <key> [default]
  python3 - "$1" "$2" "${3-}" <<'PY'
import json, sys
path, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    v = json.load(open(path)).get(key)
except Exception:
    v = None
if v is None:
    print(default)
elif isinstance(v, bool):
    print("true" if v else "false")
elif isinstance(v, (list, dict)):
    print(json.dumps(v))
else:
    print(v)
PY
}

# A port counts as taken if the host listens on it OR Docker has published it.
# Checking both matters: `ss` misses published ports under some Docker network modes.
port_taken() {
  local p="$1"
  ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$" && return 0
  docker ps --format '{{.Ports}}' 2>/dev/null | grep -qE "(^|[:,] ?)[0-9.]*:${p}->" && return 0
  return 1
}

pick_port() {
  local p="$1" limit=$(( $1 + 100 ))
  while [ "$p" -lt "$limit" ]; do
    port_taken "$p" || { echo "$p"; return 0; }
    p=$((p + 1))
  done
  die "no free port found in ${1}-${limit}"
}

notify() { [ -x /usr/local/bin/logagent ] && /usr/local/bin/logagent notify "$*" >/dev/null 2>&1 || true; }

audit() {
  # Record maintenance actions so the app can show why data disappeared.
  pgq -c "INSERT INTO maintenance_log(action,detail) VALUES('$1','$2');" >/dev/null 2>&1 || true
}
