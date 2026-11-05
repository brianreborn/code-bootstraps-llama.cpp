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

# parse_ifconfig: sample FreeBSD `ifconfig -a` output
sys.path.insert(0, os.path.join(ROOT, "scripts", "lib")); sys.path.insert(0, os.path.join(ROOT, "scripts"))
import importlib.util
_sp = importlib.util.spec_from_file_location("cockpit_mod", os.path.join(ROOT, "scripts", "cockpit.py"))
_cm = importlib.util.module_from_spec(_sp); _sp.loader.exec_module(_cm)
FREEBSD = """em0: flags=8863<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
\toptions=481009b<RXCSUM,TXCSUM,VLAN_MTU,VLAN_HWTAGGING,VLAN_HWCSUM,VLAN_HWFILTER,NOMAP>
\tether 08:00:27:aa:bb:cc
\tinet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255
\tinet6 fe80::a00:27ff:feaa:bbcc%em0 prefixlen 64 scopeid 0x1
\tinet6 2001:db8:1::20 prefixlen 64
\tmedia: Ethernet autoselect (1000baseT <full-duplex>)
\tstatus: active
\tnd6 options=23<PERFORMNUD,ACCEPT_RTADV,AUTO_LINKLOCAL>
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> metric 0 mtu 16384
\tinet6 ::1 prefixlen 128
\tinet 127.0.0.1 netmask 0xff000000
"""
ok(_cm._hostname("127.0.0.1", 80) == "127.0.0.1" and _cm._hostname("h", 443, "https") == "h" and _cm._hostname("h", 9933) == "" and _cm._hostname("[::1]:9933", 9933) == "::1", "_hostname: missing port is the scheme default")
ok(_cm.redact('"GET /logs?token=abc-_1&x=1 HTTP/1.1"') == '"GET /logs?token=REDACTED&x=1 HTTP/1.1"', "redact() hides the token")
ok(_cm.redact("/x?%74oken=s1&%74%6F%6B%65%6E=s2&notoken=k&a=1") == "/x?%74oken=REDACTED&%74%6F%6B%65%6E=REDACTED&notoken=k&a=1", "redact() catches percent-encoded token names")
got = _cm.parse_ifconfig(FREEBSD)
ok(got == ["192.168.1.20", "fe80::a00:27ff:feaa:bbcc%em0", "2001:db8:1::20", "::1", "127.0.0.1"], "parse_ifconfig reads FreeBSD inet/inet6 lines: %s" % got)
ok(_cm.parse_ifconfig("eth0 Link encap:Ethernet\n  inet addr:10.0.0.5  Bcast:10.0.0.255\n") == ["10.0.0.5"], "parse_ifconfig reads old Linux net-tools format")
ok(_cm.parse_ifconfig("") == [], "parse_ifconfig: no output, no addresses")

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

    def file_token():
        t = open(os.path.join(d, ".cache", "cockpit.token-url")).read()
        return t.split("?token=")[1].split()[0] if "?token=" in t else ""
    def page_token(html):
        m = re.search(r'name="cockpit-token" content="([^"]+)"', html)
        return m.group(1) if m else ""

    tf0 = os.path.join(d, ".cache", "cockpit.token-url")
    open(tf0 + ".tmp", "w").write("stale\n"); os.chmod(tf0 + ".tmp", 0o644)   # leftover 0644 .tmp
    pr, p, log = start({"API_KEY_FILE": kf})
    ok(stat.S_IMODE(os.stat(tf0).st_mode) == 0o600 and not os.path.exists(tf0 + ".tmp") and "stale" not in open(tf0).read(),
       "a leftover 0644 .tmp ends up as a fresh 0600 token file")
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
    ok(get(p, "/logs", dict(A, Origin="null"))[0] == 403, "Origin: null is refused")
    ok(get(p, "/logs", dict(A, Origin="http://127.0.0.1"))[0] == 403, "Origin without a port means :80, not ours: refused")
    ok(get(p, "/logs", dict(A, Origin="https://127.0.0.1"))[0] == 403, "https Origin without a port means :443: refused")
    ok(get(p, "/logs", dict(A, Host="127.0.0.1"))[0] == 403, "Host without a port means :80, not ours: refused")
    ok(get(p, "/logs?token=" + lt)[0] == 200, "query-string token works")
    ok(get(p, "/logs?%74oken=" + lt)[0] == 200, "percent-encoded name ?%74oken= authenticates (parse_qs)")
    time.sleep(0.2); log.seek(0); ok(lt not in log.read() and "token=REDACTED" in open(log.name).read(), "token is redacted in cockpit.log after ?token= requests")
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
    tok = file_token()
    ok(bool(tok) and KEY not in out and tok != KEY, "non-loopback: a session token (not the API key) in cockpit.token-url")
    ok(tok not in out, "non-loopback: the token URL is not written to stderr/log")
    ok(get(p, "/logs")[0] == 401 and get(p, "/api/models")[0] == 401, "non-loopback: no token, no access")
    ok(not page_token(get(p, "/")[1]), "non-loopback: the page does not carry the token")
    ok(get(p, "/logs?token=" + tok)[0] == 200 and get(p, "/api/models", {"Authorization": "Bearer " + tok})[0] == 200, "non-loopback: token opens logs and proxy")
    ok(get(p, "/logs", {"Authorization": "Bearer " + KEY})[0] == 401, "non-loopback: the API key itself is not a cockpit token")
    pr.terminate(); pr.wait()

    # LAN Host: a non-loopback bind accepts this machine's own address in Host/Origin (token still required)
    def lan_ip():
        try:
            u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.connect(("192.0.2.1", 9)); a = u.getsockname()[0]; u.close()
            return a if not a.startswith("127.") else ""
        except OSError:
            return ""
    ip = lan_ip()
    if ip:
        pr, p, log = start({"API_KEY_FILE": kf}, "--host", "0.0.0.0")
        time.sleep(0.3); log.seek(0); out = log.read()
        tok = file_token()
        B = {"Authorization": "Bearer " + tok, "Host": "%s:%d" % (ip, p)}
        ok(get(p, "/logs", B)[0] == 200, "0.0.0.0 bind: Host = own LAN IP %s is accepted with the token" % ip)
        ok(get(p, "/logs", dict(B, Origin="http://%s:%d" % (ip, p)))[0] == 200, "0.0.0.0 bind: same-origin LAN page is accepted")
        ok(get(p, "/logs", {"Host": "%s:%d" % (ip, p)})[0] == 401, "0.0.0.0 bind: own LAN IP still needs the token")
        ok(get(p, "/logs", dict(B, Host="evil.example:%d" % p))[0] == 403, "0.0.0.0 bind: foreign Host still refused")
        ok(get(p, "/logs", dict(B, Host="192.0.2.77:%d" % p))[0] == 403, "0.0.0.0 bind: an IP that is not ours is refused")
        ok(get(p, "/logs", dict(B, Origin="http://evil.example"))[0] == 403, "0.0.0.0 bind: foreign Origin still refused")
        pr.terminate(); pr.wait()
        pr, p, log = start({"API_KEY_FILE": kf, "COCKPIT_ALLOWED_HOSTS": "mybox.lan,*,evil.example:80"}, "--host", "0.0.0.0")
        time.sleep(0.3); log.seek(0); out = log.read()
        tok = file_token()
        ok(get(p, "/logs", {"Authorization": "Bearer " + tok, "Host": "mybox.lan:%d" % p})[0] == 200, "COCKPIT_ALLOWED_HOSTS adds a LAN host name")
        log.seek(0); w = log.read()
        ok("'*' ignored" in w and "'evil.example:80' ignored" in w, "COCKPIT_ALLOWED_HOSTS: '*' and host:port entries are warned about")
        ok(get(p, "/logs", {"Authorization": "Bearer " + tok, "Host": "anything.example:%d" % p})[0] == 403 and
           get(p, "/logs", {"Authorization": "Bearer " + tok, "Host": "evil.example:%d" % p})[0] == 403, "ignored entries grant nothing")
        pr.terminate(); pr.wait()
        pr, p, log = start({"API_KEY_FILE": kf}, "--host", ip)
        for _ in range(50):
            try: urllib.request.urlopen("http://%s:%d/" % (ip, p), timeout=1); break
            except Exception: time.sleep(0.1)
        time.sleep(0.3); log.seek(0); out = log.read()
        tok = file_token()
        try:
            with urllib.request.urlopen(urllib.request.Request("http://%s:%d/logs" % (ip, p), headers={"Authorization": "Bearer " + tok}), timeout=5) as r: c = r.status
        except urllib.error.HTTPError as e: c = e.code
        ok(c == 200, "explicit LAN bind %s: Host = bind address is accepted" % ip)
        pr.terminate(); pr.wait()
    else:
        print("skip LAN Host tests: no non-loopback IPv4 address")
    cu = open(os.path.join(d, ".cache", "cockpit.url")).read()
    ok(KEY not in cu and "token=" not in cu, "cockpit.url has no key or token")
finally:
    shutil.rmtree(T, ignore_errors=True)
print("all cockpit auth tests passed" if not fails else "%d failure(s)" % len(fails)); sys.exit(1 if fails else 0)
