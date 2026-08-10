#!/usr/bin/env bash
#
# logagent doctor — one command that prints everything needed to explain why the
# agent is or is not collecting.
#
# Written because the alternative was a round trip per hypothesis: the app could
# only report a boolean, so every wrong guess cost a full "change something,
# reinstall, look again" cycle. This prints the whole chain — binary, unit,
# config, validation, sources, sink, database — in the order a log line travels,
# so the first FAIL is the cause and everything after it is a consequence.
#
# Plain text, not JSON. It is read by a person.

set -uo pipefail   # deliberately NOT -e: a diagnostic must survive every probe
                   # failing. Aborting on the first bad command would hide the
                   # rest of the report, which is the part that explains it.
. /opt/ai-terminal-logs/lib/common.sh
load_env

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }
info() { printf '  ----  %s\n' "$*"; }
head_() { printf '\n\033[36m== %s\033[0m\n' "$*"; }

PROBLEMS=0

# ── 1. agent ─────────────────────────────────────────────────────────────────
head_ "agent"
info "version        $(cat /opt/ai-terminal-logs/VERSION 2>/dev/null || echo unknown)"
info "installed at   /opt/ai-terminal-logs"
info "cli            $(command -v logagent || echo 'NOT ON PATH')"
info "host           ${HOST_NAME:-$(hostname)}   timezone ${TZ_NAME:-unknown}"

if [ -f "$ENV_FILE" ]; then
  ok "env file present ($ENV_FILE)"
  info "db port        ${PG_PORT:-unset}"
  info "receiver port  ${RECEIVER_PORT:-unset}"
  # An unexported env file is invisible to the python and psql subprocesses that
  # read it, which once made status report db port 0 and the app connect to
  # 127.0.0.1:0. Prove the export actually happened.
  if [ -n "${PG_PORT:-}" ] && [ "$(python3 -c 'import os;print(os.environ.get("PG_PORT","MISSING"))')" = "${PG_PORT}" ]; then
    ok "env is exported to subprocesses"
  else
    bad "env file is NOT exported — subprocesses will use defaults"
  fi
else
  bad "no env file at $ENV_FILE — the installer never finished"
fi

# ── 2. configuration ─────────────────────────────────────────────────────────
head_ "configuration"
if [ -f "$CONF" ]; then
  PAUSED=$(json_get "$CONF" paused true)
  DAYS=$(json_get "$CONF" days 0)
  SERVICES=$(json_get "$CONF" logServices '[]')
  info "retention      $DAYS day(s)"
  info "services       $SERVICES"
  if [ "$PAUSED" = "true" ]; then
    bad "paused — nothing will be collected until retention and services are set"
  else
    ok "not paused"
  fi
  [ "$SERVICES" = "[]" ] && bad "no services selected — the filter stores nothing"
else
  bad "no config at $CONF"
fi

# ── 3. collector binary and unit ─────────────────────────────────────────────
head_ "collector (vector)"
VEC=$(command -v vector 2>/dev/null)
if [ -n "$VEC" ]; then
  ok "binary         $VEC  ($(vector --version 2>/dev/null | head -1))"
else
  bad "vector binary not installed"
fi

if systemctl cat vector >/dev/null 2>&1; then
  ok "service unit   $(systemctl show vector -p FragmentPath --value 2>/dev/null)"
  info "enabled        $(systemctl is-enabled vector 2>/dev/null || echo unknown)"
  # NOT `$(... || echo unknown)`. `systemctl is-active` prints the state AND
  # exits non-zero when it is not active, so that form captures both and reports
  # "inactive\nunknown".
  STATE_V=$(systemctl is-active vector 2>/dev/null)
  STATE_V=${STATE_V:-unknown}
  if [ "$STATE_V" = "active" ]; then
    ok "state          active"
    info "running since  $(systemctl show vector -p ActiveEnterTimestamp --value 2>/dev/null)"
  else
    bad "state          $STATE_V"
  fi
else
  bad "no vector service unit — re-run the installer"
fi

# ── 4. collector config ──────────────────────────────────────────────────────
head_ "collector config"
if [ -f "$VECTOR_CONF" ]; then
  ok "config         $VECTOR_CONF ($(wc -l < "$VECTOR_CONF") lines, written $(date -r "$VECTOR_CONF" '+%Y-%m-%d %H:%M' 2>/dev/null))"
  info "sources        $(grep -c '^\[sources\.' "$VECTOR_CONF" 2>/dev/null) declared"
  grep -o "^\[sources\.[a-z0-9_]*\]" "$VECTOR_CONF" 2>/dev/null | sed 's/^/                 /'

  # Re-validate live. A config that was accepted at generate time can still be
  # rejected by a Vector that has since been upgraded, and that is invisible
  # until the next restart — which may be a reboot, weeks later.
  if [ -n "$VEC" ]; then
    if OUT=$(vector validate --no-environment "$VECTOR_CONF" 2>&1); then
      ok "validates against the installed vector"
    elif OUT=$(vector validate --no-environment --config "$VECTOR_CONF" 2>&1); then
      ok "validates (this vector uses the older --config form)"
    else
      bad "config is REJECTED by the installed vector:"
      printf '%s\n' "$OUT" | sed 's/^/          /'
    fi
  fi
