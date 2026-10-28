#!/bin/sh
# Startup UX: llama-server's log streams live while it starts (STARTUP_LOG=live), a stuck
# start can be changed and retried without restarting everything (terminal menu with a TTY,
# .cache/recover.request from the cockpit; whitelisted keys only), and a role whose model is
# still downloading (MODELS_PENDING_OK=1, start.sh MODELS_BG) is served and hot-added.
#   sh tests/test_startup_recover.sh
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
open(log, "a").write("stub: loading model\n")
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
  [ "${NO_SANDBOX:-0}" = 1 ] || sandbox "$d"; NO_SANDBOX=0
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  ( cd "$d" && exec env "$@" PORT="$port" GGUF_HOME="$d" TOOLS="" MCP_CONFIG="" TOOLS_RUNTIME=host LANGUAGE_MODE=off \
      LLAMA_SERVER="$T/llama-server" setsid sh scripts/serve.sh > "$d/out.txt" 2>&1 ) &
  echo $! >> "$T/pids"
  i=0
  while [ "$i" -lt "$lim" ]; do
    grep -qE "${WAITFOR:-serve.sh: listening on http://|not ready after}" "$d/out.txt" 2>/dev/null && break
    sleep 1; i=$((i + 1))
  done
}

wait_for() { i=0; while [ "$i" -lt "$2" ]; do grep -q "$1" "$3" 2>/dev/null && return 0; sleep 1; i=$((i + 1)); done; return 1; }

run live 30 STUB_DELAY=3 READY_EVERY=1
o=$T/live/out.txt
if grep -q "^  | stub: loading model" "$o" && grep -q "serve.sh: listening on" "$o"; then ok "llama-server log streams live while it starts"
else bad "live log: $(tail -n 5 "$o")"; fi
run quiet 30 STUB_DELAY=1 STARTUP_LOG=quiet
if ! grep -q "^  | " "$T/quiet/out.txt"; then ok "STARTUP_LOG=quiet keeps only progress lines"; else bad "quiet still streams"; fi

run req 30 STUB_DELAY=-1 READY_EVERY=1 READY_TIMEOUT=3
o=$T/req/out.txt
printf 'SIZING=distributed\nCTX=abc\nLLAMA_SERVER=/bin/sh\nACTION=retry\n' > "$T/req/.cache/recover.request"
if wait_for "restarting llama-server with: SIZING=distributed" 20 "$o" && wait_for "sizing=distributed" 20 "$o" \
   && grep -q "ignored 'CTX'" "$o" && grep -q "ignored 'LLAMA_SERVER'" "$o"; then
  ok "cockpit request: whitelisted change applied, llama-server restarted, bad values ignored"
else bad "cockpit request: $(grep 'serve.sh' "$o" | tail -n 5)"; fi

# terminal menu through a pty: s (SIZING) -> 2 (distributed) -> g (retry)
d=$T/tty; sandbox "$d"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
cat > "$T/drive_tty.py" <<'PY'
import os, pty, select, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp("sh", ["sh", "scripts/serve.sh"])
buf, steps, t0 = b"", [b"s\n", b"2\n", b"g\n"], time.time()
while time.time() - t0 < 40:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        try: chunk = os.read(fd, 4096)
        except OSError: break
        buf += chunk; sys.stdout.buffer.write(chunk); sys.stdout.flush()
    if steps and (buf.endswith(b"choice: ") or buf.rstrip().endswith(b"]:")):
        time.sleep(0.2); os.write(fd, steps.pop(0)); buf = b""
    if not steps and b"sizing=distributed" in buf:
        break
os.kill(pid, 15); time.sleep(1)
PY
( cd "$d" && env STUB_DELAY=-1 READY_TIMEOUT=3 READY_EVERY=1 PORT="$port" GGUF_HOME="$d" TOOLS="" MCP_CONFIG="" TOOLS_RUNTIME=host \
    LANGUAGE_MODE=off LLAMA_SERVER="$T/llama-server" python3 "$T/drive_tty.py" > "$d/out.txt" 2>&1 ) || true
o=$d/out.txt
if grep -q "startup is slow" "$o" && grep -q "restarting llama-server with: SIZING=distributed" "$o" && grep -q "sizing=distributed" "$o"; then
  ok "terminal menu: SIZING changed and llama-server retried in place"
else bad "terminal menu: $(tr -d '\r' < "$o" | grep serve.sh | tail -n 5)"; fi
pkill -f "$T/llama-server" 2>/dev/null || true

# background downloads: decision model missing
dec=$(awk -F '\t' '$1 == "decision" { print $2 }' "$T/req/.cache/default-rows")
d=$T/nodl; sandbox "$d"; rm -f "$d/models/decision/$dec"
( cd "$d" && PORT=1 GGUF_HOME="$d" TOOLS="" LANGUAGE_MODE=off LLAMA_SERVER="$T/llama-server" sh scripts/serve.sh > "$d/out.txt" 2>&1 ) || true
if grep -q "no model for the decision role" "$d/out.txt"; then ok "missing decision model without MODELS_PENDING_OK still stops"; else bad "nodl: $(tail -n 2 "$d/out.txt")"; fi
d=$T/bg; mkdir -p "$d/.cache"; echo "fetch-models: 12% Laya" > "$d/.cache/fetch-models.log"
sandbox "$d"; rm -f "$d/models/decision/$dec"; NO_SANDBOX=1
run bg 30 MODELS_PENDING_OK=1 STUB_DELAY=1
o=$d/out.txt
echo "placeholder $dec" > "$d/models/decision/$dec"
if grep -q "decision role.s model $dec is still downloading" "$o" && wait_for "serve.sh: listening on" 15 "$o" \
   && wait_for "hot-add: the decision role's model $dec finished downloading" 15 "$o"; then
  ok "background download: chat starts without the decision model, which hot-adds when it lands"
else bad "background download: $(grep serve.sh "$o" | tail -n 5)"; fi

if python3 - "$ROOT" <<'PY'
import sys; sys.path.insert(0, sys.argv[1] + "/scripts"); import cockpit as c
assert c.recover_lines({"SIZING": "distributed", "ACTION": "retry"}) == ["SIZING=distributed", "ACTION=retry"]
for bad in ({"SIZING": "x"}, {"CTX": "1;rm"}, {"LLAMA_API_KEY": "k"}, {"MODEL_GENERAL": "a\nB=c.gguf"}):
    try: c.recover_lines(bad); raise SystemExit("accepted %r" % bad)
    except ValueError: pass
PY
then ok "cockpit /recover accepts only whitelisted keys and plain values"; else bad "cockpit whitelist"; fi
grep -q 'MODELS_BG' "$ROOT/start.sh" && ok "start.sh downloads the other roles in the background (MODELS_BG)" || bad "start.sh MODELS_BG"
[ "$fails" = 0 ] && echo "all startup-recover tests passed" || { echo "$fails failure(s)"; exit 1; }
