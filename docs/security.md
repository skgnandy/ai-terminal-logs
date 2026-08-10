# Security

## Threat model

The agent runs as root on a machine you already control. It does not widen the
attack surface of that machine, and it is designed so that compromising the host
does not extend to your other systems.

Three properties are enforced deliberately:

1. **Nothing new is exposed to the network.** The logs database binds to
   `127.0.0.1` only.
2. **Secrets never reach the database.** Redaction runs before the write, not after.
3. **Credentials on the machine are minimal.** The Firebase credential can send
   notifications and nothing else.

---

## Network exposure

The logs database is published as `127.0.0.1:<port>:5432`. It is not reachable from
outside the host, and no firewall rule is required to keep it that way.

The app reaches it through an SSH tunnel it already maintains — the same
authentication you already use for the machine. There is no second credential to
manage and no additional listening port.

The receiver binds to `127.0.0.1` as well. `/health` exposes queue depth and
counters, no log content.

---

## Redaction

Applied in the Vector `remap` transform — **before** anything is written. This store
is queried from a phone and kept for days; a credential must never reach the
database in the first place, because after that it exists in a second place and in
every backup of it.

| Pattern | Result |
|---|---|
| `password=` / `passwd=` / `pwd=` / `secret=` / `api_key=` / `token=` / `authorization=` | `***` |
| `Bearer <token>` | `Bearer ***` |
| JWTs (`eyJ….….…`) | `***` |
| AWS access keys (`AKIA…`) | `***` |
| Credentials in URLs (`scheme://user:pass@host`) | `scheme://user:***@host` |

Redaction is best-effort pattern matching. It will not catch a secret logged in an
unusual shape. The durable fix is not logging secrets; this is a safety net, not a
guarantee.

Verify against your own logs after install:

```sql
SELECT body FROM log_entries
WHERE body ~* '(password|secret|token|bearer|AKIA|eyJ)'
ORDER BY ts DESC LIMIT 20;
```

Anything unredacted there is a pattern worth adding.

---

## Credentials on the machine

| File | Mode | Contents | Blast radius if host is compromised |
|---|---|---|---|
| `/etc/ai-terminal/pgpass` | 0600 | logs database password | the logs database only — loopback-bound, no production data |
| `/etc/ai-terminal/fcm.json` | 0600 | messaging-only service account | can send push notifications; **cannot read Firestore or Auth** |
| `/etc/ai-terminal/channels.json` | 0600 | Telegram bot token, SMTP password | can send messages as that bot / mailbox |

All are root-only, and all are removed unconditionally by
`logagent uninstall --yes`.

### Firebase

The credential is deliberately **not** a full Admin SDK key. Create a service
account with `roles/firebasemessaging.admin` and nothing else.

A full Admin SDK credential on a production server would grant read and write access
to your entire Firestore. A messaging-only account grants the ability to send
notifications. That difference is the whole point.

**Device tokens are pushed to the machine by the app over SSH.** The agent never
reads Firebase for anything. Send-only, zero read access — so there is no path from
this machine to your data.

### SMTP

Use a dedicated sending account or an app-specific password, never a primary mailbox
password. The credential sits on a server; if that server is compromised the blast
radius should be "can send mail as a bot", not "can read my inbox".

---

## Privilege

The installer requires root: it writes systemd units, manages Docker, and edits
`/etc/systemd/journald.conf`.

The receiver runs under systemd hardening:

```ini
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/ai-terminal /var/lib/ai-terminal
MemoryMax=256M
```

`MemoryMax` is a safety property, not a tuning knob — the agent must never OOM the
machine it is monitoring.

Vector needs read access to the Docker socket, which is equivalent to root on the
host. That is inherent to reading container logs without changing Docker's log
driver; the alternative forces a restart of every running container.

---

## Access control in the app

The agent has no authentication of its own. Anyone who can SSH to the machine as
root can run `logagent`. Access control belongs to the layer that holds the SSH
session.

Destructive operations must be gated to owners:

- `logagent set --purge`
- any retention **decrease** (deletes partitions immediately, irreversibly)
- `logagent pause`
- `logagent uninstall`

Note that the database path is a **separate code path** from shell execution. An app
that guards `readOnly` sessions at the shell layer does not automatically guard a
tunnelled Postgres connection — that needs its own check, or a read-only session can
run arbitrary SQL against the logs database.

---

## What is not protected

- **Log content is not encrypted at rest.** Anyone with root on the machine can read
  it — as they could read the original log files.
- **Redaction is pattern-based**, not semantic.
- **No audit trail of reads.** Maintenance actions are recorded in
  `maintenance_log`; queries are not.
- **No authentication between app and agent** beyond SSH.

---

## Reporting

Open an issue at
<https://github.com/skgnandy/ai-terminal-logs/issues>. For anything sensitive,
please report privately rather than in a public issue.
