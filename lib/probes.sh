#!/usr/bin/env bash
#
# Active probes. Runs every 10 minutes.
#
# Everything here is pulled rather than tailed — it is state a log line never
# reports. Two groups:
#
#   database internals   connections, slow queries, cache hit rate, evictions.
#                        A hosted tool needs a separate exporter per engine and a
#                        network path to each database. This runs on the machine
#                        with the sockets already there, so it needs neither.
#
#   TLS certificates     expiry per nginx server_name. Nobody watches this until
#                        a site breaks; the alert rule fires 14 days out.
#
# Failures are recorded, never fatal: a probe that cannot reach one database must
# not stop the others or fail the timer.

set -euo pipefail
. /opt/ai-terminal-logs/lib/common.sh
load_env

now_sql="now()"

record() {
  # record <service> <engine> <metric> <value> [detail]
  local svc="$1" eng="$2" met="$3" val="$4" det="${5:-}"
  [ -n "$val" ] || return 0
  pgq -c "INSERT INTO db_metrics (ts, host, service, engine, metric, value, detail)
          VALUES ($now_sql, '${HOST_NAME:-unknown}', '${svc//\'/\'\'}', '$eng', '$met',
                  nullif('${val//\'/}','')::double precision,
                  nullif('${det//\'/\'\'}',''));" >/dev/null 2>&1 || true
}

