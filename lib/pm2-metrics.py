#!/usr/bin/env python3
"""Turn `pm2 jlist` output into INSERT statements for the metrics table.

Reads the JSON on stdin, writes SQL on stdout. One row per PM2 process.

A separate file rather than a heredoc, and that is the whole point of it: the
previous shape was

    pm2 jlist | python3 - "$HOST" <<'PY' ... PY

where `python3 -` takes its *program* from stdin and the heredoc is the later
redirection, so the heredoc won stdin and the pipe from pm2 had no reader at
all. pm2 died writing to it —

    Error: write EPIPE
        at /usr/local/lib/node_modules/pm2/lib/API.js:1674:24

— and this script read the already-consumed program text instead of the JSON,
failed to parse it, and emitted nothing. cpu and memory were blank for every
PM2 service while everything upstream looked healthy.
"""

import json
import sys


def sql_str(value):
    return str(value).replace("'", "''")


def main():
    host = sql_str(sys.argv[1])

    try:
        procs = json.load(sys.stdin)
    except Exception as exc:  # noqa: BLE001 - the reason goes to the diagnostic
        print(f"pm2 jlist output was not valid JSON: {exc}", file=sys.stderr)
        return 0

    if not isinstance(procs, list):
        print("pm2 jlist did not return a list", file=sys.stderr)
        return 0

    for proc in procs:
        monit = proc.get("monit") or {}
        env = proc.get("pm2_env") or {}
        name = sql_str(proc.get("name", ""))
        if not name:
            continue
        print(
            "INSERT INTO metrics(ts,host,service,kind,cpu,mem_bytes,restarts,status) "
            "VALUES(now(),'{h}','{n}','pm2',{c},{m},{r},'{s}');".format(
                h=host,
                n=name,
                c=float(monit.get("cpu") or 0),
                m=int(monit.get("memory") or 0),
                r=int(env.get("restart_time") or 0),
                s=sql_str(env.get("status", "")),
            )
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
