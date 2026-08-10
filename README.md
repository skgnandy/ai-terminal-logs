# ai-terminal-logs

Self-hosted log and metric collection for a single Linux machine. Ships logs from
PM2, Docker, systemd and nginx into a dedicated Postgres container on the same box,
with automatic retention, a disk-pressure watchdog, and alerting to FCM, Telegram
and email.

Designed to be driven remotely by [ai-terminal](https://github.com/skgnandy/ai-terminal)
over SSH — but it is a complete, standalone agent and works fine on its own.

```bash
curl -fsSL https://raw.githubusercontent.com/skgnandy/ai-terminal-logs/main/install.sh | sudo bash
```

That is the whole setup. One command, any machine, no prior knowledge, no flags.
The agent installs **paused** — nothing is collected until you configure it.

---

## Why this exists

A machine running twenty services shows you *state now* and forgets it. `pm2 logs`
is a live tail; a restart wipes the scrollback; a recreated container takes its
history with it. When something breaks at 3am you find out from a customer, and by
then the evidence is gone.

Full observability platforms solve this, but they are built for fleets. A typical
self-hosted stack wants **4 GB of RAM or more** across four or five containers, plus a
machine to put them on. On a VPS already running your applications, that is not a
trade-off — it is an outage.

This agent does the useful 70% in **~250 MB**:

| | This agent |
|---|---|
| RAM | ~250 MB |
| Containers | 1 |
| Storage | Postgres (dedicated container) |
| Logs, retention, search | yes |
| Metrics history | yes |
| Alerting | yes |
| Distributed traces | **no** |
| Cost | none |

If you need distributed traces and p95 latency across dozens of hosts, run a full
platform. If you need to know what broke, when, and be told about it — this is enough.

---

## What it collects

| Source | Mechanism | Discovery |
|---|---|---|
| **PM2** | tails `~/.pm2/logs/*.log` | filename → service name |
| **Docker** | `docker_logs` source over the socket | container name; new containers picked up automatically |
| **systemd** | journald | unit name |
| **nginx** | `/var/log/nginx/*.log` | opt-in: `off` / `errors` / `full` |

Nothing is enumerated in configuration. A new PM2 app or container is discovered on
its own — you only choose whether to *store* its logs.

**No Docker restart is required.** The `docker_logs` source reads the socket directly,
so your production database containers are never touched.

Beyond logs, four background jobs collect what a log line never reports:

| Job | Every | Produces |
|---|---|---|
| **metrics** | 60 s | CPU, memory, restarts, status — for *every* service, selected or not |
| **rollup** | 5 min | 5-minute buckets with **p50/p95/p99 latency**, plus errors grouped by fingerprint |
| **alerts** | 60 s | evaluates every rule, notifies on state *transitions* only |
| **probes** | 10 min | Postgres/Redis/Mongo internals, TLS certificate expiry |

Latency percentiles come from `attrs.duration_ms`, which the parser extracts from HTTP
access lines — so **p95 per service works without tracing**. What still needs spans is
*which layer* was slow.

---

## Architecture

```
┌──────────────────────── one machine ────────────────────────┐
│                                                              │
│   PM2 files ────┐                                            │
│   Docker socket ┼──▶ Vector ──▶ receiver ──▶ Postgres        │
│   journald ─────┤     ~40 MB      ~15 MB     ~200 MB         │
│   nginx files ──┘                            (container)     │
│                                                              │
│   systemd timers:  partitions (daily) · watchdog (5 min)     │
│                    metrics (60 s)  · alerts (60 s)           │
│                    rollup (5 min)  · probes (10 min)         │
└──────────────────────────────────────────────────────────────┘
                              ▲
                              │  SSH tunnel — Postgres is loopback-only
                        ai-terminal app
```

Postgres binds to `127.0.0.1` only. Nothing is exposed to the network; the app
reaches it through an SSH tunnel it already has.

**Ingest path.** Vector batches to a local HTTP receiver which `COPY`s into Postgres.
A Vector `postgres` sink is deliberately *not* used — its availability varies by
build, and a version-dependent install path is unacceptable for a one-line setup.
The receiver is Python 3 standard library only: no pip, no venv, no wheels.

---

## Retention — three layers, all automatic

Retention is never manual, on any machine.

**1. Immediate.** Changing retention in the app drops out-of-window partitions on
apply, not on the next timer. `DROP TABLE` returns disk instantly, unlike `DELETE`,
which leaves dead rows and grows the database before it shrinks.

**2. Daily.** A systemd timer creates partitions **seven days ahead** and drops
expired ones. `Persistent=true`, so a run missed during downtime executes at next
boot — a skipped run would leave a day with no partition and every insert would fail.

**3. Emergency.** A watchdog every five minutes:

| Free disk | Action |
|---|---|
| < 15% | drop oldest partition, notify |
| < 10% | drop again |
| < 8% | **pause collection**, alert |

Time-based retention cannot stop a sudden log flood. The agent must never be the
thing that fills your disk — it degrades, then stops.

Every automatic drop is reported through your alert channels. Nothing is silent.

---

## Log parsing

Real-world logs are rarely JSON. The parser handles the formats actually found in
production:

```
[2026-08-09 03:07:24.603] http: GET /v1/x (8 ms) 200      bracketed, no zone
[2026-08-09 23:17:31.198 +0530] INFO: Request completed   with offset
    requestId: "abc"                                       ← 4-space continuation
WARNING:  Invalid HTTP request received.                   no timestamp
2026-08-09 17:37:25.250 UTC [867970] FATAL:  ...           postgres
```

- **Multiline** — a record starts at column 0; indented lines belong to the record above
- **Timestamps** — three shapes, falling back to ingest time rather than dropping the line
- **Severity** — level words, then emoji (`⚠️` → WARN, `❌`/`🔴` → ERROR), then HTTP
  status (`≥500` ERROR, `≥400` WARN)
- **stderr is *not* mapped to ERROR.** In practice PM2 error logs are full of
  warnings; that mapping manufactures thousands of false errors and makes alerting
  useless on the first day.

### Redaction

Secrets are stripped **before the write**, never after:

| Pattern | Becomes |
|---|---|
| `password=` / `secret=` / `api_key=` / `token=` | `***` |
| `Bearer <token>` | `Bearer ***` |
| JWTs (`eyJ…`) | `***` |
| AWS keys (`AKIA…`) | `***` |
| `postgres://user:pass@host` | `postgres://user:***@host` |

This store is queried from a phone. A credential must never reach the database at all.

---

## Usage

```bash
logagent status                                     # JSON: config, discovery, stats
logagent set --json '{"days":7}'                    # retention — applies immediately
logagent set --json '{"logServices":["api","web"]}' # choose services
logagent set --json '{"sources":{"nginx":"errors"}}'
logagent set --json '{"sources":{"docker":false}}' --purge
logagent pause                                      # stop collecting, keep data
logagent resume
logagent notify "test message"                      # verify alert channels
logagent uninstall --yes                            # removes everything, credentials included

logagent alerts list                                # rules, thresholds, what is firing
logagent alerts firing                              # currently firing, with since-time
logagent alerts coverage                            # which rules apply to which service
logagent alerts events 50                           # alert history
logagent alerts set 1 '{"threshold":50}'            # tune a rule
logagent alerts silence 3 120                       # mute rule 3 for 120 minutes

logagent errors list                                # errors grouped by fingerprint
logagent errors state <fp> ignored                  # triage: open | ignored | resolved

logagent probe                                      # run DB + certificate probes now
logagent rollup                                     # recompute rollups now
```

`alerts coverage` exists because coverage is uneven and that must be visible: metric
rules (crash loop, service down, unhealthy, disk, CPU, memory, certificates) apply to
**every** discovered service, while log rules (error rate, p95 latency) only apply to
services with logging enabled. A half-monitored service must never read as fully
covered.

Marking an error group `ignored` also stops it feeding the error-rate alert — otherwise
the ignore button would be a lie.

Metrics are collected for **every** service regardless of log selection — roughly
5 MB/day for fifty services. An unselected service still needs a graph when it
becomes suspicious.

Full reference: [docs/configuration.md](docs/configuration.md).

---

## Requirements

- Linux with systemd
- Docker (the logs database runs as a container)
- Python 3.6+ (standard library only)
- ≥ 3 GB free disk — the installer **refuses** below this
- ~250 MB RAM

Optional: PM2, nginx.

Ports are probed, not assumed. `5432`–`5434` are commonly taken by application
databases, so the logs database starts at `5499` and walks upward until it finds a
free port. Override with `--port`.

---

## Install paths

**Remote, from the app** — the agent is pushed over SSH and executed. No public
mirror needed, and the agent version always matches the app version.

**Manual, one-liner** — for a machine set up outside the app:

```bash
curl -fsSL https://raw.githubusercontent.com/skgnandy/ai-terminal-logs/main/install.sh | sudo bash
```

Both are idempotent. Re-running on a configured machine reuses the existing ports,
keeps the database, and reapplies configuration.

Pre-flight also reclaims disk before installing anything: caps journald
(uncapped by default, routinely several GB) and installs `pm2-logrotate`. It
**rotates rather than flushes**, so history nothing has collected yet is not destroyed.

---

## Documentation

| | |
|---|---|
| [docs/architecture.md](docs/architecture.md) | components, data flow, schema, design rationale |
| [docs/configuration.md](docs/configuration.md) | every option, the JSON contract, alert channels |
| [docs/operations.md](docs/operations.md) | day-two ops, sizing, troubleshooting, upgrade, uninstall |
| [docs/security.md](docs/security.md) | credential handling, network exposure, redaction, threat model |

---

## Status

Version 1.0.0. Field-tested against PM2, Docker (Postgres/Mongo/Redis), systemd and
nginx on Debian and Ubuntu.

Not implemented: distributed tracing, Kubernetes, OTLP network ingest, clustering.
See [docs/architecture.md](docs/architecture.md#limits) for when to outgrow this.

## License

MIT — see [LICENSE](LICENSE).
