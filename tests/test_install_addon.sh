#!/bin/sh
# scripts/install-addon.sh: named file, sha256 pinned (fail-closed), --fetch does not run,
# mismatch is kept as .bad and never run. Offline: a file:// URL is served by a curl shim.
set -eu
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
die() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$d/bin" "$d/srv"
printf '#!/bin/sh\necho ran > "%s/ran"\n' "$d" > "$d/srv/inst.sh"
# curl shim: copy the "https://test/<f>" file from $d/srv to -o target
cat > "$d/bin/curl" <<SHIM
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -fsSLo) out=\$2; shift ;; *) url=\$1 ;; esac; shift; done
cp "$d/srv/\${url##*/}" "\$out"
SHIM
chmod +x "$d/bin/curl"
sha=$(sha256sum "$d/srv/inst.sh" | cut -d' ' -f1)
mk() { printf '{"mcpServers":{},"addons":{"extra_mcps":{"x":{"_installer":{"url":"%s","sha256":"%s"}},"nopin":{"_install":"doc"}}}}' "$1" "$2" > "$d/s.json"; }
export PATH="$d/bin:$PATH" ADDON_STARTER="$d/s.json" ADDON_DIR="$d/inst"
mk https://test/inst.sh "$sha"
sh "$ROOT/scripts/install-addon.sh" --fetch x >/dev/null
[ -f "$d/inst/install-x.sh" ] || die "named file missing"
[ ! -f "$d/ran" ] || die "--fetch ran the installer"
sh "$ROOT/scripts/install-addon.sh" x >/dev/null
[ -f "$d/ran" ] || die "installer did not run"
rm -f "$d/ran" "$d/inst/install-x.sh"
mk https://test/inst.sh "$(printf '%064d' 0)"
if sh "$ROOT/scripts/install-addon.sh" x 2>/dev/null; then die "mismatch accepted"; fi
[ -f "$d/inst/install-x.sh.bad" ] && [ ! -f "$d/ran" ] || die "mismatch not quarantined"
if sh "$ROOT/scripts/install-addon.sh" nopin 2>/dev/null; then die "unpinned pick accepted"; fi
mk http://test/inst.sh "$sha"
if sh "$ROOT/scripts/install-addon.sh" x 2>/dev/null; then die "http accepted"; fi
if sh "$ROOT/scripts/install-addon.sh" '../x' 2>/dev/null; then die "bad pick name accepted"; fi
# shipped starter: no pipe-to-shell and no unpinned @latest in install notes
if grep '"_install"' "$ROOT/config/mcp-servers.starter.json" | grep -nE '\|[[:space:]]*(sh|bash|iex)\b|@latest'; then die "starter has pipe/@latest install"; fi
echo "test_install_addon: ok"
