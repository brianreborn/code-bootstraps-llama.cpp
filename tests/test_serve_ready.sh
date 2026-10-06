#!/bin/sh
# Integration test for scripts/serve.sh with the real llama-server (bin/llama-b*-linux-x64-cpu,
# or REAL_LLAMA_SERVER=): readiness cannot be spoofed, and nothing from a model cache is served.
#   sh tests/test_serve_ready.sh
# The banner line must stay "serve.sh: listening on" so this test can match it.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib/common.sh"
REAL=${REAL_LLAMA_SERVER:-}
if [ -z "$REAL" ]; then
  for c in "$ROOT"/bin/llama-b*-linux-x64-cpu/llama-server; do
    if [ -x "$c" ]; then REAL=$c; break; fi
  done
fi
if [ -z "$REAL" ] || [ ! -x "$REAL" ]; then
  echo "test_serve_ready: SKIP (no real llama-server; set REAL_LLAMA_SERVER)"
  exit 0
fi
T=$(mktemp -d)
: > "$T/pids"
fails=0
cleanup() {
  if [ -f "$T/pids" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      kill -TERM "$p" 2>/dev/null || true
    done < "$T/pids"
  fi
  sleep 1
  rm -rf "$T"
}
trap cleanup EXIT
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
pause() { python3 -c 'import sys,time; time.sleep(int(sys.argv[1])/10.0)' "$1"; }
tab=$(printf '\t')

sandbox() {
  d=$1
  mkdir -p "$d/.cache/verified"
  cp -R "$ROOT/scripts" "$ROOT/config" "$d/"
  awk -v match_kv="pick=default" -v fields="role file sha256" -f "$ROOT/scripts/lib/manifest.awk" \
    "$ROOT/config/models-manifest.json" > "$d/.cache/default-rows"
  while IFS=$tab read -r role f sha; do
    mkdir -p "$d/models/$role"
    echo "placeholder $f" > "$d/models/$role/$f"
    fingerprint "$d/models/$role/$f" > "$d/.cache/verified/$sha"
  done < "$d/.cache/default-rows"
}
hf_model() {
  c="$1/models--$2--$3"
  rev=0123456789abcdef0123456789abcdef01234567
  mkdir -p "$c/refs" "$c/snapshots/$rev"
  echo "$rev" > "$c/refs/main"
  echo "not a model" > "$c/snapshots/$rev/$3-Q4_K_M.gguf"
}
start_serve() {
  d=$1
  port=$2
  bin=$3
  shift 3
  ( cd "$d" && exec env "$@" PORT="$port" GGUF_HOME="$d" TOOLS_RUNTIME=host TOOLS="" MCP_CONFIG="" LLAMA_SERVER="$bin" \
      setsid sh scripts/serve.sh > "$d/out.txt" 2>&1 ) &
  echo $! >> "$T/pids"
  SERVE_PID=$!
}
wait_for() {
  i=0
  limit=$(($3 * 10))
  while [ "$i" -lt "$limit" ]; do
    grep -qE "$2" "$1" 2>/dev/null && return 0
    pause 1
    i=$((i + 1))
  done
  return 1
}
stop_serve() {
  kill -TERM "$SERVE_PID" 2>/dev/null || true
  i=0
  while [ "$i" -lt 100 ]; do
    kill -0 "$SERVE_PID" 2>/dev/null || return 0
    pause 1
    i=$((i + 1))
  done
}
key_of() { grep -v '^#' "$1/.secrets/api-keys" | head -n 1; }
models_of() {
  printf 'header = "Authorization: Bearer %s"\n' "$(key_of "$1")" |
    curl -s --max-time 5 --config - "http://127.0.0.1:$2/models" |
    python3 -c 'import json,sys; print(" ".join(sorted(m["id"] for m in json.load(sys.stdin)["data"])))'
}

for android in 0 1; do
  d=$T/normal$android
  sandbox "$d"
  port=$(free_port)
  if [ "$android" = 1 ]; then
    start_serve "$d" "$port" "$REAL" ANDROID_ROOT=/system PROFILE=lowram
  else
    start_serve "$d" "$port" "$REAL" PROFILE=lowram
  fi
  if wait_for "$d/out.txt" "^serve.sh: listening on http://127.0.0.1:$port" 30 && [ -s "$d/.cache/serve.ready" ]; then
    read -r rp rpid < "$d/.cache/serve.ready"
    owner=$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | head -n 1 | cut -d= -f2)
    if [ "$rp" = "$port" ] && [ "$rpid" = "$owner" ]; then
      ok "normal start (android=$android): ready file = port $rp, pid $rpid (the listener)"
    else
      bad "normal start (android=$android): ready file '$rp $rpid', listener pid '$owner'"
    fi
  else
    bad "normal start (android=$android): no banner/ready file: $(tail -n 3 "$d/out.txt")"
  fi
  stop_serve
  if [ ! -e "$d/.cache/serve.ready" ]; then ok "normal start (android=$android): ready file removed on exit"
  else bad "ready file left behind"; fi
