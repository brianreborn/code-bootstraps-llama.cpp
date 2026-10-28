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

Same API key as the server: the page asks once and sends it as ?key= on the SSE stream (EventSource
cannot set headers) and as "Authorization: Bearer" elsewhere. Binds 127.0.0.1 only.
The accessible no-JavaScript settings panel stays scripts/panel.py; it links here.
"""
import argparse, hmac, json, os, sys, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "lib"))
HTML = os.path.join(ROOT, "scripts", "cockpit", "index.html")


def api_keys():
    try:
        from snap import key_file_candidates  # same resolution as serve.sh
        files = key_file_candidates()
    except Exception:
        files = []
    keys = set()
    for f in files:
        try:
            with open(f) as fh:
                keys.update(l.strip() for l in fh if l.strip())
        except OSError:
            pass
    if os.environ.get("LLAMA_API_KEY"):
        keys.add(os.environ["LLAMA_API_KEY"])
    return keys


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


class H(BaseHTTPRequestHandler):
    manifests = []

    def log_message(self, *a):
        sys.stderr.write("cockpit: %s\n" % (a[0] % a[1:]))

    def authed(self, q):
        got = q.get("key", [""])[0]
        h = self.headers.get("Authorization", "")
        if h.startswith("Bearer "):
            got = h[7:]
        return bool(got) and any(hmac.compare_digest(got, k) for k in api_keys())

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path == "/":
            body = open(HTML, "rb").read()
            self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        if not self.authed(q):
            self.send_response(401); self.end_headers(); self.wfile.write(b"API key required\n"); return
        L = logs(self.manifests)
        if u.path == "/logs":
            body = json.dumps(L).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body); return
        if u.path == "/reasoning":
            body = json.dumps(reasoning()).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body); return
        if u.path == "/stream":
            path = L.get(q.get("log", [""])[0])
            if not path:
                self.send_response(404); self.end_headers(); return
            self.send_response(200); self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache"); self.end_headers()
            self.tail(path); return
        self.send_response(404); self.end_headers()

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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("COCKPIT_PORT", 9933)))
    ap.add_argument("--manifest", action="append", default=[])
    a = ap.parse_args()
    H.manifests = a.manifest or [os.path.join(ROOT, ".cache", "logs.manifest")] + \
        [m for m in os.environ.get("FAMILIA_LOG_MANIFEST", "").split(":") if m]
    print("cockpit: http://127.0.0.1:%d/  logs from %s" % (a.port, ", ".join(H.manifests)), file=sys.stderr)
    ThreadingHTTPServer(("127.0.0.1", a.port), H).serve_forever()


if __name__ == "__main__":
    main()
