#!/usr/bin/env bash
#
# ai-terminal-logs — bootstrap installer
#
#   curl -fsSL https://raw.githubusercontent.com/skgnandy/ai-terminal-logs/main/install.sh | sudo bash
#
# Downloads the agent to /opt/ai-terminal-logs and runs lib/install.sh.
#
# Kept deliberately small: this is the only file fetched by the one-liner, so it
# must stay readable end-to-end by anyone about to pipe it into a root shell.
#
# Flags are passed through to lib/install.sh:
#   --port <n>      pin the logs-database port (default: first free from 5499)
#   --ref <ref>     install a specific branch or tag (default: main)
#   --local <dir>   skip the download, install from a directory already on disk
#                   (used when the app pushes the agent over SSH)

set -euo pipefail

REPO="skgnandy/ai-terminal-logs"
REF="main"
PREFIX=/opt/ai-terminal-logs
LOCAL=""
PASSTHRU=()

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)   REF="${2:?--ref needs a value}"; shift 2 ;;
    --local) LOCAL="${2:?--local needs a value}"; shift 2 ;;
    *)       PASSTHRU+=("$1"); shift ;;
  esac
done

say() { printf '\033[36m[ai-terminal-logs]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[ai-terminal-logs] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"
command -v tar >/dev/null 2>&1 || die "tar is required"

if [ -n "$LOCAL" ]; then
  [ -f "$LOCAL/lib/install.sh" ] || die "no agent found at $LOCAL"
  say "installing from $LOCAL"
  SRC="$LOCAL"
else
  command -v curl >/dev/null 2>&1 || die "curl is required"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT

  say "fetching $REPO@$REF"
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$REF" -o "$TMP/agent.tar.gz" \
    || curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/tags/$REF" -o "$TMP/agent.tar.gz" \
    || die "could not download $REPO@$REF"

  tar -xzf "$TMP/agent.tar.gz" -C "$TMP"
  SRC="$(find "$TMP" -maxdepth 1 -type d -name 'ai-terminal-logs-*' | head -1)"
  [ -n "$SRC" ] || die "unexpected archive layout"
fi

# Replace the payload atomically so a failed download never leaves a half-written
# agent behind, and an in-flight `logagent` call keeps working until the swap.
say "installing to $PREFIX"
rm -rf "$PREFIX.new"
mkdir -p "$PREFIX.new"
cp -r "$SRC/lib" "$SRC/bin" "$SRC/sql" "$SRC/systemd" "$PREFIX.new/"
[ -f "$SRC/VERSION" ] && cp "$SRC/VERSION" "$PREFIX.new/"
chmod +x "$PREFIX.new"/lib/*.sh "$PREFIX.new"/bin/* 2>/dev/null || true

rm -rf "$PREFIX.old"
[ -d "$PREFIX" ] && mv "$PREFIX" "$PREFIX.old"
mv "$PREFIX.new" "$PREFIX"
rm -rf "$PREFIX.old"

exec bash "$PREFIX/lib/install.sh" ${PASSTHRU[@]+"${PASSTHRU[@]}"}
