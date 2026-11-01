#!/bin/sh
# issue #38: the full instance key must never reach the start log
set -eu
. "$(dirname "$0")/../scripts/lib/instance-key.sh"
k1=0123456789abcdef0123456789abcdef0123456789abcdef; k2=ffffeeee11112222
[ "$(key_mask "$k1")" = "****cdef" ] || { echo "FAIL mask"; exit 1; }
out=$(printf 'Bearer %s and %s\n' "$k1" "$k2" | sed -e "$(key_redact_sed "$k1,$k2")")
case "$out" in *"$k1"*|*"$k2"*) echo "FAIL: key leaked: $out"; exit 1;; esac
[ "$out" = "Bearer ****cdef and ****2222" ] || { echo "FAIL: $out"; exit 1; }
echo "ok key-redact"
