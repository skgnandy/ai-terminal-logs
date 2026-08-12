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
  # Which SOURCES are on, not just which services. A source switched off in the
  # app is indistinguishable from a broken one once the config is generated —
  # the section simply is not there.
  info "sources        $(json_get "$CONF" sources '{}')"
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
  # Top-level source tables only. Counting every line starting with
  # "[sources." also counted [sources.pm2.multiline] and
  # [sources.pm2.fingerprint], so the report claimed three sources and then
  # listed two — which reads as a bug in the listing rather than what it was:
  # the count was wrong.
  SRC_LIST=$(grep -oE '^\[sources\.[a-z0-9_]+\]$' "$VECTOR_CONF" 2>/dev/null)
  info "sources        $(printf '%s\n' "$SRC_LIST" | grep -c . ) collecting"
  printf '%s\n' "$SRC_LIST" | sed 's/^/                 /'

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
  #
  # Sorted by mtime and counted. The first version piped `find` straight into
  # `head -5`, and find emits directory order — so the five shown were an
  # arbitrary five of however many, while reading exactly like the complete
  # list. That is worse than showing nothing: it was used to conclude one
  # service was the only one writing, which the output could not support.
  RECENT=$(find "$d" -name '*.log' -type f -mmin -10 -printf '%T@ %p\n' 2>/dev/null \
           | sort -rn | cut -d' ' -f2-)
  RECENT_N=$(printf '%s' "$RECENT" | grep -c . || true)
  if [ "${RECENT_N:-0}" -eq 0 ]; then
    info "               nothing written here in the last 10 minutes"
  else
    printf '%s\n' "$RECENT" | head -8 \
      | sed 's/^/                 recently written: /'
    [ "$RECENT_N" -gt 8 ] && info "                 … and $((RECENT_N - 8)) more (newest first)"
  fi
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

  # Metrics separately from logs. They arrive by a completely different path —
  # a timer shelling out to pm2 and docker, not the collector — so "logs are
  # flowing" says nothing about whether the cpu and memory graphs will have
  # anything in them, and a green metrics timer only means the script exited 0.
  M_RECENT=$(pgq -c "SELECT count(*) FROM metrics WHERE ts > now() - interval '10 minutes';" 2>/dev/null || echo 0)
  M_PM2=$(pgq -c "SELECT count(DISTINCT service) FROM metrics WHERE kind='pm2' AND ts > now() - interval '10 minutes';" 2>/dev/null || echo 0)
  M_DOCKER=$(pgq -c "SELECT count(DISTINCT service) FROM metrics WHERE kind='docker' AND ts > now() - interval '10 minutes';" 2>/dev/null || echo 0)
  if [ "${M_RECENT:-0}" -gt 0 ]; then
    ok "metrics        ${M_RECENT} samples in 10 min (pm2: ${M_PM2} services, docker: ${M_DOCKER})"
  else
    bad "metrics        no samples in the last 10 minutes — cpu and memory will be blank"
  fi
  [ "${M_PM2:-0}" -eq 0 ] && [ -d /root/.pm2 ] && \
    bad "pm2 metrics    none, though /root/.pm2 exists"

  # What the collector itself said. Every failure mode in it used to be silenced
  # individually by 2>/dev/null and || true, so an empty metrics table was
  # indistinguishable from a machine with nothing to report.
  if [ -s "$STATE/metrics.error" ]; then
    bad "metrics collector reported:"
    sed 's/^/          /' "$STATE/metrics.error"
  fi

  # Last resort: run the collectors now and show what SQL they would produce.
  # Reading the code has been guesswork three times; this answers it.
  if [ "${M_RECENT:-0}" -eq 0 ]; then
    info "dry run of the metric collectors:"
    bash "$LIB_DIR/metrics.sh" --dry-run 2>&1 | head -25 | sed 's/^/          /'
  fi

  info "host samples   $(pgq -c "SELECT count(*) FROM host_metrics WHERE ts > now() - interval '10 minutes';" 2>/dev/null || echo 0) in 10 min"

  # ── latency ────────────────────────────────────────────────────────────────
  # Every percentile in the app comes from attrs.duration_ms, and there is no
  # other way to tell whether it is being extracted: a blank p95 chart looks
  # identical whether the parser is broken, the service is idle, or the
  # application simply never logs a response time. Only the last of those is
  # fixed in the application rather than here, so guessing wrong costs a day.
  L_TOTAL=$(pgq -c "SELECT count(*) FROM log_entries WHERE ts > now() - interval '1 hour';" 2>/dev/null || echo 0)
  L_TIMED=$(pgq -c "SELECT count(*) FROM log_entries WHERE ts > now() - interval '1 hour' AND attrs ? 'duration_ms';" 2>/dev/null || echo 0)

  # Latency does not require a duration field. A service that logs a start and
  # an end line sharing a request id has its timing in the gap between them, and
  # the rollup derives it — so counting only duration_ms would report FAIL on a
  # machine whose percentiles are about to appear.
  L_PAIRS=$(pgq -c "SELECT count(*) FROM log_entries
                    WHERE ts > now() - interval '1 hour' AND attrs->>'phase' = 'end';" 2>/dev/null || echo 0)

  # What the parser is actually producing, and whether anything has been through
  # it yet. Without this, "no timings" after an update is ambiguous between a
  # parser that is not extracting and a collector that has simply not ingested a
  # line since it restarted thirty seconds ago — and the previous wording
  # asserted the first, blaming the application for a fix that had just shipped.
  SINCE=$(systemctl show vector -p ActiveEnterTimestamp --value 2>/dev/null || true)
  # Computed first, not inlined into the SQL: a command substitution nested
  # inside a quoted query is exactly where quoting breaks silently, and a
  # broken timestamp here would be read as "no fresh rows" on every machine.
  SINCE_UTC=""
  [ -n "$SINCE" ] && SINCE_UTC=$(date -d "$SINCE" -u '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)

  FRESH=0
  if [ -n "$SINCE_UTC" ]; then
    FRESH=$(pgq -c "SELECT count(*) FROM log_entries WHERE ts > timestamptz '${SINCE_UTC}+00';" 2>/dev/null || echo 0)
  fi
  info "parser output   $(pgq -c "SELECT
        count(*) FILTER (WHERE attrs ? 'status') || ' status, ' ||
        count(*) FILTER (WHERE attrs ? 'method') || ' method, ' ||
        count(*) FILTER (WHERE attrs ? 'route')  || ' route, ' ||
        count(*) FILTER (WHERE attrs->>'phase' = 'start') || ' start, ' ||
        count(*) FILTER (WHERE attrs->>'phase' = 'end')   || ' end, ' ||
        -- Should exceed start+end once the agent tags every line that carries
        -- an id, not only the two that bracket the request. The gap between
        -- this and start+end is what the single-request view has to show.
        count(*) FILTER (WHERE attrs ? 'req_id') || ' req_id'
      FROM log_entries WHERE ts > now() - interval '1 hour';" 2>/dev/null || echo '?') (last hour)"

  # Read on its own as well as inside that line: the endpoints check below needs
  # to tell "the parser found no routes" from "routes exist but nothing has
  # aggregated them yet", and those call for opposite advice.
  R_ROUTE=$(pgq -c "SELECT count(*) FROM log_entries
                    WHERE ts > now() - interval '1 hour' AND attrs ? 'route';" 2>/dev/null || echo 0)

  # Seconds since the collector came up. A restart a moment ago with no rows yet
  # is normal — batches land every few seconds, and pm2 file sources resume from
  # a checkpoint. Warning about it told the reader to disregard an hour of valid
  # data below, which is worse than saying nothing.
  UP_SECS=0
  if [ -n "$SINCE" ]; then
    SINCE_EPOCH=$(date -d "$SINCE" +%s 2>/dev/null || echo 0)
    [ "${SINCE_EPOCH:-0}" -gt 0 ] && UP_SECS=$(( $(date +%s) - SINCE_EPOCH ))
  fi

  if [ "${FRESH:-0}" -eq 0 ] && [ -n "$SINCE_UTC" ] && [ "$UP_SECS" -gt 120 ]; then
    info "no rows at all since the collector restarted ($SINCE)."
    info "Nothing has been through the current parser yet — wait a minute for"
    info "the next batch and run this again before reading anything below."
  elif [ "${FRESH:-0}" -eq 0 ] && [ -n "$SINCE_UTC" ]; then
    info "collector restarted ${UP_SECS}s ago; nothing has arrived through it"
    info "yet, which is expected. The figures below cover the last hour and are"
    info "unaffected."
  fi

  if [ "${L_TIMED:-0}" -eq 0 ] && [ "${L_PAIRS:-0}" -gt 0 ]; then
    ok "latency        derived from ${L_PAIRS} request pairs in the last hour"
    info "no duration field in these logs, but each request logs a start and an"
    info "end sharing an id — the gap between them is the duration."
    # Both figures used to be wrong, and wrong in a way that read as precise.
    #
    #   "p95" was max(p95_ms) — the worst five-minute bucket in the hour, not
    #   the hour's p95. One quiet bucket containing a single slow request set
    #   it, so it stayed pinned at that value while the real distribution moved
    #   underneath. Two consecutive runs printing an identical 2587.1ms is what
    #   gave it away.
    #
    #   "p50" was percentile_cont(0.50) ORDER BY p95_ms — the median of the
    #   bucket p95 VALUES. It never read p50_ms at all.
    #
    # Both are now averaged across buckets weighted by the requests in each, so
    # a bucket with two requests cannot outvote one with two hundred. The worst
    # bucket is still shown, labelled as what it is: it is the useful half of
    # the old number, and dropping it would hide a real spike.
    pgq -f - <<'SQL' 2>/dev/null || true
SELECT '                 ' || service ||
       '  p50 ' || round((sum(p50_ms * w) /
                     nullif(sum(w) FILTER (WHERE p50_ms IS NOT NULL), 0))::numeric, 1) || 'ms' ||
       '  p95 ' || round((sum(p95_ms * w) /
                     nullif(sum(w) FILTER (WHERE p95_ms IS NOT NULL), 0))::numeric, 1) || 'ms' ||
       '  worst 5m bucket ' || round(max(p95_ms)::numeric, 1) || 'ms'
FROM (
  -- greatest(timed,1): a rollup written before schema v5 has timed = 0, and
  -- weighting everything by zero would divide the whole line by nothing. Falls
  -- back to an unweighted average, which is what the data can support.
  SELECT service, p50_ms, p95_ms, greatest(coalesce(timed, 0), 1) AS w
  FROM log_rollup
  WHERE bucket > now() - interval '1 hour' AND p95_ms IS NOT NULL
) s
GROUP BY service
ORDER BY 1;
SQL
    info "(blank above means the rollup has not run since the agent was updated;"
    info " it runs every 5 minutes)"
  elif [ "${L_TIMED:-0}" -gt 0 ]; then
    ok "latency        ${L_TIMED} of ${L_TOTAL} lines in the last hour carry a duration"
    pgq -c "SELECT '                 ' || service || '  p50 ' ||
                   round(percentile_cont(0.50) WITHIN GROUP (ORDER BY d)::numeric, 1) || 'ms  p95 ' ||
                   round(percentile_cont(0.95) WITHIN GROUP (ORDER BY d)::numeric, 1) || 'ms  (' || count(*) || ' timed)'
            FROM (SELECT service, (attrs->>'duration_ms')::double precision AS d
                  FROM log_entries
                  WHERE ts > now() - interval '1 hour'
                    AND attrs->>'duration_ms' ~ '^[0-9]+(\.[0-9]+)?\$') s
            GROUP BY service ORDER BY 1;" 2>/dev/null || true
  else
    bad "latency        no line in the last hour carries a duration — p50/p95/p99 will be blank"

    # Which of the two causes is it: the parser missing a field that IS there,
    # or an application that never logs one?
    #
    # The value has to be a bare number, not just the key looking time-ish. The
    # first version matched any key containing "time" or "response" and duly
    # reported created_time, scheduleDateTime and turnaround_time — ordinary
    # business fields holding date strings — under a heading telling the reader
    # the parser had missed a timing. That is worse than reporting nothing: it
    # sends someone to change a parser that was right.
    #
    # A duration is a number. A timestamp is a date string. That is the whole
    # discriminator, and it is reliable.
    info "timing-like fields present in the last hour:"
    FOUND=$(pgq -c "SELECT DISTINCT '          ' || m[1] || ': ' || m[2]
            FROM log_entries,
                 LATERAL regexp_matches(body,
                   '([A-Za-z_.]*(?:[Dd]uration|[Ee]lapsed|[Ll]atency|[Rr]esponse[Tt]ime|[Tt]ook|_ms|[Mm]illis)[A-Za-z_.]*)\"?\s*[=:]\s*\"?([0-9]+(?:\.[0-9]+)?)', 'g') AS m
            WHERE ts > now() - interval '1 hour'
            LIMIT 20;" 2>/dev/null || true)
    if [ -n "$FOUND" ]; then
      printf '%s\n' "$FOUND"
      info "^ one of these holds the request duration but the extractor did not"
      info "  read it. Report the names — the parser needs to learn them."
    elif [ "${FRESH:-0}" -eq 0 ]; then
      # Do not blame the application for a machine that has not ingested a line
      # since the parser changed. The previous wording did, immediately after
      # shipping the fix that made the blame wrong.
      info "          (nothing has been through the current parser yet)"
    else
      info "          (none — no field anywhere holds a numeric duration)"
      info "no duration field, and no start/end pair to derive one from. Either"
      info "log a duration where the request completes —"
      info "  responseTime: Date.now() - start"
      info "— or log a line when the request ARRIVES carrying the same request"
      info "id, and the gap between the two becomes the duration automatically."
    fi

    # Whole records, untruncated, so the shape can be read rather than guessed.
    info "a recent request record in full:"
    pgq -c "SELECT '          ' || replace(body, E'\n', E'\n          ')
            FROM log_entries
            WHERE ts > now() - interval '6 hours'
              AND (body ILIKE '%request completed%' OR body ILIKE '%statusCode%'
                   OR body ILIKE '%HTTP/1.%')
            ORDER BY ts DESC LIMIT 2;" 2>/dev/null || true
  fi

  # ── per-service breakdown ──────────────────────────────────────────────────
  #
  # "Only one service shows a p95" is the first question anyone asks of this
  # screen, and a single machine-wide verdict cannot answer it — the reason is
  # different for each service. So say it per service, once, from the data.
  #
  # Fed through `pgq -f -` rather than `pgq -c "…"`: this SQL contains regexes
  # and quotes, and wrapping it in a double-quoted shell string is exactly how
  # the earlier `[^\s"'…]` character class ended up in the config literally.
  info "latency by service (last hour)"
  pgq -f - <<'SQL' 2>/dev/null || true
SELECT '                 ' || rpad(service, 30) ||
       lpad(lines::text, 6) || ' lines   ' ||
       CASE
         WHEN ended  > 0 THEN 'p95 from ' || ended || ' request pairs'
         WHEN timed  > 0 THEN 'p95 from ' || timed || ' timed lines'
         -- Ids present but the wording never matched. This is the one case
         -- that is OUR gap rather than the application's, so it must not be
         -- reported as "this service logs nothing".
         WHEN withid > 0 THEN 'has request ids, but no line says "incoming request" / "request completed"'
         ELSE 'no duration and no request id in any line'
       END
FROM (
  SELECT service,
         count(*) AS lines,
         count(*) FILTER (WHERE attrs ? 'duration_ms')  AS timed,
         count(*) FILTER (WHERE attrs->>'phase' = 'end') AS ended,
         count(*) FILTER (WHERE body ~* '(request_?id|req_?id|correlation_?id|trace_?id|x-request-id)') AS withid
  FROM log_entries
  WHERE ts > now() - interval '1 hour'
  GROUP BY service
) s
ORDER BY lines DESC;
SQL
  # ── selected services ──────────────────────────────────────────────────────
  #
  # Every service the operator selected, listed whether or not it stored a line.
  # The breakdown above can only report services that HAVE rows, so a service
  # that stored nothing simply vanished from the output — which is precisely the
  # service someone is looking for when they ask why it is missing.
  #
  # For each one, the row count and the evidence that explains it: when its log
  # file was last written, or that no file bears its name at all. That last case
  # is the only one that is a fault rather than an idle service, and it was
  # indistinguishable from silence before.
  info "selected services (last hour)"
  SERVICES_LIST=$(python3 - "$CONF" <<'PY' 2>/dev/null || true
import json, sys
try:
    for s in (json.load(open(sys.argv[1])).get("logServices") or []):
        if s:
            print(s)
except Exception:
    pass
PY
)
  NOW_EPOCH=$(date +%s)

  # Read into an array, NOT `printf … | while read`. pgq is `docker exec -i`,
  # which attaches stdin and drains it — inside a read loop fed by a pipe it
  # consumes the remaining service names, so the loop ran exactly once and the
  # section listed one service out of six while looking complete.
  mapfile -t SELECTED < <(printf '%s\n' "$SERVICES_LIST")

  for svc in "${SELECTED[@]}"; do
    [ -n "$svc" ] || continue

    # Doubling the quote is the SQL escape for a literal quote. These names come
    # from pm2 on this machine rather than from us, so they are not trusted into
    # a query unescaped even though doctor already runs as root.
    #
    # </dev/null belongs here for the same reason as the array above: it is what
    # makes the loop independent of whatever stdin the script was given.
    esc=$(printf '%s' "$svc" | sed "s/'/''/g")
    rows=$(pgq -c "SELECT count(*) FROM log_entries
                   WHERE service = '$esc' AND ts > now() - interval '1 hour';" \
                 </dev/null 2>/dev/null || echo 0)

    newest=$(find /root/.pm2/logs /home/*/.pm2/logs -maxdepth 1 -type f \
               \( -name "$svc-out*.log" -o -name "$svc-error*.log" -o -name "$svc.log" \) \
               -printf '%T@ %s %p\n' 2>/dev/null | sort -rn | head -1)

    if [ -n "$newest" ]; then
      mtime=${newest%%.*}
      size=$(printf '%s' "$newest" | awk '{print $2}')
      age=$(( NOW_EPOCH - mtime ))
      if   [ "$age" -lt 120 ]   ; then when="${age}s ago"
      elif [ "$age" -lt 7200 ]  ; then when="$((age / 60))m ago"
      elif [ "$age" -lt 172800 ]; then when="$((age / 3600))h ago"
      else                            when="$((age / 86400))d ago"
      fi
      detail="log written $when, ${size} bytes"
      # A file that has not been touched in an hour cannot produce rows in the
      # last hour. Saying so removes the only other suspect.
      [ "${rows:-0}" -eq 0 ] && [ "$age" -gt 3600 ] && detail="$detail — service is silent"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qxF "$svc"; then
      detail="docker container — logs come from the docker socket, not a file"
    else
      detail="NO log file matching $svc-*.log — check the pm2 process name"
    fi

    printf '                 %-32s %6s rows   %s\n' "$svc" "${rows:-0}" "$detail"
  done

  # ── rollup freshness ───────────────────────────────────────────────────────
  #
  # The charts read rollups; everything above reads raw rows. When those two
  # disagree the screen shows a service that stopped hours ago while the
  # database is plainly still being written, and nothing here said so — the
  # timer reports "success" because a run that produces no rows still exits 0.
  #
  # Reported as a lag against the newest raw row rather than against now(), so
  # a machine that is genuinely idle does not read as broken.
  for t in log_rollup endpoint_rollup; do
    [ "$(pgq -c "SELECT to_regclass('$t') IS NOT NULL;" </dev/null 2>/dev/null)" = "t" ] || continue
    LAG=$(pgq -f - </dev/null 2>/dev/null <<SQL
SELECT coalesce(
         round(extract(epoch FROM (
           (SELECT max(ts) FROM log_entries) - (SELECT max(bucket) FROM $t)
         )) / 60)::text, 'never')
SQL
)
    NEWEST=$(pgq -c "SELECT coalesce(max(bucket)::text, 'none') FROM $t;" </dev/null 2>/dev/null || echo '?')

    if [ "$LAG" = "never" ] || [ -z "$LAG" ]; then
      bad "$t has no rows at all — the charts it feeds will be blank"
      info "run: logagent rollup --backfill ${DAYS:-3}"
    elif [ "$LAG" -gt 20 ] 2>/dev/null; then
      # Buckets are five minutes wide and the timer runs every five, so up to
      # ten minutes behind is normal. Twenty is not.
      bad "$t is ${LAG} min behind the newest log row (newest bucket $NEWEST)"
      info "the charts stop there while logs keep arriving. Check:"
      info "  systemctl status ai-terminal-rollup.service"
      info "  journalctl -u ai-terminal-rollup.service -n 30 --no-pager"
      info "then backfill the gap: logagent rollup --backfill ${DAYS:-3}"
    else
      ok "$t current (${LAG} min behind the newest log row)"
    fi
  done

  # ── endpoints ──────────────────────────────────────────────────────────────
  #
  # The app's key-operations table reads endpoint_rollup. Reported separately
  # from latency because the two fail independently: a machine can time every
  # request and still show no endpoints, when the parser reads a duration out of
  # a line that never carried a URL.
  E_TABLE=$(pgq -c "SELECT to_regclass('endpoint_rollup') IS NOT NULL;" 2>/dev/null || echo f)
  if [ "$E_TABLE" != "t" ]; then
    bad "endpoints      endpoint_rollup is missing — the schema did not apply"
    info "run the installer again; it is idempotent"
  else
    E_ROWS=$(pgq -c "SELECT count(*) FROM endpoint_rollup
                     WHERE bucket > now() - interval '1 hour';" 2>/dev/null || echo 0)
    if [ "${E_ROWS:-0}" -gt 0 ]; then
      ok "endpoints      $E_ROWS route buckets in the last hour"
      pgq -c "SELECT '                 ' || coalesce(method,'') || ' ' || route ||
                     '  ' || sum(calls) || ' calls  ' ||
                     round(100.0 * sum(errors) / NULLIF(sum(calls),0), 1) || '% err' ||
                     coalesce('  p95 ' || round(max(p95_ms)::numeric, 0) || 'ms', '')
              FROM endpoint_rollup
              WHERE bucket > now() - interval '1 hour'
              GROUP BY method, route
              ORDER BY sum(calls) DESC LIMIT 5;" 2>/dev/null || true
    elif [ "${R_ROUTE:-0}" -gt 0 ]; then
      # Routes are being parsed but nothing has aggregated them yet.
      info "endpoints      no rollup rows yet — the rollup timer runs every 5"
      info "               minutes, or run: logagent rollup"
    else
      info "endpoints      no route was parsed from any line in the last hour."
      info "               An endpoint appears once a log line carries both a"
      info "               method and a URL, e.g. method=GET url=/leads/42"
    fi
  fi

  # A partitioned table with no partition covering today rejects every insert.
  # host_metrics and metrics are both partitioned, so one having rows and the
  # other not is exactly what a missing partition looks like.
  for t in log_entries metrics host_metrics; do
    n=$(pgq -c "SELECT count(*) FROM pg_class c
                JOIN pg_inherits i ON i.inhrelid = c.oid
                JOIN pg_class p ON p.oid = i.inhparent
                WHERE p.relname = '$t'
                  AND c.relname >= '${t}_$(date -u +%Y_%m_%d)';" 2>/dev/null || echo 0)
    if [ "${n:-0}" -gt 0 ]; then
      info "partitions     $t: $n covering today onward"
    else
      bad "partitions     $t has NO partition for today — every insert is rejected"
    fi
  done
else
  bad "container $PG_CONTAINER is not running"
fi

# ── 7. recent collector output ───────────────────────────────────────────────
#
# Scoped to the CURRENT run, not the last N lines.
#
# A plain tail mixes a start that failed with the one that then succeeded, so a
# config error already fixed minutes ago reads exactly like a live one — and the
# reverse: a real error scrolls out of view behind healthy startup chatter. The
# only question worth answering is whether the collector that is running right
# now has complained.
head_ "collector errors since it started"
SINCE=$(systemctl show vector -p ActiveEnterTimestamp --value 2>/dev/null)
if [ -z "$SINCE" ]; then
  info "collector has never started"
else
  # systemd prints "Mon 2026-08-10 23:22:02 IST", which journalctl does not
  # reliably parse. Convert to epoch, which it always accepts as @<seconds>.
  SINCE_ARG=$(date -d "$SINCE" +@%s 2>/dev/null) || SINCE_ARG="$SINCE"
  [ -n "$SINCE_ARG" ] || SINCE_ARG="$SINCE"

  V_JOURNAL=$(journalctl -u vector --no-pager -o cat --since "$SINCE_ARG" 2>/dev/null)

  V_ERRS=$(printf '%s\n' "$V_JOURNAL" | grep -E 'ERROR|error\[E[0-9]+\]|panicked' | head -25)
  if [ -n "$V_ERRS" ]; then
    bad "the running collector is logging errors:"
    printf '%s\n' "$V_ERRS" | sed 's/^/          /'
  else
    ok "no errors since $SINCE"
  fi

  # Warnings reported separately and NOT counted as problems. A VRL warning does
  # not stop the collector, so failing the verdict on one would train people to
  # ignore the verdict. But it is still a mistaken assumption in the config, and
  # the previous grep matched only "error[E...]" — so a warning[E620] sat in
  # plain sight two lines under "no problems found".
  V_WARNS=$(printf '%s\n' "$V_JOURNAL" | grep -E 'warning\[E[0-9]+\]' | head -10)
  if [ -n "$V_WARNS" ]; then
    info "config warnings (collector runs, but the config asserts something untrue):"
    printf '%s\n' "$V_WARNS" | sed 's/^/          /'
  fi
fi

# Restart count separates "started cleanly" from "crash-looping into a start
# that happened to work". NRestarts survives the restarts themselves.
info "restarts       $(systemctl show vector -p NRestarts --value 2>/dev/null || echo '?')"

head_ "last 25 collector log lines"
info "(may include a previous, already-corrected start — see the section above)"
journalctl -u vector --no-pager --lines=25 -o cat 2>/dev/null | sed 's/^/  /' \
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
