#!/usr/bin/env bash
# Integration test for scripts/serve.sh with the real llama-server (bin/llama-b*-linux-x64-cpu,
# or REAL_LLAMA_SERVER=): readiness cannot be spoofed, and nothing from a model cache is served.
#   bash tests/test_serve_ready.sh      (Linux; ports picked at random; ~1 min)
# Against the code before review round 5, cases 2 (android), 3 and the symlink case fail.
# 1. normal start (also with ANDROID_ROOT set, where ss/lsof cannot see sockets): ready file
#    with our pid, "listening" banner
# 2. spoof (review round 5): a decoy answers /health on the port, the real server starts 3 s
#    late and cannot bind, an old server.log already says "listening on" that port: no ready
#    file, no banner, on Android and elsewhere
# 3. populated caches: an HF-layout model in the old .cache/llama-cache, in a stale
#    .cache/llama-cache.<dead pid>.*, and behind a .cache/llama-cache symlink: /models lists
#    exactly coder, decision, general; the stale dirs are gone, the symlink target is untouched,
#    the run's own cache directory is removed on exit
# 4. a model download requested at run time (POST /models) leaves nothing in the cache, not
#    even the refs/main the router's online check of the request writes (with network access;
#    without LLAMA_ARG_OFFLINE the model lands, without MODEL_ENDPOINT=https://offline.invalid/
#    refs/main does; both checked by hand on 2026-10-03)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL="${REAL_LLAMA_SERVER:-$(ls "$ROOT"/bin/llama-b*-linux-x64-cpu/llama-server 2>/dev/null | head -1)}"
[[ -x "$REAL" ]] || { echo "test_serve_ready: SKIP (no real llama-server; set REAL_LLAMA_SERVER)"; exit 0; }
# shellcheck source=../scripts/lib/common.sh
. "$ROOT/scripts/lib/common.sh"
T="$(mktemp -d)"; fails=0; PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null || true; done; sleep 1; rm -rf "$T"; }
trap cleanup EXIT
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

sandbox() {   # $1 dir: scripts + config, placeholder default models with valid stamps
  local d="$1" f sha role
  mkdir -p "$d/.cache/verified"
  cp -a "$ROOT/scripts" "$ROOT/config" "$d/"
  while IFS=$'\t' read -r role f sha; do
    mkdir -p "$d/models/$role"; echo "placeholder $f" > "$d/models/$role/$f"
    fingerprint "$d/models/$role/$f" > "$d/.cache/verified/$sha"
  done < <(awk -v match_kv="pick=default" -v fields="role file sha256" -f "$ROOT/scripts/lib/manifest.awk" "$ROOT/config/models-manifest.json")
}
hf_model() {   # $1 hub dir, $2 org, $3 name: one GGUF in the Hugging Face cache layout
  local c="$1/models--$2--$3" rev=0123456789abcdef0123456789abcdef01234567
  mkdir -p "$c/refs" "$c/snapshots/$rev"; echo "$rev" > "$c/refs/main"
  echo "not a model" > "$c/snapshots/$rev/$3-Q4_K_M.gguf"
}
start_serve() {   # $1 sandbox, $2 port, $3 llama-server, rest: env assignments; output in $1/out.txt
  local d="$1" port="$2" bin="$3"; shift 3
  ( cd "$d" && exec env "$@" PORT="$port" TOOLS_RUNTIME=host TOOLS="" MCP_CONFIG="" LLAMA_SERVER="$bin" \
      setsid bash scripts/serve.sh > "$d/out.txt" 2>&1 ) &
  PIDS+=($!); SERVE_PID=$!
}
wait_for() {   # $1 file, $2 regex, $3 seconds; 0 when it matched
  local i; for ((i = 0; i < $3 * 10; i++)); do grep -qE "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1
}
stop_serve() { kill -TERM "$SERVE_PID" 2>/dev/null || true; for _ in $(seq 1 100); do kill -0 "$SERVE_PID" 2>/dev/null || return 0; sleep 0.1; done; }
key_of() { grep -v '^#' "$1/.secrets/api-keys" | head -1; }
models_of() {   # $1 sandbox, $2 port: sorted ids from GET /models
  printf 'header = "Authorization: Bearer %s"\n' "$(key_of "$1")" |
    curl -s --max-time 5 --config - "http://127.0.0.1:$2/models" |
    python3 -c 'import json,sys; print(" ".join(sorted(m["id"] for m in json.load(sys.stdin)["data"])))'
}

# --- 1. normal start --------------------------------------------------------------------
for android in 0 1; do
  d="$T/normal$android"; sandbox "$d"; port="$(free_port)"
  envs=(); [[ "$android" == 1 ]] && envs=(ANDROID_ROOT=/system)
  start_serve "$d" "$port" "$REAL" "${envs[@]}" PROFILE=lowram
  if wait_for "$d/out.txt" "^serve.sh: listening on http://127.0.0.1:$port" 30 && [[ -s "$d/.cache/serve.ready" ]]; then
    read -r rp rpid < "$d/.cache/serve.ready"
    owner="$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)"
    if [[ "$rp" == "$port" && "$rpid" == "$owner" ]]; then ok "normal start (android=$android): ready file = port $rp, pid $rpid (the listener)"
    else bad "normal start (android=$android): ready file '$rp $rpid', listener pid '$owner'"; fi
  else bad "normal start (android=$android): no banner/ready file: $(tail -3 "$d/out.txt")"; fi
  stop_serve
  [[ ! -e "$d/.cache/serve.ready" ]] && ok "normal start (android=$android): ready file removed on exit" || bad "ready file left behind"
