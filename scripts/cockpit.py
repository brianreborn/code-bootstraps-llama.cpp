#!/usr/bin/env python3
"""Cockpit: live tail of the REAL log files, one panel per log. Stdlib only.

  python3 scripts/cockpit.py [--port 9933] [--manifest FILE ...]

Logs come from .cache/logs.manifest (written by scripts/serve.sh: router with each child's
"[pid name:port]" lines, embed, recover, watchdog, serve) plus any FAMILIA_LOG_MANIFEST files
(colon separated; familia lists its components there). Each line: name<TAB>path.

Every panel is on by default (long lines truncated in the view, never in the file); turn panels
off with the switches. The heat map is a synthetic extra (lines/second per log), off by default.
The header shows the per-role reasoning toggle (GET /reasoning, display only: set it with
REASONING / REASONING_GENERAL / REASONING_CODER and restart serve).

No key entry in the browser. The cockpit reads the instance API key itself (the same files as
serve.sh: API_KEY_FILE, the per-instance api-keys file, .secrets/api-keys) and attaches it server-side
when it proxies to llama-server (/api/...). The key never reaches the page and is never printed.
Every request except GET / needs the cockpit's own session token (never the API key), generated
at startup. Bound to loopback (the default), GET / hands the token to the page it serves, and
.cache/cockpit.token-url (mode 0600) holds the full URL. With --host on a non-loopback address,
GET / does not carry the token: open the ?token= URL shown once on the terminal (never on stderr or
in logs) or read it from .cache/cockpit.token-url. Requests whose Host header is
not local (127.0.0.1, localhost, ::1, the bind address, this machine's own interface addresses when
bound non-loopback, or COCKPIT_ALLOWED_HOSTS, comma separated, e.g. a LAN host name)
or whose Origin header is not one of those are refused (DNS rebinding / cross-site requests).
POST bodies must be application/json.
The accessible no-JavaScript settings panel stays scripts/panel.py; it links here.
"""
import argparse, hmac, json, os, re, socket, sys, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "lib"))
HTML = os.path.join(ROOT, "scripts", "cockpit", "index.html")


def logs(manifests):
    out = {}
    for m in manifests:
        try:
            for line in open(m):
                if "\t" in line:
                    n, p = line.rstrip("\n").split("\t", 1)
                    out.setdefault(n, p)
        except OSError:
            pass
    return out


def reasoning():
    """Per-role reasoning toggle as the router got it (effective preset; else the committed one).
    Display only: it changes on the next serve start (REASONING / REASONING_GENERAL / REASONING_CODER)."""
    out = {"general": "off", "coder": "off", "source": None, "sizing": "monolithic",
           "set": "REASONING_GENERAL=on|off|auto REASONING_CODER=on|off|auto scripts/serve.sh (or REASONING=... for both)"}
    try:
        out["sizing"] = open(os.path.join(ROOT, ".cache", "sizing")).read().strip() or out["sizing"]
    except OSError:
        pass
    for f in (os.path.join(ROOT, ".cache", "models-preset.effective.ini"), os.path.join(ROOT, "config", "models-preset.ini")):
        try:
            sec = None
            for line in open(f):
                line = line.strip()
                if line.startswith("["):
                    sec = line[1:line.find("]")]
                elif sec in ("general", "coder") and line.split("=", 1)[0].strip() == "reasoning":
                    out[sec] = line.split("=", 1)[1].strip()
            out["source"] = f
            return out
        except OSError:
            pass
    return out


RECOVER_KEYS = {
    "SIZING": re.compile(r"^(monolithic|distributed)$"),
    "REASONING": re.compile(r"^(on|off|auto)$"),
    "PROFILE": re.compile(r"^(lowram|moderate|default)$"),
    "CTX": re.compile(r"^[0-9]{1,7}$"),
    "READY_TIMEOUT": re.compile(r"^[0-9]{1,6}$"),
    "GPU_LAYERS": re.compile(r"^[0-9]{1,4}$"),
    "MODEL_GENERAL": re.compile(r"^[^\n=]+\.gguf$"),
    "MODEL_CODER": re.compile(r"^[^\n=]+\.gguf$"),
    "MODEL_DECISION": re.compile(r"^[^\n=]+\.gguf$"),
    "LLAMA_SERVER": re.compile(r"^[^\n=]+/llama-server$"),
    "ACTION": re.compile(r"^(retry|wait)$"),
}


def recover_lines(req):
    if not isinstance(req, dict):
        raise ValueError("expected a JSON object")
    out = []
    for k, v in req.items():
        v = str(v)
        if k not in RECOVER_KEYS or not RECOVER_KEYS[k].match(v):
            raise ValueError("%s: not an allowed setting or value" % k)
        out.append("%s=%s" % (k, v))
    return out


