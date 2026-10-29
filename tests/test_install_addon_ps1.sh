#!/bin/sh
# scripts/install-addon.ps1 (pwsh): pick resolution is fail-closed like install-addon.sh.
# The download itself is Get-VerifiedFile (scripts/lib/download.ps1, https + sha256, .bad on mismatch).
set -eu
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
PWSH=${PWSH:-$(command -v pwsh || true)}
[ -n "$PWSH" ] || { echo "test_install_addon_ps1: SKIP (pwsh not found)"; exit 0; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
die() { echo "FAIL: $*" >&2; exit 1; }
sha=$(printf '%064d' 7)
printf '{"mcpServers":{"m":{"_installer_ps1":{"url":"https://h/i.ps1","sha256":"%s"}}},"addons":{"_comment":"c","extra_mcps":{"x":{"_installer_ps1":{"url":"https://h/x.ps1","sha256":"%s"}},"nopin":{"_install":"doc"},"plain":{"_installer_ps1":{"url":"http://h/x.ps1","sha256":"%s"}}}}}' "$sha" "$sha" "$sha" > "$d/s.json"
export ADDON_STARTER="$d/s.json"
ps() { "$PWSH" -NoProfile -File "$ROOT/scripts/install-addon.ps1" "$@" 2>/dev/null; }
[ "$(ps -Resolve x)" = "https://h/x.ps1 $sha" ] || die "addons pick not resolved"
[ "$(ps -Resolve m)" = "https://h/i.ps1 $sha" ] || die "mcpServers pick not resolved"
for bad in nopin plain unknown '..'; do
  if ps -Resolve "$bad" >/dev/null; then die "$bad accepted"; fi
done
[ "$(ADDON_STARTER='' ps -Resolve oh-my-hermes 2>&1 || true)" = "" ] || die "shipped unpinned pick resolved"
echo "test_install_addon_ps1: ok"
