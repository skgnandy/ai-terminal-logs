# Operations

## Sizing

Measure before choosing retention. Estimates from file sizes are misleading —
a long-lived log file counts in full even though it took weeks to grow.

```bash
# actual daily growth, measured over 10 minutes
A=$(du -sb /root/.pm2/logs | cut -f1); sleep 600
B=$(du -sb /root/.pm2/logs | cut -f1)
echo "PM2: $(( (B-A)*144/1048576 )) MB/day"

journalctl --since "1 hour ago" | wc -c \
  | awk '{printf "journal: %.0f MB/day\n", $1*24/1048576}'
```

Rough guide, excluding nginx access logs:

| Daily volume | 3 days | 7 days | 14 days |
|---|---|---|---|
| 50 MB | 0.2 GB | 0.4 GB | 0.8 GB |
| 200 MB | 0.7 GB | 1.5 GB | 3 GB |
| 1 GB | 3.5 GB | 8 GB | 16 GB |

Postgres compresses text roughly 2–3×, so stored size is below raw volume.

**nginx `full` is usually 10–20× everything else combined.** Use `errors`, which
keeps every 4xx/5xx and drops successful static-asset noise that has no debug value.

Retention is per machine. A host with 40 GB free and one with 8 GB free should not
share a number.

---

## Day-two checks

```bash
logagent status | python3 -m json.tool     # config, health, stats
systemctl status vector ai-terminal-receiver
systemctl list-timers 'ai-terminal-*'
curl -s localhost:9080/health              # receiver queue and counters
```

`health.clockSynced` is worth watching. Cross-machine timelines break silently
under clock skew — the data looks correct and is wrong.

---

## Verifying ingestion

```bash
docker exec -it ai-terminal-logs psql -U logagent -d logs

-- rows per service in the last hour
SELECT service, kind, count(*)
FROM log_entries WHERE ts > now() - interval '1 hour'
GROUP BY 1,2 ORDER BY 3 DESC;

-- partitions and their sizes
SELECT c.relname, pg_size_pretty(pg_total_relation_size(c.oid))
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
JOIN pg_class p ON p.oid = i.inhparent
WHERE p.relname = 'log_entries' ORDER BY 1;

-- confirm multiline joining works: a stack trace should be ONE row
SELECT ts, service, left(body, 120)
FROM log_entries WHERE body LIKE '%Error%' ORDER BY ts DESC LIMIT 5;
```

Multiline is the check most worth doing after install. If a 30-line stack trace
appears as 30 rows, error grouping is broken and the parse config needs adjusting
for that service's format.

---

## Troubleshooting

### No rows appearing

```bash
logagent status | grep -E 'paused|logServices'
```

The agent installs **paused** with an empty allowlist. That is the usual answer.

```bash
journalctl -u vector -n 50
journalctl -u ai-terminal-receiver -n 50
vector validate --config /etc/vector/vector.toml
```

### Rows appear with the wrong service name

PM2 service names come from the filename with `-out`/`-error` stripped. Docker names
come from the container. If names look wrong, check what was detected:

```bash
grep PM2_LOG_DIRS_CSV /etc/ai-terminal/env
docker ps --format '{{.Names}}'
```

### Everything is severity INFO

The parser derives severity from level words, then emoji, then HTTP status codes.
An app logging none of those has nothing to derive from.

**Note that PM2 stderr is deliberately not mapped to ERROR.** In practice PM2 error
logs are full of warnings; that mapping manufactures thousands of false errors and
makes alerting worthless on the first day. Fix it at the source — have the app emit
a level word.

### Timestamps are wrong

Logs with no UTC offset are interpreted using the machine timezone from
`/etc/ai-terminal/env`. Check `TZ_NAME` matches reality, and that NTP is synced.

### Disk filling despite retention

The watchdog should prevent this. Confirm it runs:

```bash
systemctl list-timers ai-terminal-watchdog.timer
docker exec -i ai-terminal-logs psql -U logagent -d logs \
  -c "SELECT * FROM maintenance_log ORDER BY ts DESC LIMIT 20;"
```

Every automatic drop is recorded there. If drops are frequent, retention is set too
high for the volume.

### Receiver returning 503

The queue is full — Postgres is slower than ingest. Vector buffers to disk and
retries, so nothing is lost immediately, but sustained 503s mean either too many
services are selected or the database is starved.

---

## Emergency behaviour

| Free disk | Action |
|---|---|
| < 15% | drop oldest partition, notify |
| < 10% | drop two |
| < 8% | **pause collection**, alert |

Time-based retention cannot stop a sudden log flood, so this is the backstop. The
agent degrades — shedding old data, then stopping — rather than taking the machine
down. Every action is recorded in `maintenance_log` and sent to your alert channels.

To resume after a pause, free disk and:

```bash
logagent resume
```

---

## Upgrading

```bash
curl -fsSL https://raw.githubusercontent.com/skgnandy/ai-terminal-logs/main/install.sh | sudo bash
```

Idempotent. Reuses existing ports, keeps the database and its data, preserves
`logagent.conf` and `channels.json`, and reapplies schema migrations.

The payload swap is atomic: a failed download never leaves a half-written agent.

---

## Uninstalling

```bash
logagent uninstall --yes
```

Removes the container and its volume, systemd units, Vector config, `/opt` payload,
state directory, the CLI — **and all credentials** (`fcm.json`, `channels.json`,
`pgpass`). Leaving credentials behind is the worst possible outcome of an uninstall,
so that step is unconditional.

Reports bytes freed. It does **not** revert the journald cap or remove
`pm2-logrotate` — both are improvements worth keeping.

---

## What this does not do

- No distributed traces, latency percentiles, or dependency map
- No network OTLP ingest — local sources only
- No clustering; one agent per machine, the app merges across machines
- No log search index beyond `ILIKE`

See [architecture.md](architecture.md#limits) for when to outgrow it.
