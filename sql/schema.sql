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
