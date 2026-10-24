#!/usr/bin/env python3
"""Configuration panel for the launchers. Stdlib only, no JavaScript. Binds to 127.0.0.1.

  python3 scripts/panel.py [--open] [--port N]   then open http://127.0.0.1:9932/
  sh scripts/configure.sh                        the same settings on a terminal

Built to be usable with only a keyboard, a single switch (scanning), a mouse or a
screen reader: one setting per labelled control, large targets, a visible focus
ring, short pages, choices as big radio buttons, no timeouts, no dragging.
Every change is shown before it is saved, and the last saves can be undone.

Writes .cache/panel.env as POSIX defaults (`: "${KEY:=value}"`), so an
explicit environment variable still wins. Only values that differ from the
launcher default are written. Restart start.sh after saving.

Remote use: the panel never listens on the network. From another computer run
  ssh -L 9932:127.0.0.1:9932 HOST
and open http://127.0.0.1:9932/ there.

Extra pages: PANEL_EXTRA=/path/to/module.py adds the pages that module defines
(familia uses this for skills, licenses, hermes and Harness2). See EXTRA API below.

  python3 scripts/panel.py --fields
  python3 scripts/panel.py --check KEY VALUE
  python3 scripts/panel.py --write ANSWERS
  python3 scripts/panel.py --a11y-check      render every page and run the accessibility check
"""
import hashlib
import html
import importlib.util
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV_PATH = os.path.join(ROOT, ".cache", "panel.env")
UNDO_DIR = os.path.join(ROOT, ".cache", "panel-undo")
UNDO_KEEP = 20
HOST = "127.0.0.1"
PORT = int(os.environ.get("PANEL_PORT", "9932"))
MAX_BODY = 1 << 20
TOKEN = secrets.token_urlsafe(24)

# Names start.sh / serve.sh already read. GGUF_HOME is not one of them.
FIELDS = (
    "PROFILE", "MODELS_MAX", "VARIANT", "TOOLS", "GPU_LAYERS", "PORT", "EMBED_PORT",
    "THREADS", "THREADS_BATCH", "CTX", "CODER_CTX", "GENERAL_CTX", "PARALLEL",
    "REASONING", "HOST", "LOAD_MODE", "LOCALE", "LANGUAGE_MODE", "WORKDIR",
    "REPACK", "TOOLS_RUNTIME", "SWAP_CODER", "NO_BROWSER", "BUILD", "COPY_KEY",
    "RAISE", "DETACH_MODE", "FEELD_SNAP_FS", "ENGINE_CHAT",
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
    "EMBED_PORT": "",
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
    "FEELD_SNAP_FS": "auto",
    "ENGINE_CHAT": "",
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
    "DETACH_MODE": ("foreground", "nohup", "tmux", "screen-attached", "screen"),
    "FEELD_SNAP_FS": ("auto", "zfs", "btrfs", "bcachefs", "apfs", "hardlink", "virtual"),
}
HINTS = {
    "PROFILE": "auto|lowram|moderate|default",
    "MODELS_MAX": "1-8",
    "VARIANT": "auto|cpu|vulkan|cuda-12|cuda-13",
    "TOOLS": "auto|full|lean|comma list",
    "GPU_LAYERS": "auto or 0-9999",
    "PORT": "1-65535",
    "EMBED_PORT": "1-65535; empty for PORT+1",
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
    "FEELD_SNAP_FS": "auto|zfs|btrfs|bcachefs|apfs|hardlink|virtual",
    "ENGINE_CHAT": "alternate engine tag for chat route",
}
# Plain-language names for the form. The variable name is shown too, so the
# panel teaches the names that start.sh, the docs and configure.sh use.
LABELS = {
    "PROFILE": "Memory profile",
    "MODELS_MAX": "Most models loaded at once",
    "VARIANT": "llama.cpp build to use",
    "TOOLS": "Agent tools",
    "GPU_LAYERS": "Model layers on the graphics card",
    "PORT": "Model server port",
    "EMBED_PORT": "Embedding server port",
    "THREADS": "CPU threads for writing answers",
    "THREADS_BATCH": "CPU threads for reading prompts",
    "CTX": "Context length for every model (tokens)",
    "CODER_CTX": "Context length for the coder (tokens)",
    "GENERAL_CTX": "Context length for the general model (tokens)",
    "PARALLEL": "Requests served at the same time",
    "REASONING": "Thinking (reasoning) mode",
    "HOST": "Address the model server listens on",
    "LOAD_MODE": "How model files are loaded into memory",
    "LOCALE": "Language code",
    "LANGUAGE_MODE": "How other languages are handled",
    "WORKDIR": "Agent working folder",
    "REPACK": "Repack weights for this CPU",
    "TOOLS_RUNTIME": "Where agent tools run",
    "SWAP_CODER": "Swap the coder in and out of memory",
    "NO_BROWSER": "Do not open a browser at start",
    "BUILD": "Build llama.cpp from source",
    "COPY_KEY": "Copy the API key to the clipboard",
    "RAISE": "Raise the memory-lock limit at start",
    "DETACH_MODE": "Keep running after the terminal closes",
    "FEELD_SNAP_FS": "Snapshot method for the workspace",
    "ENGINE_CHAT": "Alternate engine for chat",
}
ON_OFF = {"0": "Off", "1": "On"}
# Short pages: fewer stops for switch scanning and less scrolling at 200% zoom.
SECTIONS = (
    ("basics", "Basics", "Memory profile, thinking mode and language.",
     ("PROFILE", "MODELS_MAX", "REASONING", "LOCALE", "LANGUAGE_MODE")),
    ("speed", "Speed and memory", "Threads, context length, graphics card and loading.",
     ("VARIANT", "GPU_LAYERS", "THREADS", "THREADS_BATCH", "CTX", "CODER_CTX", "GENERAL_CTX",
      "PARALLEL", "LOAD_MODE", "REPACK", "SWAP_CODER")),
    ("network", "Network", "Ports and the address the model server listens on.",
     ("PORT", "EMBED_PORT", "HOST")),
    ("tools", "Agent tools", "Which tools the agent gets and where they run.",
     ("TOOLS", "TOOLS_RUNTIME", "WORKDIR", "ENGINE_CHAT")),
    ("startup", "Starting up", "What start.sh does when it starts.",
     ("NO_BROWSER", "BUILD", "COPY_KEY", "RAISE", "DETACH_MODE", "FEELD_SNAP_FS")),
)
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
    elif key in ("PORT", "EMBED_PORT"):
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
    elif key == "ENGINE_CHAT":
        if not re.fullmatch(r"[A-Za-z0-9_.:+@-]+", value):
            raise ValueError(key)
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


