#!/usr/bin/env python3
"""Cockpit auth: no key prompt in the page; the cockpit reads the instance key itself and attaches
it server-side to llama-server calls; loopback needs no browser auth; a non-loopback bind needs the
cockpit's own session token (printed once as a URL), never the API key; the key is never printed."""
import http.server, json, os, shutil, socket, subprocess, sys, tempfile, threading, time, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEY = "sk-test-" + os.urandom(8).hex()
fails = []
def ok(c, m): print(("ok   " if c else "FAIL ") + m); (None if c else fails.append(m))
def free():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

seen = []
class Fake(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        seen.append(self.headers.get("Authorization"))
        good = self.headers.get("Authorization") == "Bearer " + KEY
        b = json.dumps({"data": [{"id": "general", "status": {"value": "loaded"}}]} if good else {"error": "unauthorized"}).encode()
        self.send_response(200 if good else 401); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

T = tempfile.mkdtemp()
try:
    d = os.path.join(T, "co"); os.makedirs(os.path.join(d, ".cache"))
    shutil.copytree(os.path.join(ROOT, "scripts"), os.path.join(d, "scripts"))
    lp = free(); srv = http.server.HTTPServer(("127.0.0.1", lp), Fake); threading.Thread(target=srv.serve_forever, daemon=True).start()
    open(os.path.join(d, ".cache", "serve.ready"), "w").write("%d 1\n" % lp)
    kf = os.path.join(T, "api-keys"); open(kf, "w").write(KEY + "\n")
    open(os.path.join(d, ".cache", "logs.manifest"), "w").write("router\t%s\n" % os.path.join(d, ".cache", "server.log"))
    open(os.path.join(d, ".cache", "server.log"), "w").write("main: hello\n")

    def start(env, *args):
        p = free(); log = open(os.path.join(T, "cockpit-%d.log" % p), "w+")
        e = dict(os.environ, COCKPIT_PORT=str(p), **env); e.pop("LLAMA_API_KEY", None)
        pr = subprocess.Popen([sys.executable, os.path.join(d, "scripts", "cockpit.py"), *args], env=e, stdout=log, stderr=log)
        for _ in range(50):
            try: urllib.request.urlopen("http://127.0.0.1:%d/" % p, timeout=1); break
            except Exception: time.sleep(0.1)
        return pr, p, log
    def get(p, path, h=None):
        try:
            with urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:%d%s" % (p, path), headers=h or {}), timeout=5) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    pr, p, log = start({"API_KEY_FILE": kf})
    html = get(p, "/")[1]
    ok("prompt(" not in html and "API key (" not in html, "page has no API key prompt")
    ok(get(p, "/logs")[0] == 200, "loopback: logs load with no key and no token")
    c, b = get(p, "/api/models")
    ok(c == 200 and "general" in b and seen and seen[-1] == "Bearer " + KEY, "proxy attaches the instance key server-side (llama-server answers 200)")
    ok(KEY not in b and KEY not in get(p, "/session")[1], "key never sent to the browser")
    pr.terminate(); pr.wait(); log.seek(0); ok(KEY not in log.read(), "key never printed by the cockpit")

    pr, p, log = start({"API_KEY_FILE": os.path.join(T, "missing")})
    c, b = get(p, "/api/models")
    ok(c == 503 and json.loads(b).get("need_key"), "no key file: clear message and a manual-key fallback")
    ok(get(p, "/api/models", {"X-Llama-Key": KEY})[0] == 200, "manual key override works when the file is missing")
    pr.terminate(); pr.wait()

    pr, p, log = start({"API_KEY_FILE": kf}, "--host", "0.0.0.0")
    time.sleep(0.3); log.seek(0); out = log.read()
    tok = out.split("?token=")[1].split()[0] if "?token=" in out else ""
    ok(bool(tok) and KEY not in out and tok != KEY, "non-loopback: prints a URL with a session token (not the API key)")
    ok(get(p, "/logs")[0] == 401 and get(p, "/api/models")[0] == 401, "non-loopback: no token, no access")
    ok(get(p, "/logs?token=" + tok)[0] == 200 and get(p, "/api/models", {"Authorization": "Bearer " + tok})[0] == 200, "non-loopback: token opens logs and proxy")
    ok(get(p, "/logs", {"Authorization": "Bearer " + KEY})[0] == 401, "non-loopback: the API key itself is not a cockpit token")
    pr.terminate(); pr.wait()
    ok(KEY not in open(os.path.join(d, ".cache", "cockpit.url")).read(), "cockpit.url has no key or token")
finally:
    shutil.rmtree(T, ignore_errors=True)
print("all cockpit auth tests passed" if not fails else "%d failure(s)" % len(fails)); sys.exit(1 if fails else 0)
