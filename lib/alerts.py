#!/usr/bin/env python3
"""Alert evaluator.

Runs every 60s. Evaluates every enabled rule against the last window, maintains
firing/resolved state, and notifies on transitions only.

Two design rules matter more than the individual checks:

  Rules GROUP BY service, never enumerate it. A service deployed tomorrow
  inherits every rule the moment its first row lands. Nothing to configure.

  Notify on TRANSITION, not on condition. A crash loop sends one alert and one
  recovery. Evaluating every 60s and notifying every time would have sent 89,304
  messages for the restart loop this system exists to catch.

Coverage is deliberately uneven and the app is told so via `logagent alerts
--coverage`: metric rules (crash_loop, service_down, unhealthy, disk, cpu,
memory, cert_expiry) cover every discovered service, while log rules
(error_rate, latency_p95, endpoint_latency, endpoint_errors, traffic_drop) only
cover services with logging enabled. A half-monitored service must never read
as fully covered.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Any

LIB = os.path.dirname(os.path.abspath(__file__))
CONF = "/etc/ai-terminal/logagent.conf"
CONTAINER = os.environ.get("PG_CONTAINER", "ai-terminal-logs")
PG_USER = os.environ.get("PG_USER", "logagent")
PG_DB = os.environ.get("PG_DB", "logs")
HOST = os.environ.get("HOST_NAME", "unknown")

SEP = "\x1f"  # unlikely in log bodies; safer than '|' for splitting rows


def q(sql: str) -> list[list[str]]:
    """Run SQL, return rows as lists of strings. Never raises."""
    try:
        p = subprocess.run(
            ["docker", "exec", "-i", CONTAINER, "psql", "-U", PG_USER, "-d", PG_DB,
             "-qtAX", "-F", SEP, "-c", sql],
            capture_output=True, text=True, timeout=45,
        )
        if p.returncode != 0:
            print(f"sql failed: {p.stderr.strip()[:200]}", file=sys.stderr)
            return []
        return [line.split(SEP) for line in p.stdout.strip().splitlines() if line]
    except Exception as exc:  # noqa: BLE001 - the evaluator must never die
        print(f"sql error: {exc}", file=sys.stderr)
        return []


def esc(v: str) -> str:
    return str(v).replace("'", "''")


def load_conf() -> dict:
    try:
        return json.load(open(CONF))
    except Exception:  # noqa: BLE001
        return {}


# ── condition queries ────────────────────────────────────────────────────────
# Each returns rows of (service, value). A returned row means the rule's
# condition is currently TRUE for that service.

def cond_error_rate(threshold: float, window: int) -> list[list[str]]:
    # Ignored error groups are excluded: triage should silence the alert too,
    # otherwise "ignore" is a lie and people stop trusting the button.
    # position(), not LIKE: an error message containing % or _ would otherwise be
    # read as a wildcard pattern and silence the wrong things.
    return q(f"""
        SELECT l.service, count(*)::text
        FROM log_entries l
        WHERE l.ts > now() - interval '{window} seconds'
          AND l.severity IN ('ERROR','FATAL')
          AND NOT EXISTS (
            SELECT 1 FROM error_groups g
            WHERE g.service = l.service
              AND g.state = 'ignored'
              AND position(left(g.sample, 40) in l.body) = 1
          )
        GROUP BY l.service
        HAVING count(*) > {threshold}
    """)


def cond_crash_loop(threshold: float, window: int) -> list[list[str]]:
    # Restart COUNT is cumulative, so compare newest against oldest in the window
    # rather than reading the absolute value — otherwise a service with a long
    # history fires forever.
    return q(f"""
        WITH w AS (
          SELECT service,
                 max(restarts) - min(restarts) AS delta
          FROM metrics
          WHERE ts > now() - interval '{window} seconds'
            AND kind = 'pm2' AND restarts IS NOT NULL
          GROUP BY service
        )
        SELECT service, delta::text FROM w WHERE delta > {threshold}
    """)


def cond_service_down(_t: float, window: int) -> list[list[str]]:
    # Latest sample per service. A minimum lookback avoids firing on a single
    # missed collection cycle.
    return q(f"""
        SELECT service, '1' FROM (
          SELECT DISTINCT ON (service) service, status
          FROM metrics
          WHERE ts > now() - interval '{max(window, 180)} seconds'
          ORDER BY service, ts DESC
        ) s
        WHERE status NOT IN ('online','running','healthy')
    """)


def cond_unhealthy(_t: float, window: int) -> list[list[str]]:
    return q(f"""
        SELECT service, '1' FROM (
          SELECT DISTINCT ON (service) service, status
          FROM metrics
          WHERE ts > now() - interval '{max(window, 300)} seconds'
          ORDER BY service, ts DESC
        ) s
        WHERE status = 'unhealthy'
    """)


def cond_disk(threshold: float, window: int) -> list[list[str]]:
    # Host-level, so the "service" key is a fixed sentinel rather than a name.
    return q(f"""
        SELECT '_host_', round(v)::text FROM (
          SELECT 100.0 * disk_used / nullif(disk_total,0) AS v
          FROM host_metrics
          WHERE ts > now() - interval '{window} seconds'
          ORDER BY ts DESC LIMIT 1
        ) d WHERE v > {threshold}
    """)


def cond_cpu(threshold: float, window: int) -> list[list[str]]:
    return q(f"""
        SELECT service, round(avg(cpu)::numeric,1)::text
        FROM metrics
        WHERE ts > now() - interval '{window} seconds' AND cpu IS NOT NULL
        GROUP BY service
        HAVING avg(cpu) > {threshold}
    """)


def cond_memory(threshold: float, window: int) -> list[list[str]]:
    # Percentage of host total, so the threshold means the same thing on any box.
    return q(f"""
        WITH tot AS (SELECT max(mem_total) AS t FROM host_metrics
                     WHERE ts > now() - interval '{window} seconds')
        SELECT m.service, round(100.0 * avg(m.mem_bytes) / nullif(tot.t,0))::text
        FROM metrics m, tot
        WHERE m.ts > now() - interval '{window} seconds' AND m.mem_bytes IS NOT NULL
        GROUP BY m.service, tot.t
        HAVING 100.0 * avg(m.mem_bytes) / nullif(tot.t,0) > {threshold}
    """)


def cond_latency_p95(threshold: float, window: int) -> list[list[str]]:
    # From rollups, which already hold percentiles derived from attrs.duration_ms.
    return q(f"""
        SELECT service, round(max(p95_ms)::numeric)::text
        FROM log_rollup
        WHERE bucket > now() - interval '{window} seconds' AND p95_ms IS NOT NULL
        GROUP BY service
        HAVING max(p95_ms) > {threshold}
    """)


def cond_endpoint_latency(threshold: float, window: int) -> list[list[str]]:
    """Any single endpoint slower than the threshold.

    Distinct from latency_p95, which is per service and therefore averages the
    one slow endpoint away: a service whose p95 is 300 ms can contain a route
    sitting at 9 seconds, and that route is what wakes someone at 3 a.m.

    The key carries the operation, so the notification names the endpoint
    rather than the service that happens to contain it.
    """
    return q(f"""
        SELECT service || '  ' || btrim(method || ' ' || route),
               round(max(p95_ms)::numeric)::text
        FROM endpoint_rollup
        WHERE bucket > now() - interval '{window} seconds' AND p95_ms IS NOT NULL
        GROUP BY service, method, route
        -- A minimum call count, or one slow request on a rarely-used route
        -- pages someone. Percentiles over a handful of samples are not
        -- percentiles.
        HAVING sum(calls) >= 5 AND max(p95_ms) > {threshold}
    """)


def cond_endpoint_errors(threshold: float, window: int) -> list[list[str]]:
    """An endpoint failing more than the threshold percentage of its calls.

    A RATE, not a count: the endpoint called twice a minute that fails every
    time is a bigger problem than the one called ten thousand times that fails
    fifty, and a count alert only ever finds the second.

    4xx is excluded — errors here is 5xx and lines the parser judged ERROR.
    Counting a scanner's 404s would make this fire on traffic nobody controls.
    """
    return q(f"""
        SELECT service || '  ' || btrim(method || ' ' || route),
               round(100.0 * sum(errors) / nullif(sum(calls), 0))::text
        FROM endpoint_rollup
        WHERE bucket > now() - interval '{window} seconds'
        GROUP BY service, method, route
        HAVING sum(calls) >= 10
           AND 100.0 * sum(errors) / nullif(sum(calls), 0) > {threshold}
    """)


def cond_traffic_drop(threshold: float, window: int) -> list[list[str]]:
    """Requests well below the same window one week earlier.

    The failure no threshold catches: nothing errors, nothing restarts, latency
    is excellent — because almost no traffic is arriving. A load balancer
    pointed elsewhere, a DNS change, an expired client credential all look
    perfectly healthy on every other check here.

    Week-over-week rather than against the previous hour, because traffic has a
    daily shape: comparing 3 a.m. against 2 a.m. reports an outage every night.
    """
    return q(f"""
        WITH current AS (
          SELECT service, sum(timed) AS n FROM log_rollup
          WHERE bucket > now() - interval '{window} seconds'
          GROUP BY service
        ), baseline AS (
          SELECT service, sum(timed) AS n FROM log_rollup
          WHERE bucket >  now() - interval '7 days' - interval '{window} seconds'
            AND bucket <= now() - interval '7 days'
          GROUP BY service
        )
        SELECT c.service,
               round(100.0 * (b.n - c.n) / nullif(b.n, 0))::text
        FROM current c JOIN baseline b USING (service)
        -- A quiet baseline makes any dip look catastrophic. Below this the
        -- comparison is noise, and a machine with under a week of history has
        -- no baseline row at all, so it cannot fire.
        WHERE b.n >= 100
          AND 100.0 * (b.n - c.n) / nullif(b.n, 0) > {threshold}
    """)


def cond_cert_expiry(threshold: float, _w: int) -> list[list[str]]:
    return q(f"""
        SELECT domain, days_left::text FROM cert_expiry
        WHERE days_left IS NOT NULL AND days_left <= {threshold}
    """)


CONDITIONS = {
    "error_rate": cond_error_rate,
    "crash_loop": cond_crash_loop,
    "service_down": cond_service_down,
    "unhealthy": cond_unhealthy,
    "disk": cond_disk,
    "cpu": cond_cpu,
    "memory": cond_memory,
    "latency_p95": cond_latency_p95,
    "endpoint_latency": cond_endpoint_latency,
    "endpoint_errors": cond_endpoint_errors,
    "traffic_drop": cond_traffic_drop,
    "cert_expiry": cond_cert_expiry,
}

MESSAGES = {
    "error_rate":   "{service}: {value} errors in the last {window}",
    "crash_loop":   "{service}: restarted {value} times in the last {window}",
    "service_down": "{service}: not running",
    "unhealthy":    "{service}: health check failing",
    "disk":         "disk {value}% full",
    "cpu":          "{service}: CPU {value}% sustained",
    "memory":       "{service}: memory {value}% of host",
    "latency_p95":  "{service}: p95 latency {value} ms",
    # `service` here already carries the operation, so these read as
    # "api  GET /leads/:id: p95 latency 9400 ms".
    "endpoint_latency": "{service}: p95 latency {value} ms",
    "endpoint_errors":  "{service}: {value}% of calls failing",
    "traffic_drop":     "{service}: requests {value}% below the same {window} last week",
    "cert_expiry":  "{service}: TLS certificate expires in {value} days",
}


# Kinds whose key is not a service name. `disk` reports the machine under a
# fixed sentinel and `cert_expiry` reports a domain, so filtering either by
# service name would silence it entirely.
HOST_KINDS = {"disk", "cert_expiry"}

# What separates a service from the operation inside it in an endpoint key —
# see cond_endpoint_latency. Written once here because the scope filter has to
# split on exactly what those queries joined with.
KEY_SEP = "  "


def scoped(kind: str, scope: str, firing: dict[str, str]) -> dict[str, str]:
    """Restrict a rule's results to the service it was scoped to.

    Rules carry `target.service`, which the evaluator did not read: a rule
    created for one service fired for every service, and the scope picker in
    the app was decorative. Rules still GROUP BY service in SQL — the scope is
    applied to the result, so a rule left at `*` keeps covering services that
    did not exist when it was written.

    Endpoint kinds key on `service<sep>METHOD /route`, so a service scope has
    to match the prefix rather than the whole key.
    """
    if scope == "*" or kind in HOST_KINDS:
        return firing
    return {
        key: value
        for key, value in firing.items()
        if key == scope or key.startswith(scope + KEY_SEP)
    }


def human_window(secs: int) -> str:
    if secs >= 86400:
        return f"{secs // 86400}d"
    if secs >= 3600:
        return f"{secs // 3600}h"
    return f"{secs // 60}m"


def notify(message: str, data: dict[str, Any]) -> None:
    try:
        subprocess.run(
            ["python3", os.path.join(LIB, "notify.py"), message, json.dumps(data)],
            capture_output=True, text=True, timeout=60,
        )
    except Exception as exc:  # noqa: BLE001
        print(f"notify failed: {exc}", file=sys.stderr)


def evaluate() -> None:
    conf = load_conf()
    if conf.get("paused", True):
        return

    rules = q("""
        SELECT id, name, kind, coalesce(threshold,0), coalesce(window_secs,300),
               coalesce(silenced_until < now(), true),
               coalesce(target->>'service', '*')
        FROM alert_rules WHERE enabled
    """)

    for rid, name, kind, threshold, window, not_silenced, scope in rules:
        fn = CONDITIONS.get(kind)
        if fn is None:
            continue
        try:
            rows = fn(float(threshold), int(window))
        except Exception as exc:  # noqa: BLE001 - one bad rule must not stop the rest
            print(f"rule {name} failed: {exc}", file=sys.stderr)
            continue

        firing = {r[0]: r[1] for r in rows if r and r[0]}
        firing = scoped(kind, scope, firing)

        prev = {
            r[0]: r[1]
            for r in q(f"SELECT service, state FROM alert_state WHERE rule_id = {rid}")
            if r and r[0]
        }

        # ── newly firing ────────────────────────────────────────────────────
        for service, value in firing.items():
            if prev.get(service) == "firing":
                continue
            q(f"""
              INSERT INTO alert_state (rule_id, service, state, since, notified_at)
              VALUES ({rid}, '{esc(service)}', 'firing', now(), now())
              ON CONFLICT (rule_id, service)
              DO UPDATE SET state='firing', since=now(), notified_at=now();
              INSERT INTO alert_events (rule_id, service, host, value, state)
              VALUES ({rid}, '{esc(service)}', '{esc(HOST)}',
                      nullif('{esc(value)}','')::real, 'firing');
            """)
            if not_silenced == "t":
                msg = MESSAGES.get(kind, "{service}: {value}").format(
                    service=service, value=value, window=human_window(int(window)))
                notify(f"🔴 {msg}", {
                    "host": HOST, "service": service, "rule": name,
                    "kind": kind, "state": "firing", "value": value,
                })

        # ── recovered ───────────────────────────────────────────────────────
        for service, state in prev.items():
            if state != "firing" or service in firing:
                continue
            q(f"""
              UPDATE alert_state SET state='resolved', since=now()
                WHERE rule_id={rid} AND service='{esc(service)}';
              INSERT INTO alert_events (rule_id, service, host, state)
              VALUES ({rid}, '{esc(service)}', '{esc(HOST)}', 'resolved');
            """)
            if not_silenced == "t":
                notify(f"✅ {service}: {name} recovered", {
                    "host": HOST, "service": service, "rule": name,
                    "kind": kind, "state": "resolved",
                })


def coverage() -> None:
    """Which rules actually apply to which service.

    Log rules only cover services with logging enabled. Printing this is how the
    app avoids showing a half-monitored service as fully covered.
    """
    conf = load_conf()
    selected = set(conf.get("logServices") or [])
    services = {r[0] for r in q("SELECT DISTINCT service FROM metrics "
                                "WHERE ts > now() - interval '1 hour'") if r and r[0]}
    # Anything read out of log_rollup or endpoint_rollup only covers a service
    # whose logs are actually being collected. Leaving the new kinds out here
    # would show a service with logging disabled as covered by a rule that
    # cannot see it.
    log_kinds = {"error_rate", "latency_p95", "endpoint_latency",
                 "endpoint_errors", "traffic_drop"}
    kinds = [r[0] for r in q("SELECT kind FROM alert_rules WHERE enabled") if r]

    rows = [
        {
            "service": s,
            "metrics": True,
            "logs": s in selected,
            "rules": sorted(k for k in kinds if k not in log_kinds or s in selected),
            "unavailable": sorted(k for k in kinds if k in log_kinds and s not in selected),
        }
        for s in services
    ]
    rows.sort(key=lambda d: d["service"])
    print(json.dumps({"services": rows}))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--coverage":
        coverage()
    else:
        evaluate()