def startup():
    c = os.path.join(ROOT, ".cache")
    def rd(n):
        try:
            return open(os.path.join(c, n)).read().strip()
        except OSError:
            return ""
    dl = rd("fetch-models.log").replace("\r", "\n").splitlines()
    return {"ready": bool(rd("serve.ready")), "stuck": rd("serve.stuck"),
            "pending": [l.split("\t")[:2] for l in rd("pending-models").splitlines() if l],
            "download": dl[-1] if dl else "", "sizing": rd("sizing")}


def ready_port():
    try:
        return int(open(os.path.join(ROOT, ".cache", "serve.ready")).read().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def instance_key(port=None):
    """first key of the instance key file (never printed or logged)"""
    try:
        from snap import key_file_candidates
        files = key_file_candidates(port)
    except Exception:
        files = [os.path.join(ROOT, ".secrets", "api-keys")]
    for f in files:
        try:
            for l in open(f):
                if l.strip() and not l.strip().startswith("#"):   # the file starts with a comment header
                    return l.strip()
        except OSError:
            pass
    return os.environ.get("LLAMA_API_KEY", "").split(",")[0].strip() or None


from loopback import is_loopback  # noqa: E402  (scripts/lib on sys.path above)


def _hostname(netloc, our_port, scheme="http"):
    """'host:port' / '[v6]:port' -> lower-case host; a port other than ours makes it unmatchable.
    No port means the scheme's default (http 80, https 443), as a browser means it."""
    netloc = netloc.strip().lower()
    if netloc.startswith("["):
        host, _, rest = netloc[1:].partition("]")
        port = rest[1:] if rest.startswith(":") else ""
    elif netloc.count(":") == 1:
        host, port = netloc.split(":")
    else:
        host, port = netloc, ""
    if not port:
        port = "443" if scheme == "https" else "80"
    if our_port and port != str(our_port):
        return ""
    return host


def redact(text):
    """never log the session token (request lines carry ?token=...)"""
    # the name may be percent-encoded (?%74oken=...): parse_qs decodes it, so decode before matching
    def one(m):
        return m.group(1) + "REDACTED" if urllib.parse.unquote(m.group(1)).lower() == "token=" else m.group(0)
    return re.sub(r"((?:[A-Za-z0-9]|%[0-9A-Fa-f]{2})+=)[^&\s]*", one, text)


class H(BaseHTTPRequestHandler):
    manifests = []
    token = None          # cockpit session token; always set by main()
    local_bind = True     # bound to a loopback address
    allowed_hosts = set() # lower-case host names (no port) accepted in Host/Origin
    port = 0

    def log_message(self, *a):
        line = redact(a[0] % a[1:])
        if self.token:
            line = line.replace(self.token, "REDACTED")   # whatever spelling carried it
        sys.stderr.write("cockpit: %s\n" % line)

    def host_ok(self):
        """Host must name this cockpit; Origin, when a browser sends one, must too."""
        host = self.headers.get("Host", "")
        if not host or _hostname(host, self.port) not in self.allowed_hosts:
            return False
        origin = self.headers.get("Origin")
        if origin is None:
            return True
        o = urllib.parse.urlparse(origin)
        return o.scheme in ("http", "https") and bool(o.netloc) and _hostname(o.netloc, self.port, o.scheme) in self.allowed_hosts

    def refuse(self, code, msg):
        self.send_response(code); self.send_header("Content-Length", str(len(msg))); self.end_headers(); self.wfile.write(msg)

    def authed(self, q):
        if not self.token:
            return False  # fail closed: no token configured means no access
        got = q.get("token", [""])[0]
        h = self.headers.get("Authorization", "")
        if h.startswith("Bearer "):
            got = h[7:]
        return bool(got) and hmac.compare_digest(got, self.token)

    def proxy(self, path, method="GET", body=None):
        """forward to the local llama-server with the instance key attached here, server-side"""
        import urllib.request, urllib.error
        port = ready_port()
        if not port:
            return 503, {"error": "llama-server is not ready yet (.cache/serve.ready missing)"}
        key = instance_key(port) or self.headers.get("X-Llama-Key") or None
        if not key:
            return 503, {"error": "no instance key file found (API_KEY_FILE, the per-instance api-keys file, "
                                  ".secrets/api-keys): start the server once with start.sh, or enter the key below",
                         "need_key": True}
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path), data=body, method=method,
                                     headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            return e.code, {"error": "llama-server answered HTTP %d" % e.code}
        except (OSError, ValueError) as e:
            return 502, {"error": "llama-server unreachable: %s" % type(e).__name__}

    def json_out(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if not self.host_ok():
            return self.refuse(403, b"cockpit: Host or Origin is not local\n")
        if u.path == "/":
            body = open(HTML, "rb").read()
            if self.local_bind:  # same-origin page only (Host checked above); cross-site pages cannot read it
                body = body.replace(b"<meta charset=\"utf-8\">", b"<meta charset=\"utf-8\"><meta name=\"cockpit-token\" content=\"%s\">" % self.token.encode(), 1)
            self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        if not self.authed(q):
            self.send_response(401); self.end_headers(); self.wfile.write(b"API key required\n"); return
        if u.path == "/session":
            port = ready_port()
            return self.json_out(200, {"auth": "token" if self.token else "loopback", "server_port": port,
                                       "key_file": bool(instance_key(port))})
        if u.path.startswith("/api/"):
            sub = u.path[4:]
            if sub not in ("/models", "/health", "/v1/models", "/props"):
                return self.json_out(404, {"error": "not proxied"})
            return self.json_out(*self.proxy(sub))
        L = logs(self.manifests)
        if u.path == "/logs":
            body = json.dumps(L).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body); return
        if u.path == "/reasoning":
            body = json.dumps(reasoning()).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body); return
        if u.path == "/startup":
            body = json.dumps(startup()).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body); return
        if u.path == "/stream":
            path = L.get(q.get("log", [""])[0])
            if not path:
                self.send_response(404); self.end_headers(); return
            self.send_response(200); self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache"); self.end_headers()
            self.tail(path); return
        self.send_response(404); self.end_headers()

    def do_POST(self):
        # /recover: startup recovery from the cockpit. Writes .cache/recover.request (KEY=VALUE);
        # serve.sh re-checks every key and value against its own whitelist before using it.
        u = urllib.parse.urlparse(self.path)
        if not self.host_ok():
            return self.refuse(403, b"cockpit: Host or Origin is not local\n")
        if self.headers.get("Content-Type", "").split(";")[0].strip().lower() != "application/json":
            return self.refuse(415, b"cockpit: POST needs Content-Type: application/json\n")
        if not self.authed(urllib.parse.parse_qs(u.query)):
            self.send_response(401); self.end_headers(); self.wfile.write(b"cockpit token required\n"); return
        if u.path != "/recover":
            self.send_response(404); self.end_headers(); return
        try:
            req = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length", 0)), 65536)) or b"{}")
            lines = recover_lines(req)
        except (ValueError, TypeError) as e:
            self.send_response(400); self.end_headers(); self.wfile.write(("bad request: %s\n" % e).encode()); return
        path = os.path.join(ROOT, ".cache", "recover.request")
        with open(path + ".tmp", "w") as f:
            f.write("".join(l + "\n" for l in lines))
        os.replace(path + ".tmp", path)
        body = json.dumps({"queued": lines}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)

    def send(self, text):
        self.wfile.write(("data: " + json.dumps(text) + "\n\n").encode()); self.wfile.flush()

    def tail(self, path, back=200):
        pos, ino = 0, None
        try:
            with open(path, "rb") as f:
                lines = f.read().splitlines()[-back:]
                pos = f.tell(); ino = os.fstat(f.fileno()).st_ino
            for l in lines:
                self.send(l.decode("utf-8", "replace"))
        except OSError:
            self.send("(cockpit: %s does not exist yet)" % path)
        try:
            while True:
                try:
                    st = os.stat(path)
                    if st.st_ino != ino or st.st_size < pos:
                        pos, ino = 0, st.st_ino
                    if st.st_size > pos:
                        with open(path, "rb") as f:
                            f.seek(pos); chunk = f.read(); pos = f.tell()
                        for l in chunk.splitlines():
                            self.send(l.decode("utf-8", "replace"))
                    else:
                        self.wfile.write(b": ping\n\n"); self.wfile.flush()
                except FileNotFoundError:
                    pass
                time.sleep(0.5)
        except (BrokenPipeError, ConnectionResetError):
            return


