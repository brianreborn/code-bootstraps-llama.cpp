#!/bin/sh
# serve.sh readiness: polls the real /health (no fixed short limit), prints progress while a
# slow server starts, and says clearly when READY_TIMEOUT passes. A stub llama-server (python)
# says "listening on" in --log-file only after STUB_DELAY seconds (a slow first model load).
#   sh tests/test_ready_wait.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib/common.sh"
command -v curl >/dev/null 2>&1 || { echo "test_ready_wait: SKIP (no curl)"; exit 0; }
T=$(mktemp -d)
export XDG_CONFIG_HOME="$T/xdg"
: > "$T/pids"
fails=0
cleanup() {
  while IFS= read -r p; do [ -n "$p" ] && kill -TERM -"$p" 2>/dev/null; kill -TERM "$p" 2>/dev/null; done < "$T/pids" || true
  rm -rf "$T"
}
trap cleanup EXIT
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
tab=$(printf '\t')
cat > "$T/llama-server" <<'PY'
#!/usr/bin/env python3
# stub: the router (with --models-preset) listens at once but logs "listening on" and answers
# /health only after STUB_DELAY s (STUB_DELAY=-1: never); other starts (embed) just idle.
import http.server, os, sys, time, threading
a = sys.argv[1:]
if "--version" in a: print("version: 0 (stub)"); sys.exit(0)
def arg(k, d=None): return a[a.index(k) + 1] if k in a else d
if "--models-preset" not in a: time.sleep(3600); sys.exit(0)
port, log = int(arg("--port")), arg("--log-file")
delay = float(os.environ.get("STUB_DELAY", "0")); t0 = time.time()
ready = lambda: delay >= 0 and time.time() - t0 >= delay
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = 200 if ready() else 503
        self.send_response(code); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *x): pass
srv = http.server.HTTPServer(("127.0.0.1", port), H)
def said():
    while not ready(): time.sleep(0.2)
    open(log, "a").write("main: server is listening on http://127.0.0.1:%d\n" % port)
threading.Thread(target=said, daemon=True).start()
srv.serve_forever()
PY
chmod +x "$T/llama-server"
sandbox() {
  d=$1
  mkdir -p "$d/.cache/verified"
  cp -R "$ROOT/scripts" "$ROOT/config" "$ROOT/lib" "$d/"
  awk -v match_kv="pick=default" -v fields="role file sha256 dir" -f "$ROOT/scripts/lib/manifest.awk" \
    "$ROOT/config/models-manifest.json" > "$d/.cache/default-rows"
  while IFS=$tab read -r role f sha dir; do
    [ "$dir" = "-" ] && dir="models/$role"
    mkdir -p "$d/$dir"
    [ -f "$d/$dir/$f" ] && continue
    echo "placeholder $f" > "$d/$dir/$f"
    fingerprint "$d/$dir/$f" >> "$d/.cache/verified/$sha"
  done < "$d/.cache/default-rows"
}
run() {   # run NAME SECONDS ENV... : start serve.sh, wait up to SECONDS for it to settle
  d=$T/$1; lim=$2; shift 2
  sandbox "$d"
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  ( cd "$d" && exec env "$@" PORT="$port" GGUF_HOME="$d" TOOLS="" MCP_CONFIG="" TOOLS_RUNTIME=host LANGUAGE_MODE=off \
      LLAMA_SERVER="$T/llama-server" setsid sh scripts/serve.sh > "$d/out.txt" 2>&1 ) &
  echo $! >> "$T/pids"
  i=0
  while [ "$i" -lt "$lim" ]; do
    grep -qE "serve.sh: listening on http://|not ready after" "$d/out.txt" 2>/dev/null && break
    sleep 1; i=$((i + 1))
  done
}
run slow 40 STUB_DELAY=9 READY_EVERY=2 READY_TIMEOUT=60
o=$T/slow/out.txt
if grep -q "serve.sh: listening on http://" "$o" && grep -q "still starting (.*limit 60s)" "$o"; then
  ok "slow start (9 s): progress lines, then ready ($(grep -c 'still starting' "$o") progress lines)"
else bad "slow start: $(grep -E 'still|listening|ERROR|not ready' "$o" | tail -n 4)"; fi
run never 30 STUB_DELAY=-1 READY_EVERY=2 READY_TIMEOUT=5
o=$T/never/out.txt
if grep -q "not ready after [0-9]*s (READY_TIMEOUT=5)" "$o" && ! grep -q "serve.sh: listening on" "$o"; then
  ok "never ready: clear READY_TIMEOUT message, no ready banner"
else bad "never ready: $(tail -n 4 "$o")"; fi
d=$T/bad; sandbox "$d"
if ( cd "$d" && READY_TIMEOUT=soon PORT=1 GGUF_HOME="$d" TOOLS="" LANGUAGE_MODE=off LLAMA_SERVER="$T/llama-server" sh scripts/serve.sh > "$d/out.txt" 2>&1 ); then
  bad "READY_TIMEOUT=soon accepted"
elif grep -q "READY_TIMEOUT must be seconds" "$d/out.txt"; then ok "READY_TIMEOUT=soon is refused"
else bad "READY_TIMEOUT=soon: $(tail -n 3 "$d/out.txt")"; fi
if grep -q 'while \[ "\$i" -le 600 \]' "$ROOT/start.sh" "$ROOT/scripts/serve.sh"; then bad "a fixed 600 s readiness loop is left"
else ok "no fixed 600 s readiness loop in start.sh / serve.sh"; fi
[ "$fails" = 0 ] && echo "all ready-wait tests passed" || { echo "$fails failure(s)"; exit 1; }
