#!/bin/sh
# Install a starter-pack add-on / MCP pick from its pinned installer, the safe way:
# download to a NAMED file, check its sha256, show where it is, then run it. Never piped into a shell.
#   sh scripts/install-addon.sh <pick>            download + verify + run
#   sh scripts/install-addon.sh --fetch <pick>    download + verify only (read it first)
# The pick needs "_installer": {"url": "https://...", "sha256": "<64 hex>"} in
# config/mcp-servers.starter.json (mcpServers or addons.*). No sha256 = refused (fail-closed).
# Env: ADDON_STARTER (starter file), ADDON_DIR (default .cache/installers).
set -eu
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
run=1
[ "${1:-}" = --fetch ] && { run=0; shift; }
pick=${1:-}
die() { echo "install-addon: $*" >&2; exit 1; }
case "$pick" in ""|*[!A-Za-z0-9._-]*) die "usage: install-addon.sh [--fetch] <pick>" ;; esac
STARTER=${ADDON_STARTER:-$ROOT/config/mcp-servers.starter.json}
DIR=${ADDON_DIR:-$ROOT/.cache/installers}
command -v python3 >/dev/null 2>&1 || die "python3 is needed to read $STARTER"
spec=$(python3 "$ROOT/scripts/lib/addon_installer.py" "$STARTER" "$pick") || exit 1
url=${spec%% *}; sha=${spec#* }
command -v curl >/dev/null 2>&1 || die "curl is needed"
mkdir -p "$DIR"
file=$DIR/install-$pick.sh
rm -f "$file.part"
curl -fsSLo "$file.part" "$url" || die "download failed: $url"
if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$file.part" | cut -d' ' -f1)
else got=$(shasum -a 256 "$file.part" | cut -d' ' -f1); fi
if [ "$got" != "$sha" ]; then
  mv -f "$file.part" "$file.bad"
  die "sha256 mismatch for $pick (got $got, pinned $sha); kept as $file.bad, not run"
fi
mv -f "$file.part" "$file"
echo "install-addon: $pick installer saved to $file (sha256 ok)"
[ "$run" = 1 ] || { echo "install-addon: read it, then run: sh $file"; exit 0; }
cd "$DIR" && sh "./install-$pick.sh"