def parse_ifconfig(text):
    """inet / inet6 addresses from `ifconfig -a` output (BSD, macOS, Linux net-tools)."""
    out = []
    for line in text.splitlines():
        f = line.split()
        if len(f) >= 2 and f[0] in ("inet", "inet6"):
            x = f[1]
            if x.startswith("addr:"):    # old Linux net-tools: "inet addr:10.0.0.5"
                x = x[5:]
            out.append(x.split("/")[0])
    return out


def own_addresses(bind):
    """IP literals of this machine's interfaces (best effort, no DNS, no packets sent); a specific
    bind address only adds itself (done by the caller), the wildcard binds add every interface."""
    import ipaddress, subprocess
    if bind not in ("0.0.0.0", "::", ""):
        return set()
    out = set()
    def add(x):
        try:
            ip = ipaddress.ip_address(x.split("%")[0])
        except ValueError:
            return
        if not ip.is_unspecified and not ip.is_multicast and not ip.is_link_local:   # 169.254/16, fe80::/10
            out.add(str(ip))
    for fam, dst in ((socket.AF_INET, "192.0.2.1"), (socket.AF_INET6, "2001:db8::1")):
        try:   # route lookup only: UDP connect sends nothing
            s = socket.socket(fam, socket.SOCK_DGRAM); s.connect((dst, 9)); add(s.getsockname()[0]); s.close()
        except OSError:
            pass
    def run(cmd):
        try:
            return subprocess.run(cmd, capture_output=True, text=True, timeout=2).stdout
        except (OSError, subprocess.SubprocessError):
            return ""   # missing or hung tool: skip silently
    ipbin = next((b for b in ("/sbin/ip", "/usr/sbin/ip", "/bin/ip", "/usr/bin/ip") if os.access(b, os.X_OK)), None)
    for line in (run([ipbin, "-o", "addr", "show"]) if ipbin else "").splitlines():
        f = line.split()
        if len(f) > 3 and f[2] in ("inet", "inet6"):
            add(f[3].split("/")[0])
    ifc = next((b for b in ("/sbin/ifconfig", "/usr/sbin/ifconfig", "/bin/ifconfig", "/usr/bin/ifconfig") if os.access(b, os.X_OK)), None)
    for x in parse_ifconfig(run([ifc, "-a"]) if ifc else ""):   # FreeBSD, macOS, systems without ip
        add(x)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("COCKPIT_PORT", 9933)))
    ap.add_argument("--host", default=os.environ.get("COCKPIT_HOST", "127.0.0.1"))
    ap.add_argument("--manifest", action="append", default=[])
    a = ap.parse_args()
    H.manifests = a.manifest or [os.path.join(ROOT, ".cache", "logs.manifest")] + \
        [m for m in os.environ.get("FAMILIA_LOG_MANIFEST", "").split(":") if m]
    import secrets
    url = "http://%s:%d/" % ("[%s]" % a.host if ":" in a.host else a.host, a.port)
    H.port = a.port
    H.local_bind = is_loopback(a.host)
    H.allowed_hosts = {"127.0.0.1", "localhost", "::1"}
    for h in os.environ.get("COCKPIT_ALLOWED_HOSTS", "").split(","):
        h = h.strip().lower()
        if not h:
            continue
        if "*" in h or h.count(":") == 1 or "]:" in h:   # wildcards / host:port never match: warn, ignore
            print("cockpit: warning: COCKPIT_ALLOWED_HOSTS entry %r ignored (no wildcards or ports; "
                  "list bare host names or IPs)" % h, file=sys.stderr, flush=True)
            continue
        H.allowed_hosts.add(h.strip("[]"))
    if a.host not in ("0.0.0.0", "::", ""):
        H.allowed_hosts.add(a.host.lower().strip("[]"))   # an explicit bind address names this cockpit
    if not H.local_bind:
        # bound for the LAN: this machine's own interface addresses (IP literals only) name it too, so
        # http://<lan-ip>:port/ works; arbitrary names are never accepted (DNS rebinding)
        H.allowed_hosts |= own_addresses(a.host)
    H.token = secrets.token_urlsafe(24)   # the cockpit's own session token, not the API key
    token_url = url + "?token=" + H.token
    if not H.local_bind:
        url = token_url
    srv = ThreadingHTTPServer((a.host, a.port), H)
    url_file = os.path.join(ROOT, ".cache", "cockpit.url")
    try:
        os.makedirs(os.path.dirname(url_file), exist_ok=True)
        with open(url_file, "w") as f:
            f.write(url.split("?")[0] + "\n")   # never the token
        tf = os.path.join(ROOT, ".cache", "cockpit.token-url")
        try:
            os.unlink(tf + ".tmp")   # a leftover (maybe 0644, maybe a symlink) is never reused
        except FileNotFoundError:
            pass
        fd = os.open(tf + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(token_url + "\n")
        os.replace(tf + ".tmp", tf)
    except OSError:
        pass
    # stderr usually ends up in .cache/cockpit.log (start.sh): never put the token there
    print("cockpit: %s  logs from %s" % (url.split("?")[0], ", ".join(H.manifests)), file=sys.stderr, flush=True)
    if not H.local_bind:
        shown = False
        try:
            with open("/dev/tty", "w") as tty:
                tty.write("cockpit: open %s (session token, shown once)\n" % token_url); shown = True
        except OSError:
            pass
        print("cockpit: session token URL %s; also in %s (mode 0600)" % ("shown on the terminal" if shown else "not shown (no terminal)",
              os.path.join(ROOT, ".cache", "cockpit.token-url")), file=sys.stderr, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
