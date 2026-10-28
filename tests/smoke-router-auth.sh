#!/bin/sh
# Smoke test for a patched llama-server (patches/): router with an API key, one child, then
#  - the router->child stream lookup and stream stop must not 401 in the child (0001)
#  - with LLAMA_LOG_PID=1 log lines start with [pid] and child lines with [pid model:port] (0002)
#   tests/smoke-router-auth.sh <llama-server> <model.gguf> [port]
# Writes its log to $SMOKE_LOG (default: a temp file); never commit logs (see .gitignore).
set -eu
BIN=$1; MODEL=$2; PORT=${3:-19931}
T=$(mktemp -d); LOG=${SMOKE_LOG:-$T/router.log}
trap 'kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; rm -rf "$T"' EXIT
printf 'version = 1\n[tiny]\nmodel = %s\nctx-size = 512\n' "$MODEL" > "$T/preset.ini"
KEY=smoke-$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')
LLAMA_API_KEY=$KEY LLAMA_LOG_PID=1 LD_LIBRARY_PATH="$(dirname "$BIN")" \
  "$BIN" --host 127.0.0.1 --port "$PORT" --models-preset "$T/preset.ini" --models-max 1 > "$LOG" 2>&1 &
PID=$!
auth() { printf 'header = "Authorization: Bearer %s"\n' "$KEY"; }
i=0; until curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/health"; do i=$((i+1)); [ $i -lt 60 ] || { echo "FAIL: router not up"; exit 1; }; sleep 1; done
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/models")
[ "$code" = 401 ] || { echo "FAIL: keyless /v1/models gave $code, want 401"; exit 1; }
auth | curl -s -K - -o /dev/null --max-time 120 -H 'Content-Type: application/json' -H 'X-Conversation-Id: conv-smoke' \
  -d '{"model":"tiny","messages":[{"role":"user","content":"hi"}],"max_tokens":4}' "http://127.0.0.1:$PORT/v1/chat/completions"
lk=$(auth | curl -s -K - -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -d '{"conversation_ids":["conv-smoke"]}' "http://127.0.0.1:$PORT/v1/streams/lookup")
st=$(auth | curl -s -K - -o /dev/null -w '%{http_code}' -X DELETE "http://127.0.0.1:$PORT/v1/stream?conv_id=conv-smoke")
sleep 1
echo "lookup=$lk stop=$st"
fail=0
# exactly one rejection is expected: our own keyless /v1/models probe above, in the router
n=$(grep -c 'Invalid API Key' "$LOG" || true)
if [ "$n" != 1 ]; then echo "FAIL: $n 'Invalid API Key' lines (want 1, the keyless probe)"; grep -n 'Invalid API Key' "$LOG" | head -3; fail=1; fi
grep -Eq "^\[$PID\] " "$LOG" || { echo "FAIL: no [${PID}] router prefix"; fail=1; }
grep -Eq "\[[0-9]+ tiny:[0-9]+\] " "$LOG" || { echo "FAIL: no [pid tiny:port] child prefix"; fail=1; }
grep -E "\[[0-9]+( tiny:[0-9]+)?\] " "$LOG" | head -4
[ $fail = 0 ] && echo "smoke-router-auth: ok"
exit $fail
