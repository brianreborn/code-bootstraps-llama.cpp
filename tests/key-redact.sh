#!/bin/sh
# issue #38: the full instance key must never reach the start log
set -eu
. "$(dirname "$0")/../scripts/lib/instance-key.sh"
k1=0123456789abcdef0123456789abcdef0123456789abcdef; k2=ffffeeee11112222
[ "$(key_mask "$k1")" = "****cdef" ] || { echo "FAIL mask"; exit 1; }
out=$(printf 'Bearer %s and %s\n' "$k1" "$k2" | sed -e "$(key_redact_sed "$k1,$k2")")
case "$out" in *"$k1"*|*"$k2"*) echo "FAIL: key leaked: $out"; exit 1;; esac
[ "$out" = "Bearer ****cdef and ****2222" ] || { echo "FAIL: $out"; exit 1; }
# punctuation that GNU sed treats as operators or specials must match literally
# shellcheck disable=SC2016
for k in 'abc+def123' 'my(key-0001' 'a|b?c.d*e[f/g&h\\i^j$k' 'x]y{2}z' 'k&/\\1'; do
  out=$(printf 'key=%s end\n' "$k" | sed -e "$(key_redact_sed "$k")") || { echo "FAIL: sed died for $k"; exit 1; }
  case "$out" in *"$k"*) echo "FAIL: key leaked: $out"; exit 1;; esac
  [ "$out" = "key=$(key_mask "$k") end" ] || { echo "FAIL: $k -> $out"; exit 1; }
done
# overlapping keys: the longer one must be hidden whole, whatever the list order
s=abcdef12; l=abcdef1234567890
out=$(printf '%s %s\n' "$l" "$s" | sed -e "$(key_redact_sed "$s,$l")")
[ "$out" = "****7890 ****ef12" ] || { echo "FAIL overlap: $out"; exit 1; }
echo "ok key-redact"
