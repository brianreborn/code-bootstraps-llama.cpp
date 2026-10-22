#!/bin/sh
# Build the pinned FreeBSD CPU server; optionally load and query a local GGUF.
#   sh tests/test-freebsd.sh
#   MODEL=/path/to/local-model.gguf sh tests/test-freebsd.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

[ "$(uname -s)" = FreeBSD ] || {
  echo "test-freebsd: run this test on FreeBSD; current OS is $(uname -s)" >&2
  exit 2
}

BUILD_DIR=${BUILD_DIR:-build-freebsd}
GPU=off BUILD_DIR="$BUILD_DIR" scripts/build-linux.sh
SERVER=$BUILD_DIR/bin/llama-server
[ -x "$SERVER" ] || { echo "test-freebsd: build succeeded but $SERVER is missing" >&2; exit 1; }

if [ -z "${MODEL:-}" ]; then
  echo "test-freebsd: build and version check passed; model load not tested."
  echo "Set MODEL to a local GGUF path to run the loopback inference smoke test."
  exit 0
fi

case "$MODEL" in
  /*) ;;
  *) MODEL=$ROOT/$MODEL ;;
esac
[ -f "$MODEL" ] || { echo "test-freebsd: MODEL is not a file: $MODEL" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "test-freebsd: curl is required for the model smoke test" >&2; exit 1; }

PORT=${PORT:-19931}
LOG=$(mktemp)
PID=""
cleanup() {
  if [ -n "$PID" ]; then
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -f "$LOG"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  echo "test-freebsd: port $PORT already answers on loopback; choose another with PORT" >&2
  exit 1
fi
"$SERVER" --model "$MODEL" --host 127.0.0.1 --port "$PORT" --ctx-size 512 --n-gpu-layers 0 >"$LOG" 2>&1 &
PID=$!
i=0
while [ "$i" -lt 300 ]; do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "test-freebsd: llama-server exited before becoming ready:" >&2
    cat "$LOG" >&2
    exit 1
  fi
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
  i=$((i + 1))
done
[ "$i" -lt 300 ] || {
  echo "test-freebsd: model did not load within 300 seconds:" >&2
  cat "$LOG" >&2
  exit 1
}
curl -fsS --max-time 120 -H 'Content-Type: application/json' \
  -d '{"prompt":"Reply with OK.","n_predict":8}' \
  "http://127.0.0.1:$PORT/completion" >/dev/null
echo "test-freebsd: local model loaded and completed a loopback request."
