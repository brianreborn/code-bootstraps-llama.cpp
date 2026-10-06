"""Transaction record beside remote.json, and /local program launch.

tx.json lives in $AGENT_REMOTE_DIR, or in the checkout .cache, the same
directory remote.py uses for remote.json. A nested begin is a savepoint:
only the outermost commit is durable. snap is a name only; nothing here
opens a pool or deletes a declared path.
"""
import json
import os
import subprocess
import sys
import time

from lib import snap

WORDS = ("begin", "commit", "rollback", "status")
PROGRAMS = ("grok", "agy", "claude", "codex")
OUTCOMES = ("", "heuristic")


def _root():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def state_path():
    base = os.environ.get("AGENT_REMOTE_DIR")
    if not base:
        base = os.path.join(_root(), ".cache")
    return os.path.join(base, "tx.json")


def blank():
    return {"tx": []}


def _tighten(path, mode):
    try:
        os.chmod(path, mode)
    except OSError:
        pass


def _norm(rec):
    if not isinstance(rec, dict):
        return None
    state = rec.get("state")
    if state not in ("open", "committed", "rolledback"):
        return None
    parent = rec.get("parent")
    if parent is not None:
        parent = str(parent)
    writes = rec.get("writes")
    if not isinstance(writes, list):
        writes = []
    outcome = rec.get("outcome") if rec.get("outcome") in OUTCOMES else ""
    return {
        "name": str(rec.get("name") or ""),
        "state": state,
        "parent": parent,
        "snap": str(rec.get("snap") or ""),
        "writes": [str(w) for w in writes],
        "outcome": outcome,
    }


