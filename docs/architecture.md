# Architecture

## Components

```
┌─────────────────────────── one machine ────────────────────────────┐
│                                                                     │
│  /root/.pm2/logs/*.log ──┐                                          │
│  /var/run/docker.sock ───┼──▶  Vector  ──▶  receiver.py  ──▶  PG    │
│  journald ───────────────┤     ~40 MB       ~15 MB          ~200 MB │
│  /var/log/nginx/*.log ───┘                                container │
│                                                                     │
│  timers:  partitions (daily) · watchdog (5 min) · metrics (60 s)    │
└─────────────────────────────────────────────────────────────────────┘
                                 ▲
                                 │ SSH tunnel — Postgres is loopback-only
                          ai-terminal app
```

| Component | Role | Footprint |
|---|---|---|
| Vector | tail, parse, redact, batch | ~40 MB |
| `receiver.py` | HTTP → `COPY` into Postgres | ~15 MB |
| Postgres container | storage, partitioned daily | ~200 MB |
| `partitions.sh` | create ahead, drop expired | oneshot |
| `watchdog.sh` | emergency disk guard | oneshot |
| `metrics.sh` | PM2 / Docker / host metrics | oneshot |
| `logagent` | control surface for the app | — |

## Design decisions

### Why Vector

`docker_logs` reads the Docker socket directly, so every container is discovered
**by name**, new containers are picked up automatically, and **no log-driver change
is required**. The alternative — switching Docker to the journald driver — forces a
restart of every running container, including production databases.

| | RAM | Docker logs | Discovery |
|---|---|---|---|
| OTel Collector | ~150 MB | needs journald driver | manual |
| Fluent Bit | ~20 MB | needs journald driver | manual |
| **Vector** | ~40 MB | socket, no restart | **automatic, by name** |

### Why a receiver instead of a `postgres` sink

Sink availability varies across Vector builds. A one-line installer that must work
on any machine cannot depend on a specific build's feature set. The receiver is
Python 3 standard library only — no pip, no venv, no wheels to compile on a small VPS.

It also gives an explicit place to control backpressure: the queue **sheds load**
when full rather than growing, and systemd caps the process at 256 MB. The agent
must never OOM the machine it is monitoring.

Delivery is at-least-once. Vector retries on any non-2xx, so a failed `COPY` is not
data loss — and the retries it creates are absorbed by the `fp` content hash.

### Why a dedicated Postgres container

Not a database inside an existing application Postgres. Log write volume, WAL and
disk accounting never touch production data, and uninstall is a container removal
that reports exact bytes freed.

Bound to `127.0.0.1` only. Nothing is exposed to the network; the app connects
through an SSH tunnel it already maintains.

### Why partitions

Retention is `DROP TABLE`, which returns disk instantly. `DELETE` would leave dead
tuples and **grow** the database before vacuum shrinks it — exactly wrong on a host
that is already short on space.

Partitions are created **seven days ahead**. A single failed maintenance run must
never leave a day without a partition, because every insert for that day would fail
and the loss would be silent.

### Why `UNLOGGED`

Partitions skip the write-ahead log. Losing recent rows on an unclean crash is an
acceptable trade for logs; doubling write cost and WAL volume on a small VPS is not.

### Why BRIN

For append-only, time-ordered rows, BRIN costs kilobytes where a B-tree costs
gigabytes — and range scans over time are what this table exists for.

### Why keyset pagination

Rows arrive continuously. `OFFSET` paging **skips and repeats** lines as new data
lands above the window. Every query the app issues must use:

```sql
WHERE (ts, id) < ($lastTs, $lastId)
ORDER BY ts DESC, id DESC
LIMIT 200
```

## Schema

See [../sql/schema.sql](../sql/schema.sql).

| Table | Contents | Retention |
|---|---|---|
| `log_entries` | log lines | user-set, 1–30 days |
| `metrics` | per-service CPU, memory, restarts, status | 30 days |
| `host_metrics` | host CPU, load, memory, disk | 90 days |
| `alert_rules` / `alert_events` / `alert_state` | alerting | 90 days |
| `maintenance_log` | every automatic drop | 90 days |

Field names follow OpenTelemetry conventions (`service.name`, `severity_text`,
`body`, `trace_id`) so migrating to ClickHouse later is a data copy rather than a
rewrite of the agent, the queries and the app. `trace_id` and `span_id` exist but
are unused.

## Data flow

1. Vector tails files and the Docker socket
2. `multiline` joins continuation lines — a 30-line stack trace becomes **one row**
3. `remap` derives service, kind, timestamp and severity; **redacts secrets**
4. `filter` keeps only selected services
5. `http` sink batches 500 events or 5 seconds, whichever comes first
6. Receiver converts to `COPY` text format and streams into Postgres

Redaction happens at step 3 — **before** the write. This store is queried from a
phone and kept for days; a credential must never reach the database at all.

## Metrics

Collected for **every** service regardless of log selection. About 100 bytes per
service per minute — roughly 5 MB/day for fifty services. Far too cheap to filter,
and an unselected service still needs a graph the moment it turns suspicious.

Docker health comes from `docker ps`, not `docker stats`, because stats omits it.
Health is what surfaces a container that has been failing checks for months while
still reporting "Up".

## Limits

| | |
|---|---|
| Scale | Postgres is comfortable to roughly 50–100M rows |
| Search | `ILIKE`, not a purpose-built log index |
| Traces | none — no spans, no latency percentiles, no dependency map |
| Ingest | local sources only; no network OTLP endpoint |
| Scope | one machine per agent; the app merges across machines |

### When to outgrow this

- a request routinely crosses three or more services → you need traces
- log queries become slow → ClickHouse
- six or more machines → per-machine stores stop scaling
- someone asks for p95 latency → traces
- non-SSH sources (serverless, mobile, browser) → real OTLP ingest

Because the schema already uses OpenTelemetry field names, that migration is a data
copy and a driver swap — not a rewrite.