def env_text(vals):
    lines = []
    for key in FIELDS:
        value = stored_value(key, vals.get(key, ""))
        if value == "":
            continue
        if not SAFE_VALUE.fullmatch(value):
            raise ValueError(key)
        lines.append(': "${%s:=%s}"\n' % (key, value))
    return "".join(lines)


def write_env(vals):
    text = env_text(vals)
    os.makedirs(os.path.dirname(ENV_PATH), exist_ok=True)
    tmp = ENV_PATH + ".tmp"
    # Always LF. A CRLF line is not the assignment the shell launchers source.
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, ENV_PATH)


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
    if cmd == "--a11y-check":
        return a11y_cli()
    sys.stderr.write("panel: unknown argument %r. Try: python3 scripts/panel.py --help\n" % cmd)
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


# ---------------------------------------------------------------- UI helpers
# Every control gets an id, a <label for>, and its hint/error via aria-describedby.
# Choices are radio buttons inside <fieldset><legend>: one press selects, arrow
# keys move inside the group, Tab moves to the next group (good for scanning).

def esc(s):
    return html.escape("" if s is None else str(s), quote=True)


def _ids(name):
    base = re.sub(r"[^A-Za-z0-9_-]", "-", name)
    return "f-" + base, "h-" + base, "e-" + base


def _described(hint_id, err_id, hint, error):
    ids = ([hint_id] if hint else []) + ([err_id] if error else [])
    return (' aria-describedby="%s"' % " ".join(ids)) if ids else ""


def _hint_err(hint_id, err_id, hint, error):
    out = ""
    if hint:
        out += '<p class="hint" id="%s">%s</p>' % (hint_id, hint)
    if error:
        out += '<p class="error" id="%s"><strong>Problem:</strong> %s</p>' % (err_id, esc(error))
    return out


