# Configuration

All configuration lives on the machine. The app reads it on connect and writes it
on change, so the agent keeps working whether or not the app is running.

| File | Mode | Contents |
|---|---|---|
| `/etc/ai-terminal/logagent.conf` | 0600 | retention, sources, service selection |
| `/etc/ai-terminal/channels.json` | 0600 | FCM, Telegram, SMTP credentials |
| `/etc/ai-terminal/fcm.json` | 0600 | messaging-only service account |
| `/etc/ai-terminal/pgpass` | 0600 | generated database password |
| `/etc/ai-terminal/env` | 0600 | detected paths and ports |

---

## `logagent.conf`

```jsonc
{
  "paused": false,
  "days": 7,                       // retention, 1-30. null = unset (paused)
  "sources": {
    "pm2": true,
    "docker": true,
    "systemd": true,
    "nginx": "off",                // "off" | "errors" | "full"
    "redis": false
  },
  "logServices": [                 // explicit allowlist — nothing else is stored
    "atira-hrms-backend",
    "postgres17"
  ],
  "metricsAll": true               // metrics ignore the allowlist, always
}
```

`sources` toggles whole **collectors**. `logServices` is the real control: an
explicit allowlist of what gets stored. A newly discovered service appears in
`logagent status` as unselected — you opt it in, so nothing starts consuming disk
behind your back.

---

## `logagent status`

```jsonc
{
  "installed": true,
  "version": "1.0.0",
  "schemaVersion": 1,
  "paused": false,
  "days": 7,
  "timezone": "Asia/Kolkata",
  "dbPort": 5499,
  "sources": { "pm2": true, "docker": true, "systemd": true, "nginx": "off" },
  "logServices": ["api"],
  "metricsAll": true,

  "discovered": [
    { "name": "api",        "kind": "pm2",    "status": "online",  "restarts": 2, "enabled": true },
    { "name": "postgres17", "kind": "docker", "status": "running", "enabled": false }
  ],

  "health": {
    "database": true,
    "vector": true,
    "receiver": true,
    "partitionTimer": true,
    "clockSynced": true
  },

  "maintenance": {
    "lastCleanup": "2026-08-10 00:10:04+00",
    "partitionsThrough": "log_entries_2026_08_17",
    "recent": ["2026-08-10 00:10:04 drop_partition log_entries_2026_08_02"]
  },

  "stats": {
    "rows": 4210000,
    "dbBytes": 912000000,
    "oldestRow": "2026-08-03 00:00:11+00",
    "newestRow": "2026-08-10 14:47:02+00",
    "freeDisk": 8300000000,
    "totalDisk": 77000000000
  }
}
```

`discovered` enumerates everything the machine *could* collect, so a UI can render
a checkbox list of real services rather than a text field where names are typed.

`health` drives degraded states — each false value has one obvious remedy.
`clockSynced` matters because cross-machine timelines silently break under skew.

---

## `logagent set`

Merges a patch. `sources` merges key-by-key; everything else replaces.

```bash
logagent set --json '{"days":3}'
logagent set --json '{"logServices":["api","worker","postgres17"]}'
logagent set --json '{"sources":{"nginx":"errors"}}'
logagent set --json '{"sources":{"docker":false}}' --purge
```

Setting both `days` and `logServices` un-pauses the agent automatically.

### Retention semantics

**Lowering deletes immediately and permanently.** Going 7 → 3 drops four partitions
on apply — not on the next timer. Disk is returned at once. There is no undo, so a
UI must confirm, showing rows and bytes.

**Raising applies forward only.** Days already dropped do not return; you begin
accumulating toward the new window from today.

### Turning a source off

Default behaviour is **stop collecting** — existing rows remain and age out
normally. `--purge` additionally deletes them, which is irreversible and should be
confirmed separately.

---

## Alert channels

```bash
logagent channels --json '{
  "telegram": { "token": "123456:ABC…", "chatId": "987654321" }
}'

logagent channels --json '{
  "smtp": {
    "host": "smtp.example.com", "port": 587,
    "user": "alerts@example.com", "password": "app-specific-password",
    "from": "alerts@example.com", "to": ["me@example.com"]
  }
}'

logagent channels --json '{ "fcm": { "tokens": ["device-token-1"] } }'

logagent notify "test message"        # verify every channel
```

### FCM

The primary channel, because it is the only one that can **deep-link**: tapping the
notification opens the service detail screen at the moment the alert fired.

Sent **directly from the machine** to the FCM HTTP v1 API — no Cloud Function, and
therefore no Blaze plan.

Two deliberate constraints:

- The credential at `/etc/ai-terminal/fcm.json` is a **messaging-only service
  account** (`roles/firebasemessaging.admin`, nothing else). It cannot read
  Firestore or touch Auth. A compromised host can send notifications; it cannot
  read your data.
- **Device tokens are pushed in by the app over SSH.** The agent never reads
  Firebase. Send-only, zero read access.

Tokens rotate. A token returning 400/404 is dropped automatically and the app
repairs the list on its next connect.

### Choosing channels per rule

| Channel | Best for |
|---|---|
| FCM | urgent — crash loop, service down, disk full. Deep-links |
| Telegram | same alerts on desktop; FCM fallback |
| SMTP | digests and anything needing a record |

---

## Alert rules

Six ship by default. Every rule groups **by service** and never enumerates them, so
a service deployed tomorrow inherits all of them the moment its first row lands.

| Rule | Kind | Default |
|---|---|---|
| Error spike | `error_rate` | > 20 errors / 5 min |
| Crash loop | `crash_loop` | restart delta > 5 / 10 min |
| Service down | `service_down` | status ≠ online |
| Container unhealthy | `unhealthy` | health ≠ healthy |
| Disk pressure | `disk` | > 85% used |
| CPU sustained | `cpu` | > 90% for 15 min |

### Coverage is not uniform

Metric rules (crash loop, service down, unhealthy, disk, CPU) cover **every**
service, because metrics ignore the allowlist.

Log rules (error spike) only cover services in `logServices`.

A service with logging disabled is therefore **half-monitored**. A UI must say so
explicitly — otherwise partial coverage reads as full coverage.

---

## Ports

Probed, never assumed. `5432`–`5434` are commonly taken by application databases,
so the logs database starts at **5499** and walks upward until it finds a free port,
checking both host listeners and Docker published ports.

```bash
curl -fsSL …/install.sh | sudo bash -s -- --port 5599
```

Re-running the installer **reuses the port already recorded** in `/etc/ai-terminal/env`,
so a reinstall never silently moves the endpoint the app is connected to.

---

## Environment reference

| Variable | Meaning |
|---|---|
| `PG_CONTAINER` | `ai-terminal-logs` |
| `PG_PORT` | chosen loopback port |
| `RECEIVER_PORT` | chosen receiver port |
| `HOST_NAME` | stamped into every row |
| `TZ_NAME` | used for logs without a UTC offset |
| `HAS_JOURNAL` | whether journald is available |
| `NGINX_LOG_DIR` | detected nginx log directory |
| `PM2_LOG_DIRS_CSV` | detected PM2 log globs |
