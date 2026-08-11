#!/usr/bin/env bash
#
# Pre-aggregation. Runs every 5 minutes.
#
# Three outputs, all of which exist so the UI never scans raw logs:
#
#   log_rollup       5-minute buckets per service — counts plus latency
#                    percentiles. One query fills a 51-service grid with
#                    sparklines; without this the dashboard would run 51 scans
#                    over millions of rows.
#
#   endpoint_rollup  the same buckets split by method and route, which is what
#                    "which endpoint is slow / failing" is asked of.
#
#   error_groups     errors collapsed by fingerprint. Variable parts (ids,
#                    numbers, hex, quoted strings) are normalised away, so 1,204
#                    error lines become the three real problems behind them.
#
# Latency percentiles come from attrs.duration_ms, extracted by the parser from
# HTTP access lines. That gives p50/p95/p99 per service with no tracing at all.

set -euo pipefail
. /opt/ai-terminal-logs/lib/common.sh
load_env

# Recompute the last 15 minutes rather than only the newest bucket: late-arriving
# events (Vector disk buffer replay after a restart) would otherwise be lost from
# a bucket that had already been written.
pgx <<'SQL' >/dev/null
-- date_bin, not date_trunc + arithmetic: `numeric * interval` has no operator in
-- Postgres, so the obvious floor(minute/5) * interval '5 minutes' form fails.
--
-- The duration cast is guarded by a regex. attrs.duration_ms is written by the
-- parser, but one malformed value would abort the whole rollup transaction; a
-- CASE that yields NULL instead is ignored by percentile_cont and max.
--
-- One derivation, two tables. `resolved` is computed once and both inserts read
-- it, because the per-service and per-endpoint numbers must agree: two copies of
-- this pairing logic would drift, and a service whose p95 disagrees with the p95
-- of its own endpoints is worse than having neither.
--
-- The first INSERT sits in a data-modifying CTE. Postgres runs such a CTE
-- exactly once and to completion whether or not the outer query reads it, so
-- both writes happen in a single statement against a single snapshot.
WITH resolved AS (
  SELECT e.ts, e.host, e.service, e.severity,
         COALESCE(
           CASE WHEN e.attrs->>'duration_ms' ~ '^[0-9]+(\.[0-9]+)?$'
                THEN (e.attrs->>'duration_ms')::double precision END,
           paired.dur
         ) AS dur,
         -- Route and method may be on either line of a pair: many frameworks log
         -- the method and path when the request ARRIVES and only a status when it
         -- finishes. Taking the completion line's value first and falling back to
         -- its start line attributes the request to the right endpoint either way.
         COALESCE(e.attrs->>'route',  paired.route)  AS route,
         COALESCE(e.attrs->>'method', paired.method) AS method,
         CASE WHEN e.attrs->>'status' ~ '^[0-9]{3}$'
              THEN (e.attrs->>'status')::int END     AS status,
         e.attrs->>'phase'                           AS phase
  FROM log_entries e
  -- Latency from the PAIR of lines, for the many services that log
  -- "Incoming request" and "Request completed" with a shared id and no
  -- duration anywhere. The gap between the two IS the duration, so those
  -- services get percentiles without a single change to their application.
  --
  -- LEFT JOIN LATERAL rather than joining two CTEs: it runs only for rows that
  -- end a request, and stops at the first match.
  LEFT JOIN LATERAL (
    SELECT extract(epoch FROM (e.ts - s.ts)) * 1000 AS dur,
           s.attrs->>'route'  AS route,
           s.attrs->>'method' AS method
    FROM log_entries s
    WHERE e.attrs->>'phase' = 'end'
      AND s.attrs->>'phase' = 'start'
      AND s.attrs->>'req_id' = e.attrs->>'req_id'
      AND s.service = e.service
      -- Bounded both ways. With no upper bound a recycled request id from hours
      -- earlier would pair up and report a multi-hour "request"; with no lower
      -- bound the join would scan every partition.
      AND s.ts <= e.ts
      AND s.ts > e.ts - interval '5 minutes'
    ORDER BY s.ts DESC
    LIMIT 1
  ) paired ON true
  WHERE e.ts > now() - interval '15 minutes'
),
service_level AS (
  INSERT INTO log_rollup (bucket, host, service, errors, warns, total,
                          p50_ms, p95_ms, p99_ms, max_ms)
  SELECT
    date_bin('5 minutes', ts, timestamptz '2000-01-01') AS bucket,
    host,
    service,
    count(*) FILTER (WHERE severity IN ('ERROR','FATAL')),
    count(*) FILTER (WHERE severity = 'WARN'),
    count(*),
    percentile_cont(0.50) WITHIN GROUP (ORDER BY dur),
    percentile_cont(0.95) WITHIN GROUP (ORDER BY dur),
    percentile_cont(0.99) WITHIN GROUP (ORDER BY dur),
    max(dur)
  FROM resolved
  GROUP BY 1, 2, 3
  ON CONFLICT (bucket, host, service) DO UPDATE SET
    errors = EXCLUDED.errors,
    warns  = EXCLUDED.warns,
    total  = EXCLUDED.total,
    p50_ms = EXCLUDED.p50_ms,
    p95_ms = EXCLUDED.p95_ms,
    p99_ms = EXCLUDED.p99_ms,
    max_ms = EXCLUDED.max_ms
  RETURNING 1
)
INSERT INTO endpoint_rollup (bucket, host, service, method, route,
                             calls, errors, clienterr,
                             p50_ms, p95_ms, p99_ms, max_ms)