def text_field(name, label, value, hint="", error="", inputmode=""):
    fid, hid, eid = _ids(name)
    im = ' inputmode="%s"' % inputmode if inputmode else ""
    inv = ' aria-invalid="true"' if error else ""
    return ('<div class="field%s"><label for="%s">%s</label>%s'
            '<input type="text" id="%s" name="%s" value="%s"%s%s%s autocomplete="off" spellcheck="false"></div>'
            % (" bad" if error else "", fid, esc(label), _hint_err(hid, eid, hint, error), fid, esc(name),
               esc(value), im, inv, _described(hid, eid, hint, error)))


def radio_group(name, legend, options, current, hint="", error=""):
    """options: [(value, label)]. Exactly one is checked (current, else the first)."""
    fid, hid, eid = _ids(name)
    if current not in [v for v, _ in options]:
        current = options[0][0] if options else ""
    rows = []
    for n, (value, lab) in enumerate(options):
        rid = "%s-%d" % (fid, n)
        chk = " checked" if value == current else ""
        rows.append('<div class="choice"><input type="radio" id="%s" name="%s" value="%s"%s>'
                    '<label for="%s">%s</label></div>' % (rid, esc(name), esc(value), chk, rid, lab))
    return ('<fieldset class="field%s" id="%s"%s><legend>%s</legend>%s%s</fieldset>'
            % (" bad" if error else "", fid, _described(hid, eid, hint, error), esc(legend),
               _hint_err(hid, eid, hint, error), "".join(rows)))


def checkbox(name, label, checked, hint="", value="1"):
    fid, hid, _ = _ids(name)
    return ('<div class="choice check"><input type="checkbox" id="%s" name="%s" value="%s"%s%s>'
            '<label for="%s">%s</label>%s</div>'
            % (fid, esc(name), esc(value), " checked" if checked else "",
               _described(hid, "", hint, ""), fid, label, _hint_err(hid, "", hint, "")))


def checkbox_group(legend, boxes, hint=""):
    gid = "g-" + re.sub(r"[^A-Za-z0-9_-]", "-", legend.lower())[:40]
    h = ('<p class="hint" id="%s-h">%s</p>' % (gid, hint)) if hint else ""
    d = (' aria-describedby="%s-h"' % gid) if hint else ""
    return '<fieldset class="field" id="%s"%s><legend>%s</legend>%s%s</fieldset>' % (gid, d, esc(legend), h, "".join(boxes))


def hidden(name, value):
    return '<input type="hidden" name="%s" value="%s">' % (esc(name), esc(value))


def button(label, name="", value="", primary=True):
    nv = (' name="%s" value="%s"' % (esc(name), esc(value))) if name else ""
    return '<button type="submit" class="%s"%s>%s</button>' % ("primary" if primary else "secondary", nv, esc(label))


def link_button(href, label):
    return '<a class="btn" href="%s">%s</a>' % (esc(href), esc(label))


def form(action, body, method="post"):
    tok = hidden("token", TOKEN) if method == "post" else ""
    return '<form method="%s" action="%s">%s%s</form>' % (method, esc(action), tok, body)


def pre(text, label="Output"):
    return '<pre aria-label="%s" tabindex="0">%s</pre>' % (esc(label), esc(text))


