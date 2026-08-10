#!/usr/bin/env bash
#
# Pre-aggregation. Runs every 5 minutes.
#
# Two outputs, both of which exist so the UI never scans raw logs:
#
#   log_rollup    5-minute buckets per service — counts plus latency percentiles.
#                 One query fills a 51-service grid with sparklines; without this
#                 the dashboard would run 51 scans over millions of rows.
#
#   error_groups  errors collapsed by fingerprint. Variable parts (ids, numbers,
#                 hex, quoted strings) are normalised away, so 1,204 error lines
#                 become the three real problems behind them.
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
FROM (
  SELECT ts, host, service, severity,
         CASE WHEN attrs->>'duration_ms' ~ '^[0-9]+(\.[0-9]+)?$'
              THEN (attrs->>'duration_ms')::double precision END AS dur
  FROM log_entries
  WHERE ts > now() - interval '15 minutes'
) e
GROUP BY 1, 2, 3
ON CONFLICT (bucket, host, service) DO UPDATE SET
  errors = EXCLUDED.errors,
  warns  = EXCLUDED.warns,
  total  = EXCLUDED.total,
  p50_ms = EXCLUDED.p50_ms,
  p95_ms = EXCLUDED.p95_ms,
  p99_ms = EXCLUDED.p99_ms,
  max_ms = EXCLUDED.max_ms;
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
pgq -c "DELETE FROM error_groups WHERE last_seen < now() - interval '90 days';" >/dev/null 2>&1 || true

# db_metrics is a plain table rather than partitioned (a few dozen rows per 10
# minutes), so it is pruned here instead of by partition maintenance.
pgq -c "DELETE FROM db_metrics    WHERE ts < now() - interval '30 days';" >/dev/null 2>&1 || true
pgq -c "DELETE FROM alert_events  WHERE ts < now() - interval '90 days';" >/dev/null 2>&1 || true
