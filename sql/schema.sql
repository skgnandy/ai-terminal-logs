-- ai-terminal-logs schema
--
-- Two design choices dominate this file:
--
--   PARTITION BY RANGE (ts) — retention is DROP TABLE, which returns disk
--   instantly. DELETE would leave dead rows and grow the database before it
--   shrinks, which is exactly wrong on a host that is already short on space.
--
--   UNLOGGED partitions — skips WAL. Losing recent logs on an unclean crash is
--   acceptable; doubling write cost and WAL volume on a small VPS is not.
--
-- Field names follow OpenTelemetry conventions (service.name, severity_text,
-- body, trace_id) so migrating to ClickHouse later is a data copy rather than a
-- rewrite of the agent, the queries and the app.

CREATE TABLE IF NOT EXISTS schema_version (
  version    int PRIMARY KEY,
  applied_at timestamptz DEFAULT now()
);

-- ── logs ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS log_entries (
  id       bigint      NOT NULL,   -- per-batch sequence; enables keyset paging
  ts       timestamptz NOT NULL,
  host     text        NOT NULL,
  service  text        NOT NULL,
  kind     text        NOT NULL,   -- pm2 | docker | systemd | nginx
  severity text,                   -- FATAL | ERROR | WARN | INFO | DEBUG
  body     text        NOT NULL,
  attrs    jsonb,
  fp       bytea,                  -- content hash; absorbs at-least-once retries
  trace_id text,                   -- reserved
  span_id  text                    -- reserved
) PARTITION BY RANGE (ts);

-- BRIN, not B-tree: for append-only time-ordered rows BRIN costs kilobytes where
-- a B-tree costs gigabytes, and range scans are what this table exists for.
CREATE INDEX IF NOT EXISTS log_entries_ts_brin   ON log_entries USING BRIN (ts);
CREATE INDEX IF NOT EXISTS log_entries_svc_ts    ON log_entries (service, ts DESC);
CREATE INDEX IF NOT EXISTS log_entries_sev_ts    ON log_entries (severity, ts DESC)
  WHERE severity IN ('ERROR', 'FATAL', 'WARN');

-- Pagination MUST be keyset, never OFFSET: rows arrive continuously, so offset
-- paging skips and repeats lines as new data lands above the window.
--   WHERE (ts, id) < ($lastTs, $lastId) ORDER BY ts DESC, id DESC LIMIT 200

-- ── metrics ─────────────────────────────────────────────────────────────────
-- Collected for EVERY service regardless of log selection (~5 MB/day for 50
-- services). An unselected service still needs a graph when it turns suspicious.
CREATE TABLE IF NOT EXISTS metrics (
  ts        timestamptz NOT NULL,
  host      text NOT NULL,
  service   text NOT NULL,
  kind      text NOT NULL,
  cpu       real,
  mem_bytes bigint,
  restarts  int,
  status    text
) PARTITION BY RANGE (ts);

CREATE INDEX IF NOT EXISTS metrics_svc_ts ON metrics (service, ts DESC);

CREATE TABLE IF NOT EXISTS host_metrics (
  ts         timestamptz NOT NULL,
  host       text NOT NULL,
  cpu        real,
  load1      real,
  mem_used   bigint,
  mem_total  bigint,
  disk_used  bigint,
  disk_total bigint
) PARTITION BY RANGE (ts);

-- ── alerting ────────────────────────────────────────────────────────────────
-- Rules always group by service; they never enumerate services. A service
-- deployed tomorrow inherits every rule the moment its first row lands.
CREATE TABLE IF NOT EXISTS alert_rules (
  id          serial PRIMARY KEY,
  name        text NOT NULL,
  kind        text NOT NULL,   -- error_rate | crash_loop | service_down | unhealthy | disk | cpu
  target      jsonb NOT NULL DEFAULT '{"service":"*"}',
  threshold   real,
  window_secs int DEFAULT 300,
  channels    text[] DEFAULT '{}',
  enabled     bool DEFAULT true,
  silenced_until timestamptz
);

CREATE TABLE IF NOT EXISTS alert_events (
  id      serial PRIMARY KEY,
  ts      timestamptz DEFAULT now(),
  rule_id int REFERENCES alert_rules(id) ON DELETE CASCADE,
  service text,
  host    text,
  value   real,
  state   text            -- firing | resolved
);

CREATE INDEX IF NOT EXISTS alert_events_ts ON alert_events (ts DESC);

-- Firing/resolved state, so a crash loop sends one alert and one recovery
-- rather than one per evaluation cycle.
CREATE TABLE IF NOT EXISTS alert_state (
  rule_id    int,
  service    text,
  state      text,
  since      timestamptz DEFAULT now(),
  notified_at timestamptz,
  PRIMARY KEY (rule_id, service)
);