CSS = """
html { font-size: 112.5%; }
body { font-family: sans-serif; line-height: 1.5; margin: 0; padding: 0.75rem; color: #000; background: #fff; }
main, header, nav, footer { display: block; max-width: 46rem; margin: 0 auto; }
h1 { font-size: 1.6rem; margin: 0.4rem 0 0.6rem; }
h2 { font-size: 1.3rem; margin: 1.4rem 0 0.5rem; }
a { color: #0040a0; text-decoration: underline; }
a:visited { color: #50207a; }
.skip { position: absolute; left: -999em; }
.skip:focus { position: static; display: inline-block; }
a:focus, button:focus, input:focus, pre:focus, .btn:focus {
  outline: 4px solid #d35400; outline-offset: 3px; }
input[type=text] { font-size: 1.1rem; min-height: 2.75rem; width: 100%; max-width: 30rem;
  box-sizing: border-box; padding: 0.3rem 0.5rem; border: 2px solid #333; }
button, .btn { display: inline-block; font-size: 1.1rem; min-height: 2.75rem; min-width: 2.75rem;
  padding: 0.45rem 1.1rem; margin: 0.3rem 0.6rem 0.3rem 0; border: 3px solid #000;
  background: #fff; color: #000; text-decoration: none; cursor: pointer; box-sizing: border-box; }
button.primary { background: #0040a0; color: #fff; border-color: #0040a0; }
fieldset { border: 2px solid #777; padding: 0.5rem 0.9rem 0.7rem; margin: 0 0 1rem; }
legend { font-weight: bold; padding: 0 0.3rem; }
.field { margin: 0 0 1.1rem; }
.field label { font-weight: bold; display: block; }
.choice { display: block; min-height: 2.75rem; margin: 0.15rem 0; }
.choice input { width: 1.6rem; height: 1.6rem; margin: 0.55rem 0.6rem 0 0; vertical-align: top; float: left; }
.choice label { display: block; font-weight: normal; padding: 0.45rem 0; margin-left: 2.3rem; cursor: pointer; }
.hint { margin: 0.1rem 0 0.35rem; color: #333; }
.choice .hint { margin-left: 2.3rem; }
.error { color: #a00000; margin: 0.1rem 0 0.35rem; }
.bad { border-left: 6px solid #a00000; padding-left: 0.6rem; }
.alert { border: 3px solid #a00000; padding: 0.6rem 0.9rem; margin: 0 0 1rem; }
.ok { border: 3px solid #1b6e20; padding: 0.6rem 0.9rem; margin: 0 0 1rem; }
.strip { border: 2px solid #777; padding: 0.4rem 0.8rem; }
ul.pages { list-style: none; padding: 0; }
ul.pages li { margin: 0 0 0.6rem; }
ul.pages a { display: block; font-size: 1.15rem; padding: 0.55rem 0.8rem; border: 2px solid #0040a0; min-height: 2.75rem; box-sizing: border-box; }
pre { white-space: pre-wrap; word-wrap: break-word; border: 2px solid #777; padding: 0.5rem; font-size: 0.95rem; }
table { border-collapse: collapse; }
th, td { text-align: left; padding: 0.3rem 0.6rem 0.3rem 0; vertical-align: top; }
code { font-size: 0.95em; }
@media (prefers-reduced-motion: reduce) { * { transition: none !important; } }
"""


def layout(title, body, crumbs=True):
    app = os.environ.get("PANEL_TITLE") or "Settings"
    nav = ('<nav aria-label="Where you are"><p><a href="/">%s: start page</a></p></nav>' % esc(app)) if crumbs else ""
    return ("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
            "<title>%s</title>\n<style>%s</style>\n</head>\n<body>\n"
            "<a class=\"skip\" href=\"#main\">Skip to the main content</a>\n<header>%s</header>\n"
            "<main id=\"main\">\n<h1>%s</h1>\n%s\n</main>\n</body>\n</html>\n"
            % (esc(title if title == app else "%s - %s" % (title, app)), CSS, nav, esc(title), body))


def notice(msg, ok=True):
    if not msg:
        return ""
    return '<div class="%s" role="%s"><p>%s</p></div>' % ("ok" if ok else "alert", "status" if ok else "alert", msg)


def error_summary(errors):
    """errors: [(field name or "", message)]. Links jump to the control."""
    if not errors:
        return ""
    items = []
    for name, msg in errors:
        if name:
            items.append('<li><a href="#%s">%s</a></li>' % (_ids(name)[0], esc(msg)))
        else:
            items.append("<li>%s</li>" % esc(msg))
    return ('<div class="alert" role="alert"><h2>Nothing was saved. Please fix:</h2><ul>%s</ul></div>'
            % "".join(items))


# ---------------------------------------------------------------- undo journal
# Before a save, every file it may touch is copied here. Undo puts them back,
# but only if nothing else changed the file since (its hash is checked).

