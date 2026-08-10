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

load_env() { [ -f "$ENV_FILE" ] && . "$ENV_FILE"; }

free_bytes() { df -B1 --output=avail / | tail -1 | tr -d ' '; }
gb()         { echo $(( ${1:-0} / 1024 / 1024 / 1024 )); }

# psql inside the logs container. Quiet, tuple-only, unaligned — parseable output.
pgq()  { docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -qtAX "$@" 2>/dev/null; }
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