-- ── maintenance ─────────────────────────────────────────────────────────────
-- Every automatic drop is recorded. Data disappearing silently is unacceptable;
-- the app reads this to explain gaps.
CREATE TABLE IF NOT EXISTS maintenance_log (
  ts     timestamptz DEFAULT now(),
  action text,          -- drop_partition | emergency_drop | paused | resumed | purge
  detail text
);

CREATE INDEX IF NOT EXISTS maintenance_log_ts ON maintenance_log (ts DESC);

-- ── default alert rules ─────────────────────────────────────────────────────
INSERT INTO alert_rules (name, kind, threshold, window_secs)
SELECT * FROM (VALUES
  ('Error spike',         'error_rate',   20, 300),
  ('Crash loop',          'crash_loop',    5, 600),
  ('Service down',        'service_down',  1,  60),
  ('Container unhealthy', 'unhealthy',     1, 300),
  ('Disk pressure',       'disk',         85, 300),
  ('CPU sustained',       'cpu',          90, 900)
) AS v(name, kind, threshold, window_secs)
WHERE NOT EXISTS (SELECT 1 FROM alert_rules);

INSERT INTO schema_version (version) VALUES (1) ON CONFLICT DO NOTHING;

-- ══════════════════════════════════════════════════════════════════════════
-- schema v2 — rollups, error grouping, database internals, certificates
-- ══════════════════════════════════════════════════════════════════════════

-- ── rollup ──────────────────────────────────────────────────────────────────
-- Pre-aggregated 5-minute buckets. Every dashboard card and sparkline reads
-- this, never raw logs: one small query fills a 51-service grid instead of 51
-- scans over millions of rows.
--
-- Latency percentiles come from attrs.duration_ms, which the parser extracts
-- from HTTP access lines. That yields p50/p95/p99 per service WITHOUT traces —
-- "this endpoint got slow at 14:32" is answerable; "because Postgres took 4.1s"
-- still needs spans.
CREATE TABLE IF NOT EXISTS log_rollup (
  bucket   timestamptz NOT NULL,
  host     text NOT NULL,
  service  text NOT NULL,
  errors   int  DEFAULT 0,
  warns    int  DEFAULT 0,
  total    int  DEFAULT 0,
  p50_ms   real,
  p95_ms   real,
  p99_ms   real,
  max_ms   real,
  PRIMARY KEY (bucket, host, service)
);

CREATE INDEX IF NOT EXISTS log_rollup_svc ON log_rollup (service, bucket DESC);

-- ── error grouping / exceptions triage ──────────────────────────────────────
-- Variable parts (ids, numbers, hex) are normalised away so 1,204 error lines
-- collapse into the three real problems behind them. `state` gives Sentry-style
-- triage: an ignored group stops contributing to alerts.
CREATE TABLE IF NOT EXISTS error_groups (
  fp          text PRIMARY KEY,
  host        text NOT NULL,
  service     text NOT NULL,
  severity    text,
  sample      text NOT NULL,
  first_seen  timestamptz NOT NULL,
  last_seen   timestamptz NOT NULL,
  occurrences bigint DEFAULT 0,
  state       text DEFAULT 'open'   -- open | ignored | resolved
);

CREATE INDEX IF NOT EXISTS error_groups_svc  ON error_groups (service, last_seen DESC);
CREATE INDEX IF NOT EXISTS error_groups_open ON error_groups (state, last_seen DESC);

-- ── database internals ──────────────────────────────────────────────────────
-- SigNoz needs a separate exporter per engine. The app already holds working
-- drivers, so these are collected directly: connections, slow queries, cache hit
-- rate, evictions, replication lag.
--
-- Deliberately NOT partitioned, unlike the other time-series tables. It takes a
-- few dozen rows every 10 minutes, so a plain table plus a periodic DELETE is
-- the right trade. Partitioning it would also add it to partition maintenance,
-- and a table whose partition is missing rejects every insert.
CREATE TABLE IF NOT EXISTS db_metrics (
  ts      timestamptz NOT NULL DEFAULT now(),
  host    text NOT NULL,
  service text NOT NULL,
  engine  text NOT NULL,        -- postgres | redis | mongo
  metric  text NOT NULL,
  value   double precision,
  detail  text
);

CREATE INDEX IF NOT EXISTS db_metrics_svc ON db_metrics (service, metric, ts DESC);

-- ── TLS certificates ────────────────────────────────────────────────────────
-- Nobody watches certificate expiry until a site breaks. Cheap to collect,
-- and the alert rule below fires two weeks out.
CREATE TABLE IF NOT EXISTS cert_expiry (
  domain     text PRIMARY KEY,
  host       text NOT NULL,
  not_after  timestamptz,
  days_left  int,
  issuer     text,
  checked_at timestamptz DEFAULT now(),
  error      text
);

