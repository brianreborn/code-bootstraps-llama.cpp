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

# serve.sh live-tail path: sed -f on a 0600 mktemp file (keys must not be in argv)
_td=$(umask 077; mktemp -d) || { echo "FAIL: mktemp -d"; exit 1; }
cleanup_kr() { [ -n "${_spid:-}" ] && kill "$_spid" 2>/dev/null || true; exec 4>&- 2>/dev/null || true; rm -rf "$_td"; }
trap cleanup_kr EXIT
_sf=$_td/key.sed
( umask 077; key_redact_sed "$k1,$k2" > "$_sf" )
chmod 600 "$_sf"
case $(ls -l "$_sf") in -rw-------*) ;; *) echo "FAIL: sed script mode $(ls -l "$_sf")"; exit 1;; esac
out=$(printf 'Bearer %s and %s\n' "$k1" "$k2" | sed -f "$_sf")
case "$out" in *"$k1"*|*"$k2"*) echo "FAIL: -f key leaked: $out"; exit 1;; esac
[ "$out" = "Bearer ****cdef and ****2222" ] || { echo "FAIL -f: $out"; exit 1; }
# punctuation + overlap through -f as well
for k in 'abc+def123' 'my(key-0001' 'a|b?c.d*e[f/g&h\\i^j$k' 'x]y{2}z' 'k&/\\1'; do
  key_redact_sed "$k" > "$_sf"
  out=$(printf 'key=%s end\n' "$k" | sed -f "$_sf") || { echo "FAIL: sed -f died for $k"; exit 1; }
  case "$out" in *"$k"*) echo "FAIL: -f key leaked: $out"; exit 1;; esac
  [ "$out" = "key=$(key_mask "$k") end" ] || { echo "FAIL -f: $k -> $out"; exit 1; }
done
key_redact_sed "$s,$l" > "$_sf"
out=$(printf '%s %s\n' "$l" "$s" | sed -f "$_sf")
[ "$out" = "****7890 ****ef12" ] || { echo "FAIL -f overlap: $out"; exit 1; }

# If we can inspect a running filter's argv, the keys must be absent there.
key_redact_sed "$k1,$k2" > "$_sf"
_fifo=$_td/in
_outf=$_td/out
mkfifo "$_fifo"
sed -u -f "$_sf" < "$_fifo" > "$_outf" &
_spid=$!
exec 4>"$_fifo"
_args=""
if [ -r /proc/$_spid/cmdline ]; then
  _args=$(tr '\0' ' ' < /proc/$_spid/cmdline)
elif command -v ps >/dev/null 2>&1; then
  _args=$(ps -p "$_spid" -o args= 2>/dev/null || ps -p "$_spid" -o command= 2>/dev/null || true)
fi
if [ -n "$_args" ]; then
  case "$_args" in
    *"$k1"*|*"$k2"*) echo "FAIL: key in sed argv: $_args"; exit 1;;
  esac
else
  echo "note: could not inspect sed argv; skipped leak assertion"
fi
printf 'Bearer %s and %s\n' "$k1" "$k2" >&4
exec 4>&-
wait "$_spid"
_spid=""
out=$(cat "$_outf")
[ "$out" = "Bearer ****cdef and ****2222" ] || { echo "FAIL -f live: $out"; exit 1; }
echo "ok key-redact"
