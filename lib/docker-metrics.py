#!/usr/bin/env python3
"""Turn `docker stats` output into INSERT statements for the metrics table.

    docker-metrics.py <host> <container-to-skip> <health-map>

Reads `{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}` lines on stdin, writes SQL on
stdout. The health map is `{{.Names}}|{{.Status}}` lines from `docker ps`, which
`docker stats` does not report — and a container failing its health check for
months while still reporting "Up" is exactly what nobody notices.

A separate file rather than a heredoc, for the reason given at length in
pm2-metrics.py: a piped `python3 - <<'PY'` never sees the pipe.
"""

import re
import sys

UNITS = {
    "B": 1,
    "KIB": 1024,
    "MIB": 1024**2,
    "GIB": 1024**3,
    "KB": 1000,
    "MB": 1000**2,
    "GB": 1000**3,
}


def to_bytes(text):
    m = re.match(r"([\d.]+)\s*([A-Za-z]+)", text.strip())
    if not m:
        return 0
    return int(float(m.group(1)) * UNITS.get(m.group(2).upper(), 1))


def parse_health(raw):
    health = {}
    for line in raw.splitlines():
        if "|" not in line:
            continue
        name, status = line.split("|", 1)
        health[name] = (
            "unhealthy" if "unhealthy" in status
            else "healthy" if "healthy" in status
            else "running"
        )
    return health


def main():
    host, skip, health_raw = sys.argv[1], sys.argv[2], sys.argv[3]
    health = parse_health(health_raw)

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
    return 0


if __name__ == "__main__":
    sys.exit(main())