-- ── v2 alert rules ──────────────────────────────────────────────────────────
INSERT INTO alert_rules (name, kind, threshold, window_secs)
SELECT * FROM (VALUES
  ('Certificate expiry', 'cert_expiry', 14,  86400),
  ('Latency p95',        'latency_p95', 2000,  900),
  ('Memory sustained',   'memory',        90,  900)
) AS v(name, kind, threshold, window_secs)
WHERE NOT EXISTS (SELECT 1 FROM alert_rules WHERE kind = 'cert_expiry');

INSERT INTO schema_version (version) VALUES (2) ON CONFLICT DO NOTHING;

-- ══════════════════════════════════════════════════════════════════════════
-- schema v3 — request pairing
--
-- Latency for services that log two lines per request ("Incoming request",
-- "Request completed") sharing an id, and no duration anywhere. The rollup
-- joins the pair on that id; without this index the join scans every partition
-- once per five-minute run, which on a busy machine costs more than the rollup
-- it serves.
--
-- Partial: only a request line carries req_id, and those are a small slice of a
-- log. Indexing the rest would triple the index for rows it can never match.
CREATE INDEX IF NOT EXISTS log_entries_reqid
  ON log_entries ((attrs->>'req_id'))
  WHERE attrs ? 'req_id';

INSERT INTO schema_version (version) VALUES (3) ON CONFLICT DO NOTHING;

-- ══════════════════════════════════════════════════════════════════════════
-- schema v4 — key operations
--
-- Per-endpoint aggregates, so the app can answer "which route is slow, which
-- route is failing" without scanning raw logs. Same reasoning as log_rollup:
-- one small query fills the whole table instead of one scan per endpoint.
--
-- Keyed on the NORMALISED route (/leads/:id, not /leads/8f2c…), which the
-- parser writes. Without that collapse a table of "top endpoints" is a list of
-- individual requests and every row has one call.
--
-- method is NOT NULL with a '' fallback rather than nullable: it is part of the
-- primary key, and a NULL there makes ON CONFLICT never match, so every rollup
-- run would insert a duplicate row instead of updating the previous one.
CREATE TABLE IF NOT EXISTS endpoint_rollup (
  bucket   timestamptz NOT NULL,
  host     text NOT NULL,
  service  text NOT NULL,
  method   text NOT NULL DEFAULT '',
  route    text NOT NULL,
  calls    int  DEFAULT 0,
  errors   int  DEFAULT 0,   -- 5xx, or a line the parser judged ERROR/FATAL
  clienterr int DEFAULT 0,   -- 4xx: not an outage, but a broken caller
  p50_ms   real,
  p95_ms   real,
  p99_ms   real,
  max_ms   real,
  PRIMARY KEY (bucket, host, service, method, route)
);
CREATE INDEX IF NOT EXISTS endpoint_rollup_bucket ON endpoint_rollup (bucket DESC);
CREATE INDEX IF NOT EXISTS endpoint_rollup_svc    ON endpoint_rollup (service, bucket DESC);

INSERT INTO schema_version (version) VALUES (4) ON CONFLICT DO NOTHING;

-- ══════════════════════════════════════════════════════════════════════════
-- schema v5 — request rate, error rate and Apdex
--
-- log_rollup.total counts LOG LINES, which is not the request rate: a service
-- that logs four lines per request would report four times the traffic it
-- serves. `timed` counts requests — exactly the rows that produced a duration,
-- one per completed request — and is the correct denominator for both the rate
-- and the error rate.
--
-- req_errors is failures among REQUESTS, not error lines. One failing request
-- often logs a message, a stack trace and a summary; dividing that by requests
-- yields error rates above 100%, which is how an error-rate panel loses the
-- reader's trust permanently.
--
-- Apdex is stored as its two counts rather than as a score, because scores do
-- not average: combining five-minute buckets into an hour has to re-divide the
-- sums. T is 500 ms, the usual default for a web API, and 4T = 2 s. Baking T in
-- means changing it does not retroactively change history — the alternative is
-- keeping every raw duration, which is the thing these rollups exist to avoid.
ALTER TABLE log_rollup ADD COLUMN IF NOT EXISTS timed      int DEFAULT 0;
ALTER TABLE log_rollup ADD COLUMN IF NOT EXISTS req_errors int DEFAULT 0;
ALTER TABLE log_rollup ADD COLUMN IF NOT EXISTS apdex_s    int DEFAULT 0;
ALTER TABLE log_rollup ADD COLUMN IF NOT EXISTS apdex_t    int DEFAULT 0;

INSERT INTO schema_version (version) VALUES (5) ON CONFLICT DO NOTHING;