# ── Postgres ────────────────────────────────────────────────────────────────
# Any postgres container except our own logs database.
probe_postgres() {
  local c
  for c in $(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
             | awk -F'\t' '$2 ~ /postgres/ {print $1}'); do
    [ "$c" = "$PG_CONTAINER" ] && continue

    # Use the container's own superuser via peer auth on the unix socket, so no
    # credentials are needed and none are stored.
    local psql="docker exec -i $c psql -U postgres -qtAX -c"

    local conns idle longest size hit
    conns=$($psql   "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null | tr -d ' ')
    idle=$($psql    "SELECT count(*) FROM pg_stat_activity WHERE state='idle in transaction';" 2>/dev/null | tr -d ' ')
    longest=$($psql "SELECT coalesce(round(max(extract(epoch FROM now()-query_start))),0)
                     FROM pg_stat_activity WHERE state='active' AND query NOT LIKE '%pg_stat_activity%';" 2>/dev/null | tr -d ' ')
    size=$($psql    "SELECT sum(pg_database_size(datname)) FROM pg_database;" 2>/dev/null | tr -d ' ')
    hit=$($psql     "SELECT round(100.0*sum(blks_hit)/nullif(sum(blks_hit)+sum(blks_read),0),1)
                     FROM pg_stat_database;" 2>/dev/null | tr -d ' ')

    record "$c" postgres connections      "$conns"
    record "$c" postgres idle_in_txn      "$idle"
    record "$c" postgres longest_query_s  "$longest"
    record "$c" postgres size_bytes       "$size"
    record "$c" postgres cache_hit_pct    "$hit"

    # pg_stat_statements is an extension and usually absent; treat as optional.
    local slow
    slow=$($psql "SELECT round(max(mean_exec_time)) FROM pg_stat_statements;" 2>/dev/null | tr -d ' ')
    [ -n "$slow" ] && record "$c" postgres slowest_mean_ms "$slow"
  done
}

# ── Redis ───────────────────────────────────────────────────────────────────
probe_redis() {
  local c
  for c in $(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
             | awk -F'\t' '$2 ~ /redis/ {print $1}'); do
    local info
    info=$(docker exec -i "$c" redis-cli INFO 2>/dev/null | tr -d '\r') || continue
    [ -n "$info" ] || continue

    field() { echo "$info" | awk -F: -v k="$1" '$1==k{print $2}' | head -1; }

    local used peak evict hits misses clients blocked
    used=$(field used_memory)
    peak=$(field used_memory_peak)
    evict=$(field evicted_keys)
    hits=$(field keyspace_hits)
    misses=$(field keyspace_misses)
    clients=$(field connected_clients)
    blocked=$(field blocked_clients)

    record "$c" redis used_memory_bytes "$used"
    record "$c" redis peak_memory_bytes "$peak"
    record "$c" redis evicted_keys      "$evict"
    record "$c" redis connected_clients "$clients"
    record "$c" redis blocked_clients   "$blocked"

    # Hit rate is the number that explains a suddenly busy Redis.
    if [ -n "$hits" ] && [ -n "$misses" ] && [ $((hits + misses)) -gt 0 ]; then
      record "$c" redis hit_rate_pct "$(( 100 * hits / (hits + misses) ))"
    fi
  done
}

# ── Mongo ───────────────────────────────────────────────────────────────────
probe_mongo() {
  local c sh
  for c in $(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
             | awk -F'\t' '$2 ~ /mongo/ {print $1}'); do
    sh=mongosh
    docker exec -i "$c" which mongosh >/dev/null 2>&1 || sh=mongo
    docker exec -i "$c" which "$sh"   >/dev/null 2>&1 || continue

    local out
    out=$(docker exec -i "$c" "$sh" --quiet --eval '
      var s = db.serverStatus();
      print([s.connections.current,
             s.connections.available,
             s.opcounters.query + s.opcounters.insert + s.opcounters.update + s.opcounters.delete,
             (s.mem && s.mem.resident) || 0,
             db.currentOp({"secs_running":{"$gte":5},"active":true}).inprog.length
            ].join(" "));' 2>/dev/null | tail -1) || continue

    set -- $out
    [ $# -ge 5 ] || continue
    record "$c" mongo connections_current "$1"
    record "$c" mongo connections_avail   "$2"
    record "$c" mongo ops_total           "$3"
    record "$c" mongo resident_mb         "$4"
    record "$c" mongo slow_ops            "$5"
  done
}

# ── TLS certificates ────────────────────────────────────────────────────────
# Domains are read from nginx server_name directives, so new vhosts are picked
# up automatically — the same "never enumerate" rule the log sources follow.
probe_certs() {
  command -v openssl >/dev/null 2>&1 || return 0
  [ -d /etc/nginx ] || return 0

  local domains
  domains=$(grep -rhoP '^\s*server_name\s+\K[^;]+' /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null \
            | tr ' ' '\n' | grep -vE '^(_|localhost|\*)' | grep -F . | sort -u | head -50)
  [ -n "$domains" ] || return 0

  local d expiry days issuer
  for d in $domains; do
    expiry=$(echo | timeout 10 openssl s_client -servername "$d" -connect "$d:443" 2>/dev/null \
             | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -z "$expiry" ]; then
      pgq -c "INSERT INTO cert_expiry (domain, host, checked_at, error)
              VALUES ('${d//\'/}', '${HOST_NAME:-unknown}', now(), 'unreachable')
              ON CONFLICT (domain) DO UPDATE SET checked_at=now(), error='unreachable';" >/dev/null 2>&1 || true
      continue
    fi
    days=$(( ( $(date -d "$expiry" +%s) - $(date +%s) ) / 86400 ))
    issuer=$(echo | timeout 10 openssl s_client -servername "$d" -connect "$d:443" 2>/dev/null \
             | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//' | cut -c1-100)
    pgq -c "INSERT INTO cert_expiry (domain, host, not_after, days_left, issuer, checked_at, error)
            VALUES ('${d//\'/}', '${HOST_NAME:-unknown}',
                    '$(date -d "$expiry" -Iseconds)', $days,
                    '${issuer//\'/\'\'}', now(), NULL)
            ON CONFLICT (domain) DO UPDATE SET
              not_after=EXCLUDED.not_after, days_left=EXCLUDED.days_left,
              issuer=EXCLUDED.issuer, checked_at=now(), error=NULL;" >/dev/null 2>&1 || true
  done
}

probe_postgres || warn "postgres probe failed"
probe_redis    || warn "redis probe failed"
probe_mongo    || warn "mongo probe failed"
probe_certs    || warn "cert probe failed"
