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
  command -v pm2 >/dev/null 2>&1 || return 0

  # PM2_HOME must be explicit. systemd does not set HOME for a system service
  # unless User= is given, and PM2 resolves its process store from PM2_HOME or
  # $HOME/.pm2 — with neither, `pm2 jlist` quietly returns nothing. Because the
  # call is `|| true`-ed, that surfaced only as cpu and memory permanently blank
  # for every PM2 service, while discovery over SSH (where HOME is set) listed
  # them all and looked perfectly healthy.
  #
  # Iterating the homes also fixes a case the single call never handled: PM2
  # running under a non-root user, which is the norm on shared boxes.
  local home
  for home in /root/.pm2 /home/*/.pm2; do
    [ -d "$home" ] || continue
    PM2_HOME="$home" pm2 jlist 2>/dev/null | python3 - "$HOST_NAME" <<'PY' || true
import json, sys
host = sys.argv[1]
try:
    procs = json.load(sys.stdin)
except Exception:
    procs = []
for p in procs:
    monit = p.get("monit") or {}
    env = p.get("pm2_env") or {}
    name = str(p.get("name", "")).replace("'", "''")
    if not name:
        continue
    print(
        "INSERT INTO metrics(ts,host,service,kind,cpu,mem_bytes,restarts,status) "
        "VALUES(now(),'{h}','{n}','pm2',{c},{m},{r},'{s}');".format(
            h=host, n=name,
            c=float(monit.get("cpu") or 0),
            m=int(monit.get("memory") or 0),
            r=int(env.get("restart_time") or 0),
            s=str(env.get("status", "")).replace("'", "''"),
        )
    )
PY
  done
}

collect_docker() {
  command -v docker >/dev/null 2>&1 || return 0

  # `docker stats` gives live CPU/memory; `docker ps` gives health, which stats
  # omits. Health is what surfaces a container that has been failing checks for
  # months while still reporting "Up".
  local health_map
  health_map=$(docker ps --format '{{.Names}}|{{.Status}}' 2>/dev/null || true)

  docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null \
  | python3 - "$HOST_NAME" "$PG_CONTAINER" "$health_map" <<'PY' || true
import re, sys
host, skip, health_raw = sys.argv[1], sys.argv[2], sys.argv[3]

health = {}
for line in health_raw.splitlines():
    if "|" in line:
        n, s = line.split("|", 1)
        health[n] = ("unhealthy" if "unhealthy" in s else
                     "healthy" if "healthy" in s else "running")

UNITS = {"B": 1, "KIB": 1024, "MIB": 1024**2, "GIB": 1024**3, "KB": 1000, "MB": 1000**2, "GB": 1000**3}

def to_bytes(text):
    m = re.match(r"([\d.]+)\s*([A-Za-z]+)", text.strip())
    if not m:
        return 0
    return int(float(m.group(1)) * UNITS.get(m.group(2).upper(), 1))

for line in sys.stdin:
    parts = line.strip().split("|")
    if len(parts) < 3 or parts[0] == skip:
        continue
    name = parts[0].replace("'", "''")
    cpu = float(parts[1].replace("%", "") or 0)
    mem = to_bytes(parts[2].split("/")[0])
    status = health.get(parts[0], "running")
    print(
        "INSERT INTO metrics(ts,host,service,kind,cpu,mem_bytes,status) "
        f"VALUES(now(),'{host}','{name}','docker',{cpu},{mem},'{status}');"
    )
PY
}

main() {
  docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" || exit 0
  { collect_host; collect_pm2; collect_docker; } | pgq >/dev/null 2>&1 || true
}

main "$@"
