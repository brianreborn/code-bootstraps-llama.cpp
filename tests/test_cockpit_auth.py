#!/usr/bin/env python3
"""Cockpit auth: no key prompt in the page; the cockpit reads the instance key itself and attaches
it server-side to llama-server calls; every request needs the cockpit's own session token (on
loopback the served page carries it; a non-loopback bind prints it once as a URL), never the API key;
non-local Host/Origin headers are refused; POST must be JSON; the key is never printed."""
import http.server, json, os, re, stat, shutil, socket, subprocess, sys, tempfile, threading, time, urllib.request, urllib.error

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
    kf = os.path.join(T, "api-keys"); open(kf, "w").write("# familia instance key (one per line), see docs/api-key-design.md\n" + KEY + "\n")  # real files start with a comment
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
    def get(p, path, h=None, data=None):
        try:
            with urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:%d%s" % (p, path), headers=h or {}, data=data), timeout=5) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    def page_token(html):
        m = re.search(r'name="cockpit-token" content="([^"]+)"', html)
        return m.group(1) if m else ""

    pr, p, log = start({"API_KEY_FILE": kf})
    html = get(p, "/")[1]
    ok("prompt(" not in html and "API key (" not in html, "page has no API key prompt")
    lt = page_token(html); A = {"Authorization": "Bearer " + lt}
    ok(bool(lt) and lt != KEY, "loopback: the served page carries a session token (not the API key)")
    ok(get(p, "/logs")[0] == 401 and get(p, "/api/models")[0] == 401, "loopback: no token, no access (H3)")
    ok(get(p, "/logs", A)[0] == 200, "loopback: logs load with the page's token")
    ok(get(p, "/", {"Host": "evil.example:%d" % p})[0] == 403, "foreign Host on / is refused (no token leak via DNS rebinding)")
    ok(get(p, "/logs", dict(A, Host="evil.example:%d" % p))[0] == 403, "foreign Host is refused even with the token")
    ok(get(p, "/logs", dict(A, Host="localhost:%d" % p))[0] == 200, "localhost Host is accepted")
    ok(get(p, "/logs", dict(A, Host="127.0.0.1:1"))[0] == 403, "local Host with another port is refused")
    ok(get(p, "/logs", dict(A, Origin="https://evil.example"))[0] == 403, "foreign Origin is refused")
    ok(get(p, "/logs", dict(A, Origin="http://127.0.0.1:%d" % p))[0] == 200, "same Origin is accepted")
    ok(get(p, "/recover", dict(A, **{"Content-Type": "text/plain"}), b"x")[0] == 415, "POST without JSON content type is refused")
    ok(get(p, "/recover", {"Content-Type": "application/json"}, b"{}")[0] == 401, "POST without token is refused")
    tf = os.path.join(d, ".cache", "cockpit.token-url")
    ok(os.path.exists(tf) and stat.S_IMODE(os.stat(tf).st_mode) == 0o600 and lt in open(tf).read(), "token URL file is 0600")
    c, b = get(p, "/api/models", A)
    ok(c == 200 and "general" in b and seen and seen[-1] == "Bearer " + KEY, "proxy attaches the instance key server-side (llama-server answers 200)")
    ok(KEY not in b and KEY not in get(p, "/session")[1], "key never sent to the browser")
    pr.terminate(); pr.wait(); log.seek(0); ok(KEY not in log.read(), "key never printed by the cockpit")

    pr, p, log = start({"API_KEY_FILE": os.path.join(T, "missing")})
    A = {"Authorization": "Bearer " + page_token(get(p, "/")[1])}
    c, b = get(p, "/api/models", A)
    ok(c == 503 and json.loads(b).get("need_key"), "no key file: clear message and a manual-key fallback")
    ok(get(p, "/api/models", dict(A, **{"X-Llama-Key": KEY}))[0] == 200, "manual key override works when the file is missing")
    pr.terminate(); pr.wait()

    pr, p, log = start({"API_KEY_FILE": kf}, "--host", "0.0.0.0")
    time.sleep(0.3); log.seek(0); out = log.read()
    tok = out.split("?token=")[1].split()[0] if "?token=" in out else ""
    ok(bool(tok) and KEY not in out and tok != KEY, "non-loopback: prints a URL with a session token (not the API key)")
    ok(get(p, "/logs")[0] == 401 and get(p, "/api/models")[0] == 401, "non-loopback: no token, no access")
    ok(not page_token(get(p, "/")[1]), "non-loopback: the page does not carry the token")
    ok(get(p, "/logs?token=" + tok)[0] == 200 and get(p, "/api/models", {"Authorization": "Bearer " + tok})[0] == 200, "non-loopback: token opens logs and proxy")
    ok(get(p, "/logs", {"Authorization": "Bearer " + KEY})[0] == 401, "non-loopback: the API key itself is not a cockpit token")
    pr.terminate(); pr.wait()
    cu = open(os.path.join(d, ".cache", "cockpit.url")).read()
    ok(KEY not in cu and "token=" not in cu, "cockpit.url has no key or token")
finally:
    shutil.rmtree(T, ignore_errors=True)
print("all cockpit auth tests passed" if not fails else "%d failure(s)" % len(fails)); sys.exit(1 if fails else 0)
