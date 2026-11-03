#!/bin/sh
# start.sh vs. a cockpit already on the port (review of #81): a current cockpit (X-Cockpit-Auth header)
# is reused; an older one (no header, still serves the MECHA COCKPIT page) gets a clear warning and the
# new cockpit goes to the next free port. Extracts port_busy/start_cockpit from start.sh; no python launch.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); fails=0
command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "skip: needs curl and python3"; exit 0; }
cleanup() { [ -n "${FP:-}" ] && kill "$FP" 2>/dev/null; rm -rf "$T"; }; trap cleanup EXIT
ok() { if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }
P=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
fake() { # $1 = header line or "", served on 127.0.0.1:$P
  python3 - "$P" "$1" <<'PY' &
import sys, http.server
p, hdr = int(sys.argv[1]), sys.argv[2]
class F(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        b = b"<title>FAMILIA // MECHA COCKPIT</title>"; self.send_response(200)
        if hdr: self.send_header(*hdr.split(": ", 1))
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(("127.0.0.1", p), F).serve_forever()
PY
  FP=$!; i=0; while [ $i -lt 50 ] && ! curl -s -o /dev/null "http://127.0.0.1:$P/"; do sleep 0.1; i=$((i + 1)); done
}
{ echo 'say() { echo "$*"; }'
  sed -n '/^port_busy() {/,/^}/p' "$ROOT/start.sh"
  sed -n '/^start_cockpit() {/,/^}/p' "$ROOT/start.sh" | sed 's#nohup python3 scripts/cockpit.py.*#echo "LAUNCH $cp_port"#'
} > "$T/f.sh"
run() { (cd "$T" && . ./f.sh && COCKPIT_PORT=$P start_cockpit) 2>&1; }

fake "X-Cockpit-Auth: token"; out=$(run); kill "$FP"; wait "$FP" 2>/dev/null; FP=
printf '%s\n' "$out" | grep -q "already running" && ! printf '%s\n' "$out" | grep -q LAUNCH; ok $? "current cockpit on the port is reused"

fake ""; out=$(run); kill "$FP"; wait "$FP" 2>/dev/null; FP=
printf '%s\n' "$out" | grep -q "older cockpit" && printf '%s\n' "$out" | grep -q "LAUNCH $((P + 1))"; ok $? "older cockpit: clear warning, new one on the next port"
if printf '%s\n' "$out" | grep -q "already running"; then r=1; else r=0; fi; ok $r "older cockpit is not reported as already running"

out=$(run); printf '%s\n' "$out" | grep -q "LAUNCH $P" && ! printf '%s\n' "$out" | grep -q "older"; ok $? "free port: launches there, no warning"
[ "$fails" = 0 ] && echo "all cockpit upgrade tests passed" || { echo "$fails failure(s)"; exit 1; }
