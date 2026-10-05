#!/bin/sh
# install.sh unpacks with no published digest, and still refuses a wrong one.
#   sh tests/test_install.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
note() {
  if [ "$1" = ok ]; then echo "ok   $2"
  else echo "FAIL $2"; fails=$((fails + 1)); fi
}

src=$tmp/src/pkg
mkdir -p "$src"
printf '%s\n' '#!/bin/sh' 'echo start-v1' > "$src/start.sh"
tar -C "$tmp/src" -czf "$tmp/v1.tar.gz" pkg
sum=$(sha256sum "$tmp/v1.tar.gz" | cut -d' ' -f1)

run() {
  INSTALL_URL="file://$1" INSTALL_PREFIX="$2" INSTALL_NO_START=1 INSTALL_SHA256="${3-}" \
    /bin/sh "$ROOT/install.sh"
}

out=$(run "$tmp/v1.tar.gz" "$tmp/plain" 2>&1) || note no "empty digest failed: $out"
note "$(printf '%s\n' "$out" | grep -q "installed into $tmp/plain" && echo ok || echo no)" "empty digest installs"
note "$( [ -f "$tmp/plain/start.sh" ] && grep -q start-v1 "$tmp/plain/start.sh" && echo ok || echo no)" "unpacked start.sh"
note "$( [ "$(tr -d '[:space:]' < "$tmp/plain/.cache/install.sha256")" = "$sum" ] && echo ok || echo no)" "stamp is the archive digest"

out=$(run "$tmp/v1.tar.gz" "$tmp/plain" 2>&1) || note no "second run failed: $out"
note "$(printf '%s\n' "$out" | grep -q "already matches" && echo ok || echo no)" "same archive skips unpack"

bad=0
out=$(run "$tmp/v1.tar.gz" "$tmp/bad" "0000000000000000000000000000000000000000000000000000000000000000" 2>&1) || bad=1
note "$( [ "$bad" = 1 ] && printf '%s\n' "$out" | grep -q "sha256 mismatch" && [ ! -e "$tmp/bad/start.sh" ] && echo ok || echo no)" "wrong digest is not unpacked"

out=$(run "$tmp/v1.tar.gz" "$tmp/pinned" "$(printf '%s' "$sum" | tr 'a-f' 'A-F')" 2>&1) || note no "pinned digest failed: $out"
note "$( [ -f "$tmp/pinned/start.sh" ] && echo ok || echo no)" "matching digest installs"

printf '%s\n' '#!/bin/sh' 'echo start-v2' > "$src/start.sh"
tar -C "$tmp/src" -czf "$tmp/v2.tar.gz" pkg
out=$(run "$tmp/v2.tar.gz" "$tmp/plain" 2>&1) || note no "changed archive failed: $out"
note "$(grep -q start-v2 "$tmp/plain/start.sh" && echo ok || echo no)" "changed archive unpacks again"

[ "$fails" = 0 ] || { echo "test_install: $fails failed" >&2; exit 1; }
echo "test_install: OK"