def load():
    try:
        with open(state_path(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return blank()
    rows = []
    for rec in data.get("tx") or []:
        norm = _norm(rec)
        if norm and norm["name"]:
            rows.append(norm)
    return {"tx": rows}


def save(data):
    path = state_path()
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    # Same privacy as a key file: the directory is the account's, the file is not group-readable.
    _tighten(directory, 0o700)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump({"tx": data.get("tx") or []}, f, separators=(",", ":"))
        f.write("\n")
    _tighten(tmp, 0o600)
    os.replace(tmp, path)
    _tighten(path, 0o600)


def _innermost_open(rows):
    found = None
    for rec in rows:
        if rec["state"] == "open":
            found = rec
    return found


def is_durable(rows, rec):
    """Committed, and every ancestor committed. An open parent keeps a savepoint provisional."""
    if not rec or rec.get("state") != "committed":
        return False
    by_name = {r["name"]: r for r in rows}
    parent = rec.get("parent")
    seen = set()
    while parent:
        if parent in seen:
            return False
        seen.add(parent)
        anc = by_name.get(parent)
        if not anc or anc.get("state") != "committed":
            return False
        parent = anc.get("parent")
    return True


def _stamp(rows):
    name = time.strftime("%Y%m%d%H%M%S")
    taken = {r["name"] for r in rows}
    if name not in taken:
        return name
    return f"{name}{time.time_ns() % 1000000:06d}"


def begin(name=""):
    data = load()
    parent_rec = _innermost_open(data["tx"])
    parent = parent_rec["name"] if parent_rec else None
    name = (name or "").strip()
    if not name:
        name = _stamp(data["tx"])
    if any(r["name"] == name for r in data["tx"]):
        print(f"tx: name {name} already used", file=sys.stderr)
        return 1
    snap_name = snap.create(name)
    # Slot dumps are skipped, and no process is stopped, when no server of ours is listening.
    snap.save_slots(snap_name)
    data["tx"].append({
        "name": name,
        "state": "open",
        "parent": parent,
        "snap": snap_name,
        "writes": [],
        "outcome": "",
    })
    save(data)
    print(f"begin {name} parent={'null' if parent is None else parent}")
    return 0


def declare_write(path):
    """Remember a path on the open transaction. Does not create, change, or remove it."""
    data = load()
    rec = _innermost_open(data["tx"])
    if not rec:
        print("tx: nothing open", file=sys.stderr)
        return 1
    path = str(path)
    # Before-image. Rollback does not put these bytes back.
    snap.capture(rec["snap"], path)
    if path not in rec["writes"]:
        rec["writes"].append(path)
    save(data)
    return 0


def set_outcome(outcome):
    if outcome not in OUTCOMES:
        print("tx: outcome must be empty or heuristic", file=sys.stderr)
        return 1
    data = load()
    rec = _innermost_open(data["tx"])
    if not rec:
        print("tx: nothing open", file=sys.stderr)
        return 1
    rec["outcome"] = outcome
    save(data)
    return 0


def commit():
    data = load()
    rec = _innermost_open(data["tx"])
    if not rec:
        print("tx: nothing open", file=sys.stderr)
        return 1
    rec["state"] = "committed"
    save(data)
    # Re-read durability after the mark: a savepoint stays provisional while its parent is open.
    print(f"commit {rec['name']} durable={'1' if is_durable(data['tx'], rec) else '0'}")
    return 0


def _under(rows, rec, ancestor):
    by_name = {r["name"]: r for r in rows}
    parent = rec.get("parent")
    seen = set()
    while parent:
        if parent == ancestor:
            return True
        if parent in seen:
            return False
        seen.add(parent)
        anc = by_name.get(parent)
        if not anc:
            return False
        parent = anc.get("parent")
    return False


def rollback():
    data = load()
    rec = _innermost_open(data["tx"])
    if not rec:
        print("tx: nothing open", file=sys.stderr)
        return 1
    # A savepoint drops itself. The outer transaction also drops every still-open child.
    # Declared paths are not unlinked, and snap is not a restore.
    targets = [rec]
    if rec.get("parent") is None:
        for other in data["tx"]:
            if other is not rec and other["state"] == "open" and _under(data["tx"], other, rec["name"]):
                targets.append(other)
    for item in targets:
        item["state"] = "rolledback"
        item["writes"] = []
    save(data)
    print(f"rollback {rec['name']}")
    return 0


def status():
    data = load()
    for rec in data["tx"]:
        parent = "null" if rec.get("parent") is None else rec["parent"]
        snap = rec.get("snap") or "-"
        print(f"{rec['name']} {rec['state']} {parent} {snap} writes={len(rec['writes'])} {rec.get('outcome') or '-'}")
    return 0


def _prefix(text):
    s = text.strip()
    for prefix in ("/local", "/remote"):
        if s == prefix or s.startswith(prefix + " ") or s.startswith(prefix + "\t"):
            return prefix, s[len(prefix):].strip()
    return "", ""


def dispatch_word(text):
    """Run begin/commit/rollback/status. None when the first word is not one of those."""
    prefix, rest = _prefix(text)
    if prefix not in ("/local", "/remote"):
        return None
    bits = rest.split()
    if not bits or bits[0] not in WORDS:
        return None
    head, tail = bits[0], bits[1:]
    if head == "begin":
        if len(tail) > 1:
            print("usage: begin [name]", file=sys.stderr)
            return 1
        return begin(tail[0] if tail else "")
    if tail:
        print(f"usage: {head}", file=sys.stderr)
        return 1
    if head == "commit":
        return commit()
    if head == "rollback":
        return rollback()
    return status()


def local_exec(text):
    """Run one allowed program as this user. FEELD_LOCAL_BIN is prepended to PATH for the child only."""
    _prefix_name, rest = _prefix(text)
    argv = rest.split()
    if not argv:
        print("usage: /local <grok|agy|claude|codex> [args...]", file=sys.stderr)
        return 1
    prog = argv[0]
    if prog not in PROGRAMS:
        print(f"tx: refusing {prog}", file=sys.stderr)
        return 1
    env = os.environ.copy()
    bindir = env.get("FEELD_LOCAL_BIN") or ""
    if bindir:
        env["PATH"] = bindir + os.pathsep + env.get("PATH", "")
    try:
        proc = subprocess.run(argv, env=env, capture_output=True, text=True)
    except FileNotFoundError:
        print(f"tx: {prog} not found", file=sys.stderr)
        return 1
    if proc.stdout:
        sys.stdout.write(proc.stdout)
    if proc.stderr:
        sys.stderr.write(proc.stderr)
    return proc.returncode
