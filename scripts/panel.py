#!/usr/bin/env python3
"""Configuration form for the launchers. Stdlib only. Binds to 127.0.0.1.

  python3 scripts/panel.py
  sh scripts/configure.sh

Writes .cache/panel.env as POSIX defaults (`: "${KEY:=value}"`), so an
explicit environment variable still wins. Only values that differ from the
launcher default are written. Field names stay English. The resource strip
is memory, whether a GPU device is present, and whether the server answers.
Restart start.sh after saving.

  python3 scripts/panel.py --fields
  python3 scripts/panel.py --check KEY VALUE
  python3 scripts/panel.py --write ANSWERS
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

# Names start.sh / serve.sh already read. GGUF_HOME is not one of them.
FIELDS = (
    "PROFILE", "MODELS_MAX", "VARIANT", "TOOLS", "GPU_LAYERS", "PORT",
    "THREADS", "THREADS_BATCH", "CTX", "CODER_CTX", "GENERAL_CTX", "PARALLEL",
    "REASONING", "HOST", "LOAD_MODE", "LOCALE", "LANGUAGE_MODE", "WORKDIR",
    "REPACK", "TOOLS_RUNTIME", "SWAP_CODER", "NO_BROWSER", "BUILD", "COPY_KEY",
    "RAISE", "DETACH_MODE",
)
# Empty means the launcher's own default. REASONING off and LOAD_MODE auto match
# that default, so typing them stores nothing.
DEFAULTS = {
    "PROFILE": "auto",
    "MODELS_MAX": "2",
    "VARIANT": "auto",
    "TOOLS": "auto",
    "GPU_LAYERS": "auto",
    "PORT": "9931",
    "THREADS": "auto",
    "THREADS_BATCH": "auto",
    "CTX": "",
    "CODER_CTX": "",
    "GENERAL_CTX": "",
    "PARALLEL": "",
    "REASONING": "off",
    "HOST": "127.0.0.1",
    "LOAD_MODE": "auto",
    "LOCALE": "auto",
    "LANGUAGE_MODE": "native",
    "WORKDIR": "",
    "REPACK": "on",
    "TOOLS_RUNTIME": "auto",
    "SWAP_CODER": "0",
    "NO_BROWSER": "0",
    "BUILD": "0",
    "COPY_KEY": "0",
    "RAISE": "",
    "DETACH_MODE": "foreground",
}
CHOICES = {
    "PROFILE": ("auto", "lowram", "moderate", "default"),
    "VARIANT": ("auto", "cpu", "vulkan", "cuda-12", "cuda-13"),
    "REASONING": ("off", "on", "auto"),
    "LOAD_MODE": ("auto", "none", "mmap", "mlock", "mmap+mlock", "dio"),
    "LANGUAGE_MODE": ("auto", "native", "swap", "interpret", "off"),
    "REPACK": ("on", "off"),
    "SWAP_CODER": ("0", "1"),
    "NO_BROWSER": ("0", "1"),
    "BUILD": ("0", "1"),
    "COPY_KEY": ("0", "1"),
    "RAISE": ("0", "1"),
    "DETACH_MODE": ("foreground", "nohup", "tmux", "screen"),
}
HINTS = {
    "PROFILE": "auto|lowram|moderate|default",
    "MODELS_MAX": "1-8",
    "VARIANT": "auto|cpu|vulkan|cuda-12|cuda-13",
    "TOOLS": "auto|full|lean|comma list",
    "GPU_LAYERS": "auto or 0-9999",
    "PORT": "1-65535",
    "THREADS": "auto or 1-4096",
    "THREADS_BATCH": "auto or 1-4096",
    "CTX": "2048-262144; Enter keeps the profile",
    "CODER_CTX": "2048-262144; Enter keeps the profile",
    "GENERAL_CTX": "2048-262144; Enter keeps the profile",
    "PARALLEL": "1-16; Enter keeps the profile",
    "REASONING": "off|on|auto",
    "HOST": "address or comma list",
    "LOAD_MODE": "auto|none|mmap|mlock|mmap+mlock|dio",
    "LOCALE": "auto or a language code",
    "LANGUAGE_MODE": "auto|native|swap|interpret|off",
    "WORKDIR": "directory; Enter keeps workspace",
    "REPACK": "on|off",
    "TOOLS_RUNTIME": "auto|host|podman:image|docker:image|podman-container:id|docker-container:id|ssh:target",
    "SWAP_CODER": "0|1",
    "NO_BROWSER": "0|1",
    "BUILD": "0|1",
    "COPY_KEY": "0|1",
    "RAISE": "0|1; Enter asks once",
    "DETACH_MODE": "foreground|nohup|tmux|screen",
}
# No quotes, dollars, or backticks: the line is sourced as : "${KEY:=value}".
SAFE_VALUE = re.compile(r"^[A-Za-z0-9_./:+,@-]+$")


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


def shown(key):
    if key == "WORKDIR":
        return "workspace"
    if DEFAULTS[key] == "":
        return "Enter"
    return DEFAULTS[key]


def load_env():
    vals = {k: "" for k in FIELDS}
    if not os.path.isfile(ENV_PATH):
        return vals
    rx = re.compile(r'^: "\$\{([A-Z][A-Z0-9_]*):=(.*)\}"$')
    with open(ENV_PATH, encoding="utf-8") as f:
        for line in f:
            m = rx.match(line.rstrip("\r\n"))
            if m and m.group(1) in vals:
                vals[m.group(1)] = m.group(2)
    return vals


def whole(key, value, lo, hi):
    if not re.fullmatch(r"[0-9]+", value):
        raise ValueError(key)
    n = int(value)
    if n < lo or n > hi:
        raise ValueError(key)
    return str(n)


def check_tools_runtime(value):
    if value in ("auto", "host"):
        return value
    if re.fullmatch(r"(podman|docker):[A-Za-z0-9_./:+@-]+", value):
        return value
    if re.fullmatch(r"(podman|docker)-container:[A-Za-z0-9_.-]+", value):
        return value
    if re.fullmatch(r"ssh:[A-Za-z0-9_./:+@-]+", value):
        return value
    raise ValueError("TOOLS_RUNTIME")


def check(key, value):
    if value is None:
        value = ""
    else:
        value = str(value).strip()
    if value == "":
        return ""
    if key in CHOICES:
        if value not in CHOICES[key]:
            raise ValueError(key)
    elif key == "MODELS_MAX":
        value = whole(key, value, 1, 8)
    elif key == "TOOLS":
        if value not in ("auto", "full", "lean"):
            parts = [p for p in value.split(",") if p]
            if not parts or any(not re.fullmatch(r"[a-z0-9_]+", p) for p in parts):
                raise ValueError(key)
            value = ",".join(parts)
    elif key == "GPU_LAYERS":
        if value != "auto":
            value = whole(key, value, 0, 9999)
    elif key == "PORT":
        value = whole(key, value, 1, 65535)
    elif key in ("THREADS", "THREADS_BATCH"):
        if value != "auto":
            value = whole(key, value, 1, 4096)
    elif key in ("CTX", "CODER_CTX", "GENERAL_CTX"):
        value = whole(key, value, 2048, 262144)
    elif key == "PARALLEL":
        value = whole(key, value, 1, 16)
    elif key == "HOST":
        parts = value.split(",")
        if not parts or any(not re.fullmatch(r"[A-Za-z0-9.:_-]+", p) for p in parts):
            raise ValueError(key)
        value = ",".join(parts)
    elif key == "LOCALE":
        if value != "auto" and not re.fullmatch(r"[a-z]{2,8}", value):
            raise ValueError(key)
    elif key == "WORKDIR":
        if ".." in value.split("/"):
            raise ValueError(key)
    elif key == "TOOLS_RUNTIME":
        value = check_tools_runtime(value)
    else:
        raise ValueError(key)
    if not SAFE_VALUE.fullmatch(value):
        raise ValueError(key)
    return value


def stored_value(key, value):
    # The file lists changes only. Pinning a launcher default would hide that.
    if value == "" or value == DEFAULTS.get(key, ""):
        return ""
    if key == "WORKDIR":
        raw = value if os.path.isabs(value) else os.path.join(ROOT, value)
        if os.path.normpath(raw) == os.path.normpath(os.path.join(ROOT, "workspace")):
            return ""
    return value


def write_env(vals):
    os.makedirs(os.path.dirname(ENV_PATH), exist_ok=True)
    lines = []
    for key in FIELDS:
        value = stored_value(key, vals.get(key, ""))
        if value == "":
            continue
        if not SAFE_VALUE.fullmatch(value):
            raise ValueError(key)
        lines.append(': "${%s:=%s}"\n' % (key, value))
    # Always LF. A CRLF line is not the assignment the shell launchers source.
    with open(ENV_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.writelines(lines)


def cli(argv):
    """Shared by configure.sh and configure.ps1. None means: serve the form."""
    if not argv:
        return None
    cmd = argv[0]
    if cmd == "--fields":
        for key in FIELDS:
            sys.stdout.write("%s\t%s\t%s\n" % (key, shown(key), HINTS[key]))
        return 0
    if cmd == "--check":
        if len(argv) != 3:
            return 2
        try:
            check(argv[1], argv[2])
        except ValueError:
            return 1
        return 0
    if cmd == "--write":
        if len(argv) != 2:
            return 2
        vals = {k: "" for k in FIELDS}
        try:
            fh = open(argv[1], encoding="utf-8")
        except OSError:
            sys.stderr.write("panel: cannot read answers\n")
            return 1
        with fh:
            for line in fh:
                line = line.rstrip("\r\n")
                if line == "":
                    continue
                key, sep, val = line.partition("\t")
                if not sep or key not in vals:
                    sys.stderr.write("panel: bad answer line\n")
                    return 1
                try:
                    vals[key] = check(key, val)
                except ValueError:
                    sys.stderr.write("panel: refused %s\n" % key)
                    return 1
        try:
            write_env(vals)
        except ValueError as e:
            sys.stderr.write("panel: refused %s\n" % e)
            return 1
        return 0
    sys.stderr.write("panel: unknown argument\n")
    return 2


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
    code = cli(sys.argv[1:])
    if code is not None:
        raise SystemExit(code)
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