done

# --- 2. spoof: decoy on the port, slow real server --------------------------------------
cat > "$T/decoy.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
printf '#!/bin/bash\nsleep 3\nexec "%s" "$@"\n' "$REAL" > "$T/slow-llama-server"; chmod +x "$T/slow-llama-server"
for android in 1 0; do
  d="$T/spoof$android"; sandbox "$d"; port="$(free_port)"
  python3 "$T/decoy.py" "$port" & dpid=$!; PIDS+=("$dpid"); sleep 0.5
  echo "0.00.000.001 I srv  llama_server: listening on http://127.0.0.1:$port" > "$d/.cache/server.log"   # stale
  envs=(); [[ "$android" == 1 ]] && envs=(ANDROID_ROOT=/system)
  start_serve "$d" "$port" "$T/slow-llama-server" "${envs[@]}" PROFILE=lowram
  for _ in $(seq 1 150); do kill -0 "$SERVE_PID" 2>/dev/null || break; sleep 0.1; done   # the server cannot bind and exits
  if grep -q "^serve.sh: listening on" "$d/out.txt" || [[ -e "$d/.cache/serve.ready" ]]; then
    bad "spoof (android=$android): the decoy was taken for our server"
  elif grep -q "couldn't bind HTTP server socket" "$d/out.txt"; then ok "spoof (android=$android): decoy on the port, no ready file, no banner"
  else bad "spoof (android=$android): unexpected: $(tail -3 "$d/out.txt")"; fi
  kill "$dpid" 2>/dev/null || true; stop_serve
done

# --- 3. populated caches -------------------------------------------------------------------
d="$T/cache"; sandbox "$d"; port="$(free_port)"
hf_model "$d/.cache/llama-cache" evil decoy                     # the old fixed directory
dead=4194000; while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
hf_model "$d/.cache/llama-cache.$dead.abcdef" evil stale       # left by a killed serve.sh
mkdir -p "$T/outside"; hf_model "$T/outside" evil linked
start_serve "$d" "$port" "$REAL" PROFILE=lowram
if wait_for "$d/out.txt" "^serve.sh: listening on" 30; then
  got="$(models_of "$d" "$port")"
  [[ "$got" == "coder decision general" ]] && ok "populated caches: /models = $got" || bad "populated caches: /models = $got"
  run_cache="$(ls -d "$d"/.cache/llama-cache.* 2>/dev/null)"
  [[ "$(echo "$run_cache" | wc -l)" == 1 && -z "$(ls -A "$run_cache")" && ! -e "$d/.cache/llama-cache" && ! -e "$d/.cache/llama-cache.$dead.abcdef" ]] &&
    ok "populated caches: old and stale directories removed, the run's own one is empty" || bad "populated caches: dirs: $(ls -a "$d/.cache")"
  # --- 4. a download requested at run time ---
  printf 'header = "Authorization: Bearer %s"\n' "$(key_of "$d")" |
    curl -s --max-time 60 --config - -H 'Content-Type: application/json' \
      -d '{"model":"bartowski/SmolLM2-135M-Instruct-GGUF:Q2_K"}' "http://127.0.0.1:$port/models" > "$T/post.json" || true
  sleep 20   # without offline mode the 88 MB file lands within seconds here (needs network to mean anything)
  found="$(find "$d/.cache" -iname '*SmolLM2*' 2>/dev/null | head -3)"
  [[ -z "$found" ]] && ok "run-time download (POST /models): nothing in the cache ($(head -c 120 "$T/post.json"))" || bad "run-time download landed: $found"
else bad "populated caches: did not start: $(tail -3 "$d/out.txt")"; fi
stop_serve
[[ -z "$(ls -d "$d"/.cache/llama-cache* 2>/dev/null)" ]] && ok "populated caches: the run's cache directory is removed on exit" || bad "cache dir left: $(ls -d "$d"/.cache/llama-cache*)"
# a symlink in place of the old directory: the link goes, its target stays
d="$T/link"; sandbox "$d"; port="$(free_port)"; ln -s "$T/outside" "$d/.cache/llama-cache"
start_serve "$d" "$port" "$REAL" PROFILE=lowram
if wait_for "$d/out.txt" "^serve.sh: listening on" 30; then
  got="$(models_of "$d" "$port")"
  [[ "$got" == "coder decision general" && ! -L "$d/.cache/llama-cache" && -n "$(find "$T/outside" -name '*.gguf')" ]] &&
    ok "symlinked cache: /models = $got, link removed, target untouched" || bad "symlinked cache: /models = $got, $(ls -la "$d/.cache" | head -5)"
else bad "symlinked cache: did not start"; fi
stop_serve

[[ "$fails" == 0 ]] && echo "all serve readiness/cache tests passed" || { echo "$fails failed"; exit 1; }
