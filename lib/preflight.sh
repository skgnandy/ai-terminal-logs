#!/usr/bin/env bash
# Pre-flight: reclaim disk BEFORE adding a log store to it.
#
# Rationale: journald ships uncapped and routinely reaches several GB on a
# long-lived host. PM2 log files are uncapped too. Installing a log database on a
# disk already near capacity is how a monitoring tool causes the outage it exists
# to detect — so reclaim first, then refuse if there still is not enough room.

set -euo pipefail
. /opt/ai-terminal-logs/lib/common.sh

MIN_FREE_BYTES=$((3 * 1024 * 1024 * 1024))

preflight() {
  local before after
  before=$(free_bytes)
  log "free disk before pre-flight: $(gb "$before") GB"

  cap_journald
  cap_pm2

  after=$(free_bytes)
  log "free disk after pre-flight: $(gb "$after") GB (reclaimed $(( (after - before) / 1024 / 1024 )) MB)"

  if [ "$after" -lt "$MIN_FREE_BYTES" ]; then
    die "only $(gb "$after") GB free after reclaim — refusing to install a log store.
     Free space and re-run, or install on a machine with more headroom."
  fi
}

cap_journald() {
  local conf=/etc/systemd/journald.conf
  [ -f "$conf" ] || return 0

  if grep -qs '^SystemMaxUse=' "$conf"; then
    log "journald already capped, skipping"
    return 0
  fi

  log "capping journald (SystemMaxUse=500M, MaxRetentionSec=5d)"
  cp "$conf" "$conf.bak.$(date +%s)"
  printf '\n# added by ai-terminal-logs\nSystemMaxUse=500M\nMaxRetentionSec=5d\n' >> "$conf"
  systemctl restart systemd-journald >/dev/null 2>&1 || warn "journald restart failed"
  journalctl --vacuum-time=5d >/dev/null 2>&1 || true
}

cap_pm2() {
  command -v pm2 >/dev/null 2>&1 || return 0

  if pm2 list 2>/dev/null | grep -q pm2-logrotate; then
    log "pm2-logrotate already present, skipping"
    return 0
  fi

  # Rotate, never flush. `pm2 flush` would destroy history that nothing has
  # collected yet — on a busy host that is gigabytes of evidence gone for good.
  log "installing pm2-logrotate (50M x 5, compressed)"
  pm2 install pm2-logrotate           >/dev/null 2>&1 || { warn "pm2-logrotate install failed"; return 0; }
  pm2 set pm2-logrotate:max_size 50M  >/dev/null 2>&1 || true
  pm2 set pm2-logrotate:retain 5      >/dev/null 2>&1 || true
  pm2 set pm2-logrotate:compress true >/dev/null 2>&1 || true
}

# `if`, not `[ … ] && preflight`. As the last statement in a SOURCED file the
# `&&` form returns 1 when the test fails, which under the caller's `set -e`
# aborts the installer at the `.` line — before this file's functions are ever
# called, and with nothing printed to say why.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  preflight
fi