done

cat > "$T/decoy.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
printf '#!/bin/sh\nsleep 3\nexec "%s" "$@"\n' "$REAL" > "$T/slow-llama-server"
chmod +x "$T/slow-llama-server"
for android in 1 0; do
  d=$T/spoof$android
  sandbox "$d"
  port=$(free_port)
  python3 "$T/decoy.py" "$port" &
  dpid=$!
  echo "$dpid" >> "$T/pids"
  pause 5
  echo "0.00.000.001 I srv  llama_server: listening on http://127.0.0.1:$port" > "$d/.cache/server.log"
  if [ "$android" = 1 ]; then
    start_serve "$d" "$port" "$T/slow-llama-server" ANDROID_ROOT=/system PROFILE=lowram
  else
    start_serve "$d" "$port" "$T/slow-llama-server" PROFILE=lowram
  fi
  i=0
  while [ "$i" -lt 150 ]; do
    kill -0 "$SERVE_PID" 2>/dev/null || break
    pause 1
    i=$((i + 1))
  done
  if grep -q "^serve.sh: listening on" "$d/out.txt" || [ -e "$d/.cache/serve.ready" ]; then
    bad "spoof (android=$android): the decoy was taken for our server"
  elif grep -q "couldn't bind HTTP server socket" "$d/out.txt"; then
    ok "spoof (android=$android): decoy on the port, no ready file, no banner"
  else
    bad "spoof (android=$android): unexpected: $(tail -n 3 "$d/out.txt")"
  fi
  kill "$dpid" 2>/dev/null || true
  stop_serve
done

d=$T/cache
sandbox "$d"
port=$(free_port)
hf_model "$d/.cache/llama-cache" evil decoy
dead=4194000
while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
hf_model "$d/.cache/llama-cache.$dead.abcdef" evil stale
mkdir -p "$T/outside"
hf_model "$T/outside" evil linked
start_serve "$d" "$port" "$REAL" PROFILE=lowram
if wait_for "$d/out.txt" "^serve.sh: listening on" 30; then
  got=$(models_of "$d" "$port")
  if [ "$got" = "coder decision general" ]; then ok "populated caches: /models = $got"
  else bad "populated caches: /models = $got"; fi
  run_cache=$(ls -d "$d"/.cache/llama-cache.* 2>/dev/null || true)
  n=$(printf '%s\n' "$run_cache" | wc -l | tr -d ' ')
  if [ -n "$run_cache" ] && [ "$n" = 1 ] && [ -z "$(ls -A "$run_cache")" ] && [ ! -e "$d/.cache/llama-cache" ] && [ ! -e "$d/.cache/llama-cache.$dead.abcdef" ]; then
    ok "populated caches: old and stale directories removed, the run's own one is empty"
  else
    bad "populated caches: dirs: $(ls -a "$d/.cache")"
  fi
  printf 'header = "Authorization: Bearer %s"\n' "$(key_of "$d")" |
    curl -s --max-time 60 --config - -H 'Content-Type: application/json' \
      -d '{"model":"bartowski/SmolLM2-135M-Instruct-GGUF:Q2_K"}' "http://127.0.0.1:$port/models" > "$T/post.json" || true
  sleep 20
  found=$(find "$d/.cache" -iname '*SmolLM2*' 2>/dev/null | head -n 3)
  if [ -z "$found" ]; then ok "run-time download (POST /models): nothing in the cache ($(head -c 120 "$T/post.json"))"
  else bad "run-time download landed: $found"; fi
else
  bad "populated caches: did not start: $(tail -n 3 "$d/out.txt")"
fi
stop_serve
left=$(ls -d "$d"/.cache/llama-cache* 2>/dev/null || true)
if [ -z "$left" ]; then ok "populated caches: the run's cache directory is removed on exit"
else bad "cache dir left: $left"; fi

d=$T/link
sandbox "$d"
port=$(free_port)
ln -s "$T/outside" "$d/.cache/llama-cache"
start_serve "$d" "$port" "$REAL" PROFILE=lowram
if wait_for "$d/out.txt" "^serve.sh: listening on" 30; then
  got=$(models_of "$d" "$port")
  if [ "$got" = "coder decision general" ] && [ ! -L "$d/.cache/llama-cache" ] && [ -n "$(find "$T/outside" -name '*.gguf')" ]; then
    ok "symlinked cache: /models = $got, link removed, target untouched"
  else
    bad "symlinked cache: /models = $got"
  fi
else
  bad "symlinked cache: did not start"
fi
stop_serve

if [ "$fails" -eq 0 ]; then echo "all serve readiness/cache tests passed"
else echo "$fails failed"; exit 1; fi
