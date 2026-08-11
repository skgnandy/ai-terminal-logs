#!/usr/bin/env bash
# Metric collection, every 60 seconds.
#
# Metrics are gathered for EVERY service regardless of log selection. At roughly
# 100 bytes per service per minute that is ~5 MB/day for fifty services — far too
# cheap to be worth filtering, and an unselected service still needs a graph the
# moment it becomes suspicious.

set -euo pipefail
. /opt/ai-terminal-logs/lib/common.sh
load_env

collect_host() {
  local total used dtotal dused load1
  read -r total used <<<"$(free -b | awk '/^Mem:/{print $2, $3}')"
  dtotal=$(df -B1 --output=size / | tail -1 | tr -d ' ')
  dused=$(df -B1 --output=used / | tail -1 | tr -d ' ')
  load1=$(awk '{print $1}' /proc/loadavg)

  printf "INSERT INTO host_metrics(ts,host,load1,mem_used,mem_total,disk_used,disk_total) \
VALUES(now(),'%s',%s,%s,%s,%s,%s);\n" \
    "$HOST_NAME" "$load1" "$used" "$total" "$dused" "$dtotal"
}

collect_pm2() {
  local pm2_bin
  pm2_bin=$(find_pm2) || { note "pm2 binary not found on PATH or in any node manager directory"; return 0; }

  # PM2_HOME must be explicit. systemd does not set HOME for a system service
  # unless User= is given, and PM2 resolves its process store from PM2_HOME or
  # $HOME/.pm2 — with neither, `pm2 jlist` quietly returns nothing. Because the
  # call is `|| true`-ed, that surfaced only as cpu and memory permanently blank
  # for every PM2 service, while discovery over SSH (where HOME is set) listed
  # them all and looked perfectly healthy.
  #
  # Iterating the homes also fixes a case the single call never handled: PM2
  # running under a non-root user, which is the norm on shared boxes.
  local home found=0
  for home in /root/.pm2 /home/*/.pm2; do
    [ -d "$home" ] || continue
    found=1
    # The parser is a file, not a heredoc. `python3 - <<'PY'` reads its program
    # from stdin, so the heredoc took the stdin the pipe needed: pm2 wrote into
    # a pipe with no reader and died with EPIPE, and the parser tried to read
    # JSON from its own already-consumed source text. Every PM2 service showed
    # blank cpu and memory while every check upstream passed.
    PM2_HOME="$home" "$pm2_bin" jlist 2>>"$ERR_LOG" \
      | python3 "$LIB_DIR/pm2-metrics.py" "$HOST_NAME" 2>>"$ERR_LOG" || true
  done
  [ "$found" -eq 1 ] || note "pm2 found at $pm2_bin but no .pm2 directory under /root or /home/*"
}

collect_docker() {
  command -v docker >/dev/null 2>&1 || { note "docker not on PATH"; return 0; }

  # `docker stats` gives live CPU/memory; `docker ps` gives health, which stats
  # omits. Health is what surfaces a container that has been failing checks for
  # months while still reporting "Up".
  local health_map
  health_map=$(docker ps --format '{{.Names}}|{{.Status}}' 2>>"$ERR_LOG" || true)

  # Same heredoc-versus-pipe trap as the PM2 collector above — see the comment
  # there. This one lost every container's cpu and memory the same way.
  docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>>"$ERR_LOG" \
    | python3 "$LIB_DIR/docker-metrics.py" "$HOST_NAME" "$PG_CONTAINER" "$health_map" \
        2>>"$ERR_LOG" || true
}

main() {
  docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" \
    || { note "logs database container is not running"; exit 0; }

  # `|| true` because one collector failing must not cost the others their
  # samples — the previous shape lost every metric whenever any single source
  # was unavailable.
  local sql
  sql=$({ collect_host; collect_pm2; collect_docker; }) || true

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "$sql"
    echo "--- collector notes ---" >&2
    cat "$ERR_LOG" >&2 2>/dev/null || true
    return 0
  fi

  # pg_run, not pgq: pgq discards stderr internally, so wrapping it in `2>&1`
  # captured nothing and a statement failing for every row still looked like a
  # collector with nothing to insert.
  local out
  out=$(printf '%s\n' "$sql" | pg_run 2>&1) || true
  [ -n "$out" ] && printf '%s\n' "$out" >> "$ERR_LOG"

  # One file, overwritten each run, so the diagnostic reports what is wrong NOW
  # rather than every failure since install.
  if [ -s "$ERR_LOG" ]; then
    mv "$ERR_LOG" "$STATE/metrics.error"
  else
    rm -f "$ERR_LOG" "$STATE/metrics.error"
  fi
}

# Notes and captured stderr go to one scratch file that main() promotes to
# $STATE/metrics.error. Without this the collector's every failure mode — no
# pm2, no docker, rejected SQL — was indistinguishable from "nothing to report",
# because each one was individually silenced by 2>/dev/null and || true.
ERR_LOG=$(mktemp)
trap 'rm -f "$ERR_LOG"' EXIT
note() { printf '%s\n' "$*" >> "$ERR_LOG"; }

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

main "$@"