else
  bad "no config at $VECTOR_CONF — generation failed"
fi

if [ -f "$STATE/vector-config.error" ]; then
  bad "last config generation failed:"
  sed 's/^/          /' "$STATE/vector-config.error"
fi

# ── 5. what there is to collect ──────────────────────────────────────────────
head_ "sources on this machine"
PM2_FILES=0
for d in /root/.pm2/logs /home/*/.pm2/logs; do
  [ -d "$d" ] || continue
  n=$(find "$d" -name '*.log' -type f 2>/dev/null | wc -l)
  PM2_FILES=$((PM2_FILES + n))
  info "pm2 logs       $d  ($n files)"
  # Recent writes matter more than file count: a directory full of logs nothing
  # writes to any more explains an empty log view with read_from = "end".
  find "$d" -name '*.log' -type f -mmin -10 2>/dev/null | head -5 | sed 's/^/                 recently written: /'
done
[ "$PM2_FILES" -eq 0 ] && info "pm2 logs       none found"

if docker info >/dev/null 2>&1; then
  info "docker         $(docker ps -q | wc -l) running containers"
  docker ps --format '                 {{.Names}}  ({{.Status}})' 2>/dev/null | head -20
else
  info "docker         unavailable"
fi
info "journald       $(command -v journalctl >/dev/null 2>&1 && echo present || echo absent)"

# ── 6. receiver and database ─────────────────────────────────────────────────
head_ "receiver"
R_STATE=$(systemctl is-active ai-terminal-receiver 2>/dev/null)
R_STATE=${R_STATE:-unknown}
if [ "$R_STATE" = "active" ]; then
  ok "state          active on 127.0.0.1:${RECEIVER_PORT:-9080}"
else
  bad "state          $R_STATE"
  journalctl -u ai-terminal-receiver --no-pager --lines=10 2>/dev/null | sed 's/^/          /'
fi

# ── timers ───────────────────────────────────────────────────────────────────
head_ "timers"
# The dashboard reads pre-aggregated tables, so a dead timer shows up as a blank
# chart rather than an error — cpu, memory and p95 simply stay "—" forever with
# nothing anywhere to say why.
for t in metrics rollup partitions alerts probes watchdog; do
  unit="ai-terminal-$t.timer"
  if ! systemctl cat "$unit" >/dev/null 2>&1; then
    bad "$t timer      not installed"
    continue
  fi
  ts=$(systemctl is-active "$unit" 2>/dev/null)
  ts=${ts:-unknown}
  if [ "$ts" = "active" ]; then
    ok "$t timer      active (last run: $(systemctl show "ai-terminal-$t.service" -p ExecMainStatus --value 2>/dev/null | sed 's/^0$/success/;s/^$/never/'))"
  else
    bad "$t timer      $ts"
  fi
  # A timer can be perfectly active while the service it triggers fails every
  # time, which is exactly how an empty metrics table looks from the outside.
  if [ "$(systemctl show "ai-terminal-$t.service" -p ExecMainStatus --value 2>/dev/null)" != "0" ]; then
    journalctl -u "ai-terminal-$t.service" --no-pager --lines=5 -o cat 2>/dev/null \
      | sed "s/^/          $t: /"
  fi
done

head_ "database"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CONTAINER"; then
  ok "container      $PG_CONTAINER running on 127.0.0.1:${PG_PORT:-unset}"
  info "rows           $(pgq -c 'SELECT count(*) FROM log_entries;' 2>/dev/null || echo '?')"
  info "oldest         $(pgq -c 'SELECT min(ts) FROM log_entries;' 2>/dev/null || echo '-')"
  info "newest         $(pgq -c 'SELECT max(ts) FROM log_entries;' 2>/dev/null || echo '-')"
  info "size           $(pgq -c 'SELECT pg_size_pretty(pg_database_size(current_database()));' 2>/dev/null || echo '?')"
else
  bad "container $PG_CONTAINER is not running"
fi

# ── 7. recent collector output ───────────────────────────────────────────────
head_ "last 20 collector log lines"
journalctl -u vector --no-pager --lines=20 -o cat 2>/dev/null | sed 's/^/  /' \
  || info "no journal for vector"

# ── 8. verdict ───────────────────────────────────────────────────────────────
head_ "verdict"
if [ "$PROBLEMS" -eq 0 ]; then
  printf '  \033[32mNo problems found.\033[0m\n'
  printf '  If the log view is still empty, the selected services have not written\n'
  printf '  a line since collection started — pm2 file sources read from the end.\n\n'
else
  printf '  \033[31m%s problem(s) above.\033[0m Fix the FIRST one; the rest are usually\n' "$PROBLEMS"
  printf '  consequences of it.\n\n'
fi
