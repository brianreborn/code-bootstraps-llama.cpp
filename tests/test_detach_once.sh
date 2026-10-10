#!/bin/sh
# Single detach / one log when familia already detached (#18).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d)
fails=0
cleanup() { rm -rf "$T"; }
trap cleanup EXIT
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

mkdir -p "$T/scripts/lib" "$T/.cache" "$T/.secrets"
cp "$ROOT/start.sh" "$T/start.sh"
# Minimal lib stubs
printf '%s\n' 'lang_code_of(){ echo en; }' 't(){ printf %s "$*"; }' > "$T/scripts/lib/i18n.sh"
printf '%s\n' 'maybe_raise(){ :; }' > "$T/scripts/lib/raise-once.sh"
printf '%s\n' 'bind_hosts(){ echo "$1"; }' 'probe_host_of(){ echo "$1"; }' 'url_host(){ echo "$1"; }' 'public_hosts(){ :; }' > "$T/scripts/lib/bindhost.sh"
printf '%s\n' '#!/bin/sh' 'echo "$LLAMA_SERVER"' > "$T/scripts/fetch-llama.sh"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$T/scripts/fetch-models.sh"
printf '%s\n' '#!/bin/sh' \
  'echo "SERVE ran DETACH_MODE=${DETACH_MODE-} FAMILIA_DETACHED=${FAMILIA_DETACHED-} LOG_FILE=${LOG_FILE-}" > "$ROOT/.cache/serve-ran.txt"' \
  'exit 0' > "$T/scripts/serve.sh"
chmod +x "$T/scripts/"*.sh
printf '%s\n' '#!/bin/sh' 'exit 0' > "$T/llama-server"
chmod +x "$T/llama-server"
echo 'test-key' > "$T/.secrets/api-keys"
# Use a free high port so port_busy doesn't loop long
PORT=39111
LOG="$T/one.log"

# 1) FAMILIA_DETACHED=1 + DETACH_MODE=nohup => foreground serve, no second nohup
rm -f "$T/.cache/serve-ran.txt"
( cd "$T" && env ROOT="$T" FAMILIA_DETACHED=1 DETACH_MODE=nohup LOG_FILE="$LOG" \
    LLAMA_SERVER="$T/llama-server" NO_BROWSER=1 VARIANT=cpu PORT="$PORT" \
    sh start.sh > "$T/out.txt" 2>&1 ) || true
if grep -q 'familia already detached' "$T/out.txt" \
   && grep -q 'FAMILIA_DETACHED=1' "$T/.cache/serve-ran.txt" \
   && ! grep -q 'launching detached with nohup' "$T/out.txt"; then
  ok "FAMILIA_DETACHED forces foreground (no second nohup)"
else
  bad "second detach still happened"
  echo '--- out ---'; cat "$T/out.txt"
  echo '--- ran ---'; cat "$T/.cache/serve-ran.txt" 2>/dev/null || true
fi

# 2) plain nohup uses LOG_FILE
rm -f "$T/.cache/serve-ran.txt"
( cd "$T" && env ROOT="$T" DETACH_MODE=nohup LOG_FILE="$LOG" \
    LLAMA_SERVER="$T/llama-server" NO_BROWSER=1 VARIANT=cpu PORT="$PORT" \
    sh start.sh > "$T/out2.txt" 2>&1 ) || true
sleep 0.4
if grep -Fq "logging to $LOG" "$T/out2.txt"; then
  ok "nohup logs to LOG_FILE"
else
  bad "LOG_FILE not used"; cat "$T/out2.txt"
fi

# 3) source-level: FAMILIA_DETACHED block present
if grep -q 'FAMILIA_DETACHED' "$ROOT/start.sh" && grep -q 'LOG_FILE:-.cache/server.log\|_log=\${LOG_FILE' "$ROOT/start.sh"; then
  ok "start.sh has FAMILIA_DETACHED + LOG_FILE wiring"
else
  bad "start.sh missing #18 wiring"
fi

if [ "$fails" -gt 0 ]; then echo "FAILED $fails"; exit 1; fi
echo "ALL OK"
