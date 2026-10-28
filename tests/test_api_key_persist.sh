#!/bin/sh
# The key block of serve.sh: existing key reused, concurrent first starts agree, mode 600.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
blk=$(awk '/^mkdir -p "\$\(dirname "\$API_KEY_FILE"\)"/,/^\[ -n "\$API_KEYS" \]/' "$ROOT/scripts/serve.sh")
t() { printf '%s' "$1"; }; die() { echo "$*" >&2; exit 1; }
run() { ( API_KEY_FILE=$d/.secrets/api-keys; eval "$blk"; echo "$API_KEYS" ) ; }
for i in 1 2 3 4 5 6; do run > "$d/out.$i" 2>/dev/null & done; wait
n=$(cat "$d"/out.* | sort -u | wc -l); [ "$n" -eq 1 ] || die "FAIL: $n different keys"
k1=$(cat "$d/out.1"); [ "$(run 2>/dev/null)" = "$k1" ] || die "FAIL: key regenerated"
[ "$(stat -c %a "$d/.secrets/api-keys")" = 600 ] || die "FAIL: mode"
ls "$d/.secrets" | grep -q tmp && die "FAIL: temp left"
echo "test_api_key_persist: ok"
