#!/usr/bin/env python3
"""Configuration form for the launchers. Stdlib only. Binds to 127.0.0.1.

  python3 scripts/panel.py

Writes .cache/panel.env as POSIX defaults (`: "${KEY:=value}"`), so an
explicit environment variable still wins. Field names stay English. The
resource strip is memory, whether a GPU device is present, and whether the
server answers. Restart start.sh after saving.
"""
import html
import os
import re
import subprocess
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib.lockmem import try_lock_process

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV_PATH = os.path.join(ROOT, ".cache", "panel.env")
HOST = "127.0.0.1"
PORT = int(os.environ.get("PANEL_PORT", "9932"))

FIELDS = ("PROFILE", "TOOLS", "LOCALE", "LANGUAGE_MODE", "VARIANT", "GPU_LAYERS", "PORT", "WORKDIR")
CHOICES = {
    "PROFILE": ("auto", "lowram", "moderate", "default"),
    "LANGUAGE_MODE": ("auto", "native", "swap", "interpret", "off"),
    "VARIANT": ("auto", "cpu", "vulkan", "cuda-12", "cuda-13"),
}
SAFE = re.compile(r"^[A-Za-z0-9_./:+,-]*$")


def sentence(english):
    """One catalog sentence. Missing translation, or any other locale, stays English."""
    raw = os.environ.get("LC_ALL") or os.environ.get("LC_MESSAGES") or os.environ.get("LANG") or "en"
    code = raw.split(".")[0].split("@")[0].split("_")[0].split("-")[0].lower()
    path = os.path.join(ROOT, "config", "messages", code)
    if code in ("", "c", "posix", "en") or not os.path.isfile(path):
        return english
    with open(path, encoding="utf-8") as f:
        for line in f:
            key, sep, rest = line.rstrip("\n").partition("\t")
            if sep and key == english:
                return rest
    return english


def load_env():
    vals = {k: "" for k in FIELDS}
    if not os.path.isfile(ENV_PATH):
        return vals
    rx = re.compile(r'^: "\$\{([A-Z][A-Z0-9_]*):=(.*)\}"$')
    with open(ENV_PATH, encoding="utf-8") as f:
        for line in f:
            m = rx.match(line.rstrip("\n"))
            if m and m.group(1) in vals:
                vals[m.group(1)] = m.group(2)
    return vals


def check(key, value):
    if value == "":
        return ""
    if key in CHOICES:
        if value not in CHOICES[key]:
            raise ValueError(key)
        return value
    if key == "TOOLS":
        if value in ("auto", "full", "lean"):
            return value
        parts = [p for p in value.split(",") if p]
        if not parts or any(not re.fullmatch(r"[a-z0-9_]+", p) for p in parts):
            raise ValueError(key)
        return ",".join(parts)
    if key == "GPU_LAYERS":
        if value != "auto" and not re.fullmatch(r"[0-9]+", value):
            raise ValueError(key)
        return value
    if key == "PORT":
        if not re.fullmatch(r"[0-9]+", value) or not 1 <= int(value) <= 65535:
            raise ValueError(key)
        return value
    if key == "LOCALE":
        if value != "auto" and not re.fullmatch(r"[a-z]{2,8}", value):
            raise ValueError(key)
        return value
    if key == "WORKDIR":
        if not SAFE.fullmatch(value) or ".." in value.split("/"):
            raise ValueError(key)
        return value
    raise ValueError(key)


def write_env(vals):
    os.makedirs(os.path.dirname(ENV_PATH), exist_ok=True)
    lines = []
    for key in FIELDS:
        value = vals.get(key, "")
        if value == "":
            continue
        lines.append(': "${%s:=%s}"\n' % (key, value))
    with open(ENV_PATH, "w", encoding="utf-8") as f:
        f.writelines(lines)


def mem_line():
    path = "/proc/meminfo"
    if not os.path.isfile(path):
        return "unavailable"
    total = avail = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("MemTotal:"):
                total = int(line.split()[1]) // 1024
            elif line.startswith("MemAvailable:"):
                avail = int(line.split()[1]) // 1024
    if total is None or avail is None:
        return "unavailable"
    return "%d MiB available / %d MiB" % (avail, total)


def gpu_line():
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=utilization.gpu,memory.used",
                              "--format=csv,noheader"], capture_output=True, text=True, timeout=3)
        if out.returncode == 0 and out.stdout.strip():
            return "present " + out.stdout.strip().splitlines()[0]
    except (OSError, subprocess.TimeoutExpired):
        pass
    if os.path.exists("/dev/dri/renderD128"):
        return "present"
    return "absent"


def server_line(vals):
    port = vals.get("PORT") or os.environ.get("PORT") or "9931"
    ready = os.path.join(ROOT, ".cache", "serve.ready")
    if not os.path.isfile(ready):
        return "down"
    try:
        with open(ready, encoding="utf-8") as f:
            bits = f.read().split()
        if bits and bits[0].isdigit():
            port = bits[0]
        urllib.request.urlopen("http://127.0.0.1:%s/health" % port, timeout=1).read(32)
    except (OSError, ValueError):
        return "down"
    return "up"


def page(vals, note):
    rows = []
    for key in FIELDS:
        cur = html.escape(vals.get(key, ""), quote=True)
        if key in CHOICES:
            opts = ['<option value=""%s></option>' % ("" if cur else " selected")]
            for choice in CHOICES[key]:
                sel = " selected" if choice == vals.get(key) else ""
                opts.append('<option value="%s"%s>%s</option>' % (choice, sel, choice))
            control = '<select name="%s">%s</select>' % (key, "".join(opts))
        else:
            control = '<input name="%s" value="%s">' % (key, cur)
        rows.append("<tr><td>%s</td><td>%s</td></tr>" % (key, control))
    return """<!doctype html>
<meta charset="utf-8">
<title>Configuration</title>
<style>
body { font: 16px sans-serif; margin: 1.5rem; max-width: 40rem; }
table { border-collapse: collapse; }
td { padding: 0.3rem 0.6rem 0.3rem 0; }
.strip { margin: 0 0 1rem; }
</style>
<p class="strip">Memory %s<br>GPU %s<br>Server %s</p>
<form method="post" action="/save">
<table>
%s
</table>
<p><button type="submit">Save</button></p>
</form>
<p>%s</p>
""" % (html.escape(mem_line()), html.escape(gpu_line()), html.escape(server_line(vals)),
       "\n".join(rows), html.escape(note))


def main():
    try_lock_process("panel.py")
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    import urllib.parse

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            return

        def do_GET(self):
            body = page(load_env(), "").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            if urllib.parse.urlparse(self.path).path != "/save":
                self.send_error(404)
                return
            n = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(n).decode("utf-8", "replace")
            form = urllib.parse.parse_qs(raw, keep_blank_values=True)
            vals = {}
            try:
                for key in FIELDS:
                    vals[key] = check(key, (form.get(key) or [""])[0].strip())
            except ValueError as e:
                note = "Rejected %s." % e
                code = 400
            else:
                write_env(vals)
                note = sentence("Saved. Restart start.sh to apply.")
                code = 200
            body = page(vals if code == 200 else load_env(), note).encode()
            self.send_response(code)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print("panel: http://%s:%d/" % (HOST, PORT), flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