SELECT
  date_bin('5 minutes', ts, timestamptz '2000-01-01') AS bucket,
  host,
  service,
  COALESCE(method, ''),
  route,
  count(*),
  count(*) FILTER (WHERE status >= 500 OR severity IN ('ERROR','FATAL')),
  count(*) FILTER (WHERE status BETWEEN 400 AND 499),
  percentile_cont(0.50) WITHIN GROUP (ORDER BY dur),
  percentile_cont(0.95) WITHIN GROUP (ORDER BY dur),
  percentile_cont(0.99) WITHIN GROUP (ORDER BY dur),
  max(dur)
FROM resolved
WHERE route IS NOT NULL
  -- One row per request, not two. A paired service logs the route on arrival
  -- AND on completion; counting both doubles every call count and halves every
  -- error rate. The completion line is the one that knows the outcome, so
  -- arrivals are dropped — except where there is no pairing at all (a plain
  -- access log line, phase IS NULL), which is itself the whole request.
  AND COALESCE(phase, 'end') = 'end'
GROUP BY 1, 2, 3, 4, 5
ON CONFLICT (bucket, host, service, method, route) DO UPDATE SET
  calls     = EXCLUDED.calls,
  errors    = EXCLUDED.errors,
  clienterr = EXCLUDED.clienterr,
  p50_ms    = EXCLUDED.p50_ms,
  p95_ms    = EXCLUDED.p95_ms,
  p99_ms    = EXCLUDED.p99_ms,
  max_ms    = EXCLUDED.max_ms;
SQL

# Error grouping.
#
# Normalisation order matters: quoted strings and hex/uuid forms are replaced
# before bare digits, otherwise a uuid becomes a string of <n> tokens and two
# occurrences of the same error fingerprint differently.
#
# Only the first line of a multiline record is fingerprinted — a stack trace's
# frames are noise for grouping, and the full body is kept as the sample.
pgx <<'SQL' >/dev/null
WITH normalised AS (
  SELECT
    md5(
      service || '|' ||
      regexp_replace(
        regexp_replace(
          regexp_replace(
            regexp_replace(split_part(body, E'\n', 1),
              '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<uuid>', 'g'),
            '\m[0-9a-fA-F]{12,}\M', '<hex>', 'g'),
          '"[^"]*"', '<str>', 'g'),
        '\m\d+\M', '<n>', 'g')
    ) AS fp,
    host, service, severity,
    split_part(body, E'\n', 1) AS sample,
    ts
  FROM log_entries
  WHERE ts > now() - interval '15 minutes'
    AND severity IN ('ERROR','FATAL')
)
INSERT INTO error_groups (fp, host, service, severity, sample,
                          first_seen, last_seen, occurrences)
SELECT fp, min(host), min(service), min(severity),
       min(left(sample, 500)), min(ts), max(ts), count(*)
FROM normalised
GROUP BY fp
ON CONFLICT (fp) DO UPDATE SET
  last_seen   = GREATEST(error_groups.last_seen, EXCLUDED.last_seen),
  occurrences = error_groups.occurrences + EXCLUDED.occurrences,
  -- A group marked resolved that recurs must reopen, or regressions stay hidden.
  state       = CASE WHEN error_groups.state = 'resolved' THEN 'open'
                     ELSE error_groups.state END;
SQL

# Rollups are small (a few KB/day) so they outlive raw logs: retention can be 3
# days while the service graphs still show 30.
pgq -c "DELETE FROM log_rollup   WHERE bucket    < now() - interval '90 days';" >/dev/null 2>&1 || true
# Shorter than log_rollup on purpose: this table is one row per endpoint per
# bucket, so it is roughly (number of routes) times larger. 30 days still covers
# every "is this endpoint slower than it was last month" question.
pgq -c "DELETE FROM endpoint_rollup WHERE bucket  < now() - interval '30 days';" >/dev/null 2>&1 || true
pgq -c "DELETE FROM error_groups WHERE last_seen < now() - interval '90 days';" >/dev/null 2>&1 || true

# db_metrics is a plain table rather than partitioned (a few dozen rows per 10
# minutes), so it is pruned here instead of by partition maintenance.
pgq -c "DELETE FROM db_metrics    WHERE ts < now() - interval '30 days';" >/dev/null 2>&1 || true
pgq -c "DELETE FROM alert_events  WHERE ts < now() - interval '90 days';" >/dev/null 2>&1 || true
