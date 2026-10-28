#!/bin/sh
# Tool-call chat against a patched llama-server with the API key enabled (single model, --jinja).
#   tests/smoke-toolcall.sh <llama-server> <model.gguf> [port]     log: $SMOKE_LOG (never commit)
set -eu
BIN=$1; MODEL=$2; PORT=${3:-19941}
T=$(mktemp -d); LOG=${SMOKE_LOG:-$T/server.log}
trap 'kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; rm -rf "$T"' EXIT
KEY=smoke-$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')
LLAMA_API_KEY=$KEY LLAMA_LOG_PID=1 LD_LIBRARY_PATH="$(dirname "$BIN")" \
  "$BIN" --host 127.0.0.1 --port "$PORT" -m "$MODEL" --jinja -c 4096 --temp 0.1 --top-k 50 --repeat-penalty 1.1 > "$LOG" 2>&1 &
PID=$!
i=0; until curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/health"; do i=$((i+1)); [ $i -lt 120 ] || { echo "FAIL: not up"; exit 1; }; sleep 1; done
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/models")" = 401 ] || { echo "FAIL: keyless call not rejected"; exit 1; }
out=$(printf 'header = "Authorization: Bearer %s"\n' "$KEY" | curl -s -K - --max-time 300 -H 'Content-Type: application/json' -d '{
 "messages":[{"role":"user","content":"What is the weather in Paris right now? Use the tool."}],
 "tools":[{"type":"function","function":{"name":"get_weather","description":"Current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],
 "max_tokens":256}' "http://127.0.0.1:$PORT/v1/chat/completions")
echo "$out" | python3 -c '
import json,sys
m=json.load(sys.stdin)["choices"][0]["message"]; tc=m.get("tool_calls") or []
print("tool_calls:", json.dumps([[c["function"]["name"], c["function"]["arguments"]] for c in tc]))
sys.exit(0 if tc and tc[0]["function"]["name"]=="get_weather" and "paris" in tc[0]["function"]["arguments"].lower() else 1)' && echo "smoke-toolcall: ok"