def _sha(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None


def _journal_path():
    return os.path.join(UNDO_DIR, "journal.json")


def journal():
    try:
        with open(_journal_path(), encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


def _save_journal(entries):
    os.makedirs(UNDO_DIR, exist_ok=True)
    tmp = _journal_path() + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(entries[-UNDO_KEEP:], f, indent=1)
    os.replace(tmp, _journal_path())
    keep = {fe["backup"] for e in entries[-UNDO_KEEP:] for fe in e["files"] if fe.get("backup")}
    for n in os.listdir(UNDO_DIR):
        p = os.path.join(UNDO_DIR, n)
        if n.endswith(".bak") and p not in keep:
            try:
                os.remove(p)
            except OSError:
                pass


def with_undo(what, paths, action):
    """Snapshot paths, run action(), journal the result. Returns action()'s value."""
    os.makedirs(UNDO_DIR, exist_ok=True)
    eid = "%d-%s" % (int(time.time()), secrets.token_hex(3))
    files = []
    for n, p in enumerate(paths):
        p = os.path.abspath(p)
        bak = None
        if os.path.isfile(p):
            bak = os.path.join(UNDO_DIR, "%s-%d.bak" % (eid, n))
            shutil.copy2(p, bak)
        files.append({"path": p, "backup": bak})
    try:
        result = action()
    except BaseException:
        for fe in files:  # put back anything a failed action half-wrote
            _restore(fe)
        raise
    changed = []
    for fe in files:
        fe["after"] = _sha(fe["path"])
        if fe["after"] != (_sha(fe["backup"]) if fe["backup"] else None):
            changed.append(fe)
    if changed:
        entries = journal()
        entries.append({"id": eid, "time": time.strftime("%Y-%m-%d %H:%M %Z"), "what": what, "files": changed})
        _save_journal(entries)
    return result


def _restore(fe):
    if fe.get("backup") and os.path.isfile(fe["backup"]):
        tmp = fe["path"] + ".undo-tmp"
        shutil.copy2(fe["backup"], tmp)
        os.replace(tmp, fe["path"])
    elif not fe.get("backup") and os.path.isfile(fe["path"]):
        os.remove(fe["path"])


def undo_last():
    """Return (ok, message)."""
    entries = journal()
    if not entries:
        return False, "There is nothing to undo."
    e = entries[-1]
    for fe in e["files"]:
        if _sha(fe["path"]) != fe.get("after"):
            return False, ("Not undone: %s was changed by something else after this save, so undoing would "
                           "lose that change. Change it back by hand, or edit the setting again."
                           % os.path.basename(fe["path"]))
    for fe in e["files"]:
        _restore(fe)
    entries.pop()
    _save_journal(entries)
    return True, "Undone: %s" % e["what"]


# ---------------------------------------------------------------- pages
# A page source is an object with:
#   pages()                      -> [(page_id, title, one-line summary)]
#   render(page_id, query)       -> HTML for the page (forms post to /p/<id>/preview)
#   preview(page_id, form)       -> dict(changes=[str], errors=[(field, msg)], notes=HTML,
#                                        confirm=[(name, label)], files=[paths], what=str)
#   apply(page_id, form)         -> message; raise ValueError(reason) to refuse
# preview must not write anything. apply is called only after the preview page's
# "Save" was pressed and every confirm box was ticked; files are snapshotted for undo.

def _word(key, value):
    if value == "":
        return "default (%s)" % (DEFAULTS[key] or "launcher decides")
    return ON_OFF.get(value, value) if key in CHOICES and CHOICES[key] == ("0", "1") else value


class LauncherPages:
    def pages(self):
        return [("launch-" + sid, title, summary) for sid, title, summary, _ in SECTIONS]

    def _section(self, page_id):
        for sid, title, summary, keys in SECTIONS:
            if "launch-" + sid == page_id:
                return title, summary, keys
        raise KeyError(page_id)

    def control(self, key, value, error=""):
        label = LABELS[key]
        default = DEFAULTS[key] or "the launcher decides"
        hint = "Setting name <code>%s</code>. Allowed: %s." % (key, esc(HINTS[key]))
        if key in CHOICES:
            if DEFAULTS[key]:
                dflt = ON_OFF.get(DEFAULTS[key], DEFAULTS[key]) if CHOICES[key] == ("0", "1") else DEFAULTS[key]
            else:
                dflt = "ask once" if key == "RAISE" else "the launcher decides"
            opts = [("", "Default (%s)" % esc(dflt))]
            for c in CHOICES[key]:
                if c != DEFAULTS[key]:
                    opts.append((c, esc(ON_OFF.get(c, c) if CHOICES[key] == ("0", "1") else c)))
            cur = "" if value == DEFAULTS[key] else value
            return radio_group(key, label, opts, cur, hint, error)
        numeric = key in ("MODELS_MAX", "PORT", "EMBED_PORT", "CTX", "CODER_CTX", "GENERAL_CTX", "PARALLEL")
        return text_field(key, label, value, hint + " Leave empty for the default (%s)." % esc(default),
                          error, "numeric" if numeric else "")

    def render(self, page_id, query, values=None, errors=()):
        title, summary, keys = self._section(page_id)
        vals = load_env()
        if values:
            vals.update(values)
        errd = dict(errors)
        body = "".join(self.control(k, vals.get(k, ""), errd.get(k, "")) for k in keys)
        body += "<p>%s %s</p>" % (button("Next: show what will change"), link_button("/", "Cancel"))
        return error_summary(errors) + "<p>%s Nothing is saved until you confirm on the next page.</p>" % esc(summary) \
            + form("/p/%s/preview" % page_id, body)

    def _read(self, keys, form_):
        vals, errors = {}, []
        for k in keys:
            raw = (form_.get(k) or [""])[0].strip()
            try:
                vals[k] = check(k, raw)
            except ValueError:
                vals[k] = raw
                errors.append((k, "%s: %r is not allowed. Allowed: %s." % (LABELS[k], raw, HINTS[k])))
        return vals, errors

    def preview(self, page_id, form_):
        title, _, keys = self._section(page_id)
        vals, errors = self._read(keys, form_)
        cur = load_env()
        changes = []
        for k in keys:
            if not errors and stored_value(k, vals[k]) != stored_value(k, cur.get(k, "")):
                changes.append("%s (%s): %s to %s" % (LABELS[k], k, _word(k, stored_value(k, cur.get(k, ""))),
                                                      _word(k, stored_value(k, vals[k]))))
        return {"changes": changes, "errors": errors, "files": [ENV_PATH], "values": vals,
                "what": "%s settings: %s" % (title, "; ".join(changes)),
                "notes": "<p>Restart <code>start.sh</code> (or <code>start.bat</code>) after saving so the launcher reads them.</p>"}

    def apply(self, page_id, form_):
        _, _, keys = self._section(page_id)
        vals, errors = self._read(keys, form_)
        if errors:
            raise ValueError(errors[0][1])
        merged = load_env()
        merged.update(vals)
        write_env(merged)
        return sentence("Saved. Restart start.sh to apply.")


def load_extra(path=None):
    path = path or os.environ.get("PANEL_EXTRA")
    if not path:
        return None
    spec = importlib.util.spec_from_file_location("panel_extra", path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["panel_extra"] = mod
    spec.loader.exec_module(mod)
    ui = type(sys)("panel_ui")  # the helpers above, whatever name this file was loaded under
    ui.__dict__.update({k: v for k, v in globals().items() if not k.startswith("__")})
    return mod.Pages(ui)


class App:
    def __init__(self, extra=None):
        self.sources = []
        if extra is not None:
            self.sources.append(extra)
        self.sources.append(LauncherPages())

    def source_for(self, page_id):
        for s in self.sources:
            if page_id in [p[0] for p in s.pages()]:
                return s
        return None

    def title(self, page_id):
        for s in self.sources:
            for pid, t, _ in s.pages():
                if pid == page_id:
                    return t
        return page_id

    def home(self, note="", ok=True):
        groups = []
        for s in self.sources:
            heading = getattr(s, "heading", "Model server launcher (start.sh)")
            items = "".join('<li><a href="/p/%s">%s</a> %s</li>' % (esc(pid), esc(t), esc(summ))
                            for pid, t, summ in s.pages())
            groups.append("<h2>%s</h2><ul class=\"pages\">%s</ul>" % (esc(heading), items))
        j = journal()
        if j:
            last = j[-1]
            und = form("/undo", "<p>Last save (%s): %s</p><p>%s</p>"
                       % (esc(last["time"]), esc(last["what"]), button("Undo the last save", primary=False)))
        else:
            und = "<p>No saves to undo yet.</p>"
        strip = ('<div class="strip" role="group" aria-label="This computer"><p>Memory: %s<br>Graphics card: %s<br>'
                 'Model server: %s</p></div>' % (esc(mem_line()), esc(gpu_line()), esc(server_line(load_env()))))
        intro = ("<p>Pick what you want to change. Each page is short. Nothing is saved until you see the "
                 "changes and press Save, and you can undo afterwards. Works with a keyboard (Tab, arrow keys, "
                 "Space), a switch, a mouse or a screen reader.</p>")
        body = notice(note, ok) + intro + "".join(groups) + "<h2>Undo</h2>" + und + "<h2>This computer</h2>" + strip
        return layout(os.environ.get("PANEL_TITLE", "Settings"), body, crumbs=False)

    def route(self, method, path, query=None, form_=None, headers=None):
        """Returns (status, html). No HTTP here, so tests call it directly."""
        query = query or {}
        form_ = form_ or {}
        if method == "POST" and (form_.get("token") or [""])[0] != TOKEN:
            return 403, layout("Expired page", notice("This page is from an earlier panel session. Open the "
                                                        "start page and try again.", False) + link_button("/", "Start page"))
        if path in ("/", ""):
            if method != "GET":
                return 405, layout("Not allowed", "")
            return 200, self.home()
        if path == "/undo" and method == "POST":
            ok, msg = undo_last()
            return (200 if ok else 409), self.home(esc(msg), ok)
        m = re.fullmatch(r"/p/([a-z0-9-]+)(/preview|/save)?", path)
        if not m:
            return 404, layout("Page not found", '<p>%s</p>' % link_button("/", "Start page"))
        pid, step = m.group(1), m.group(2)
        src = self.source_for(pid)
        if src is None:
            return 404, layout("Page not found", '<p>%s</p>' % link_button("/", "Start page"))
        title = self.title(pid)
        if step is None:
            if method == "GET":
                return 200, layout(title, src.render(pid, query))
            # "Change them" from the preview page: show the form again with the values typed.
            return 200, layout(title, self._rerender(src, pid, form_, []))
        if method != "POST":
            return 405, layout("Not allowed", '<p>%s</p>' % link_button("/p/" + pid, "Back"))
        pv = src.preview(pid, form_)
        if pv.get("errors"):
            return 400, layout(title, self._rerender(src, pid, form_, pv["errors"]))
        if step == "/preview":
            return 200, layout(title + ": check before saving", self._preview_page(pid, form_, pv))
        missing = [lab for name, lab in pv.get("confirm", []) if (form_.get(name) or [""])[0] != "1"]
        if missing:
            return 400, layout(title + ": check before saving",
                               self._preview_page(pid, form_, pv, [("", "Tick the box: " + re.sub("<[^>]+>", "", l))
                                                                 for l in missing]))
        if not pv.get("changes"):
            return 200, self.home("Nothing changed, so nothing was saved.")
        try:
            msg = with_undo(pv.get("what") or title, pv.get("files", []), lambda: src.apply(pid, form_))
        except ValueError as e:
            return 409, layout(title, error_summary([("", str(e))]) + src.render(pid, query))
        return 200, self.home(esc(msg) + " You can undo it below.")

    def _rerender(self, src, pid, form_, errors):
        values = {k: v[0] for k, v in form_.items() if k != "token"}
        try:
            return src.render(pid, {}, values=values, errors=errors)
        except TypeError:
            return error_summary(errors) + src.render(pid, {})

    def _preview_page(self, pid, form_, pv, errors=()):
        keep = "".join(hidden(k, v) for k, vs in form_.items() if k not in ("token", "do")
                       and k not in [c[0] for c in pv.get("confirm", [])] for v in vs)
        if pv.get("changes"):
            ch = "<h2>These changes will be saved</h2><ul>%s</ul>" % "".join("<li>%s</li>" % esc(c) for c in pv["changes"])
        else:
            ch = "<h2>No changes</h2><p>What you chose is what is already saved.</p>"
        notes = pv.get("notes") or ""
        confirm = "".join(checkbox(name, lab, False) for name, lab in pv.get("confirm", []))
        if pv.get("changes"):
            actions = button("Save these changes", "do", "save")
        else:
            actions = ""
        body = (error_summary(errors) + ch + notes + confirm +
                "<p>%s %s %s</p>" % (actions, button("Go back and change them", "do", "back", primary=False),
                                     link_button("/", "Cancel")))
        return ('<form method="post" action="/p/%s/save">%s%s%s</form>'
                % (esc(pid), hidden("token", TOKEN), keep, body))


def all_pages_html(app):
    """Every page the app can show, for the accessibility check: [(where, html)]."""
    out = [("/", app.home()), ("/ (with notice)", app.home("Saved.", True))]
    for s in app.sources:
        for pid, _, _ in s.pages():
            out.append(("/p/" + pid, app.route("GET", "/p/" + pid)[1]))
            for q in getattr(s, "sample_queries", lambda p: [])(pid):
                out.append(("/p/%s?%s" % (pid, urllib.parse.urlencode(q)),
                            app.route("GET", "/p/" + pid, {k: [v] for k, v in q.items()})[1]))
            for f in getattr(s, "sample_forms", lambda p: [])(pid):
                f = dict({k: [v] if isinstance(v, str) else v for k, v in f.items()}, token=[TOKEN])
                out.append(("/p/%s/preview" % pid, app.route("POST", "/p/%s/preview" % pid, form_=f)[1]))
    if not any(s for s in app.sources if isinstance(s, LauncherPages)):
        return out
    bad = {"token": [TOKEN], "PORT": ["0"], "PROFILE": ["auto"], "EMBED_PORT": [""], "HOST": [""]}
    out.append(("/p/launch-network/preview (error)", app.route("POST", "/p/launch-network/preview", form_=bad)[1]))
    return out


def a11y_cli():
    from lib import a11y_check
    app = App(load_extra())
    n = bad = 0
    for where, page_html in all_pages_html(app):
        n += 1
        for p in a11y_check.problems(page_html):
            bad += 1
            sys.stdout.write("%s: %s\n" % (where, p))
    sys.stdout.write("panel: %d pages checked, %d problem(s)\n" % (n, bad))
    return 1 if bad else 0


LOCAL_HOSTS = ("127.0.0.1", "localhost", "[::1]")


def host_ok(host_header):
    """Only a browser that asked for 127.0.0.1/localhost (an ssh -L tunnel too) gets an answer.
    This blocks DNS rebinding: a web page cannot reach the panel under its own name."""
    h = (host_header or "").strip().lower()
    if h.startswith("["):
        name = h.split("]")[0] + "]"
    else:
        name = h.split(":")[0]
    return name in LOCAL_HOSTS


def origin_ok(origin):
    """A POST with an Origin header must come from a page the panel served itself."""
    if origin is None:
        return True  # old browsers send no Origin; the per-session form token still applies
    try:
        return host_ok(urllib.parse.urlparse(origin).netloc)
    except ValueError:
        return False


def parse_args(argv):
    port, open_browser, rest = PORT, False, []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-h", "--help"):
            print(__doc__.strip())
            raise SystemExit(0)
        if a == "--open":
            open_browser = True
        elif a == "--port" and i + 1 < len(argv) and argv[i + 1].isdigit():
            port = int(argv[i + 1])
            i += 1
        else:
            rest.append(a)
        i += 1
    return port, open_browser, rest


def main():
    port, open_browser, rest = parse_args(sys.argv[1:])
    code = cli(rest)
    if code is not None:
        raise SystemExit(code)
    from lib.lockmem import try_lock_process
    try_lock_process("panel.py")
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    app = App(load_extra())
    url = "http://%s:%d/" % (HOST, port)

    class Handler(BaseHTTPRequestHandler):
        server_version = "panel"

        def log_message(self, fmt, *args):
            return

        def send_page(self, status, body):
            data = body.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy",
                             "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(data)

        def guard(self):
            if not host_ok(self.headers.get("Host")):
                self.send_error(403, "panel answers only on 127.0.0.1 or localhost (use ssh -L for remote use)")
                return False
            return True

        def do_GET(self):
            if not self.guard():
                return
            u = urllib.parse.urlparse(self.path)
            if u.path == "/favicon.ico":
                self.send_error(404)
                return
            status, body = app.route("GET", u.path, urllib.parse.parse_qs(u.query))
            self.send_page(status, body)

        def do_POST(self):
            if not self.guard():
                return
            if not origin_ok(self.headers.get("Origin")):
                self.send_error(403, "cross-site form refused")
                return
            try:
                n = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                n = -1
            if n < 0 or n > MAX_BODY:
                self.send_error(413)
                return
            raw = self.rfile.read(n).decode("utf-8", "replace")
            form_ = urllib.parse.parse_qs(raw, keep_blank_values=True)
            path = urllib.parse.urlparse(self.path).path
            if path.endswith("/save") and (form_.get("do") or [""])[0] == "back":
                path = path[:-len("/save")]
            status, body = app.route("POST", path, form_=form_)
            self.send_page(status, body)

    try:
        httpd = ThreadingHTTPServer((HOST, port), Handler)
    except OSError as e:
        sys.stderr.write("panel: port %d is busy (%s). If the panel is already running, open %s\n"
                         "  Or pick another port: python3 scripts/panel.py --port 9933\n" % (port, e.strerror, url))
        if open_browser:
            _open(url)
        raise SystemExit(1)
    print("panel: %s  (this computer only; stop with Ctrl+C)" % url, flush=True)
    if open_browser:
        _open(url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


def _open(url):
    try:
        import webbrowser
        webbrowser.open(url)
    except Exception:  # noqa: BLE001 - a missing browser is not an error
        pass


if __name__ == "__main__":
    main()
