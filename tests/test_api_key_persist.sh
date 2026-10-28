#!/bin/sh
# scripts/lib/instance-key.sh: one stable key per port, concurrent first starts agree,
# never rotated, legacy .secrets key adopted, dir 700 / file 600, no temp left.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
die() { echo "$*" >&2; exit 1; }
export XDG_CONFIG_HOME=$d/xdg HOME=$d
unset API_KEY_FILE || true
. "$ROOT/scripts/lib/instance-key.sh"
f=$(instance_key_file 9931)
[ "$f" = "$d/xdg/familia/instances/9931/api-keys" ] || die "FAIL: path $f"
run() { ( instance_key_ensure "$f" ""; instance_key_first "$f" ) ; }
for i in 1 2 3 4 5 6; do run > "$d/out.$i" 2>/dev/null & done; wait
n=$(cat "$d"/out.* | sort -u | wc -l); [ "$n" -eq 1 ] || die "FAIL: $n different keys"
k1=$(cat "$d/out.1"); [ "$(run 2>/dev/null)" = "$k1" ] || die "FAIL: key regenerated"
[ "$(stat -c %a "$f")" = 600 ] || die "FAIL: file mode"
[ "$(stat -c %a "$(dirname "$f")")" = 700 ] || die "FAIL: dir mode"
ls -a "$(dirname "$f")" | grep -q tmp && die "FAIL: temp left"
# another port is another instance with its own key
g=$(instance_key_file 9932); instance_key_ensure "$g" "" 2>/dev/null
[ "$(instance_key_first "$g")" != "$k1" ] || die "FAIL: ports share a key"
# legacy checkout key is adopted, not replaced
mkdir -p "$d/legacy"; printf '# x\nlegacykey\n' > "$d/legacy/api-keys"
h=$(instance_key_file 9933); instance_key_ensure "$h" "$d/legacy/api-keys" 2>/dev/null
[ "$(instance_key_first "$h")" = legacykey ] || die "FAIL: legacy not adopted"
echo "test_api_key_persist: ok"
