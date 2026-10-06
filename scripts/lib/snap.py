"""Named snapshot for a transaction. The copy is the before-image.

A filesystem driver is used only when FEELD_SNAP_FS names one that exists.
Otherwise the snapshot is a directory of file bytes. kill -STOP is sent only
to pids this user owns, and never to this process.
"""
import json
import os
import shutil
import signal
import subprocess
import urllib.error
import urllib.request


def _root():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def base_dir():
    base = os.environ.get("AGENT_REMOTE_DIR")
    if not base:
        base = os.path.join(_root(), ".cache")
    path = os.path.join(base, "snaps")
    os.makedirs(path, exist_ok=True)
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass
    return path


def driver():
    """virtual unless the operator named a driver that is installed."""
    want = os.environ.get("FEELD_SNAP_FS", "").strip()
    if want in ("zfs", "btrfs", "bcachefs") and shutil.which(want):
        return want
    return "virtual"


def _safe_name(name):
    name = str(name)
    if not name or name in (".", "..") or "/" in name or "\\" in name:
        raise ValueError("snap name must be one path segment")
    return name


def create(name):
    """Make the snap directory and return its name. Does not copy the tree."""
    name = _safe_name(name)
    dest = os.path.join(base_dir(), name)
    os.makedirs(os.path.join(dest, "data"), exist_ok=True)
    try:
        os.chmod(dest, 0o700)
    except OSError:
        pass
    note = os.path.join(dest, "DRIVER")
    if not os.path.exists(note):
        with open(note, "w", encoding="utf-8") as f:
            f.write(driver() + "\n")
    return name


def capture(name, path):
    """Copy path's current bytes into the snap. A missing path is recorded, not created."""
    name = _safe_name(name)
    dest = os.path.join(base_dir(), name)
    os.makedirs(os.path.join(dest, "data"), exist_ok=True)
    data = os.path.join(dest, "data")
    # The snap must not archive itself.
    try:
        if os.path.commonpath([os.path.realpath(path), os.path.realpath(dest)]) == os.path.realpath(dest):
            return "skipped"
    except ValueError:
        pass
    n = str(len(os.listdir(data)))
    if os.path.isfile(path):
        shutil.copy2(path, os.path.join(data, n))
        status = "copied"
    else:
        status = "missing"
        n = "-"
    with open(os.path.join(dest, "MANIFEST"), "a", encoding="utf-8") as f:
        f.write(f"{path}\t{status}\t{n}\n")
    return status


def blob(name, index):
    return os.path.join(base_dir(), _safe_name(name), "data", str(index))


def _owned(pid):
    if pid == os.getpid():
        return False
    try:
        with open(f"/proc/{pid}/status", encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return False
    for line in text.splitlines():
        if line.startswith("Uid:"):
            return int(line.split()[1]) == os.getuid()
    return False


def freeze(pids):
    """SIGSTOP only pids owned by this user. Returns the pids that were stopped."""
    held = []
    for pid in pids:
        pid = int(pid)
        if not _owned(pid):
            continue
        os.kill(pid, signal.SIGSTOP)
        held.append(pid)
    return held


def thaw(pids):
    for pid in pids:
        try:
            os.kill(int(pid), signal.SIGCONT)
        except OSError:
            pass


def _state(pid):
    try:
        with open(f"/proc/{pid}/status", encoding="utf-8") as f:
            for line in f:
                if line.startswith("State:"):
                    return line.split()[1]
    except OSError:
        return ""
    return ""


def take_tree(name, src, pids=()):
    """STOP the given pids, copy src, then CONT them. src is a directory or a file."""
    name = create(name)
    dest = os.path.join(base_dir(), name, "tree")
    held = freeze(pids)
    try:
        if os.path.isdir(src):
            os.makedirs(dest, exist_ok=True)
            if shutil.which("rsync"):
                subprocess.run(
                    ["rsync", "-a", "--exclude", "snaps", src.rstrip("/") + "/", dest + "/"],
                    check=True,
                )
            else:
                for entry in os.listdir(src):
                    if entry == "snaps":
                        continue
                    item = os.path.join(src, entry)
                    target = os.path.join(dest, entry)
                    if os.path.isdir(item):
                        shutil.copytree(item, target, dirs_exist_ok=True)
                    else:
                        shutil.copy2(item, target)
        elif os.path.isfile(src):
            os.makedirs(dest, exist_ok=True)
            shutil.copy2(src, os.path.join(dest, os.path.basename(src)))
    finally:
        thaw(held)
    return name


def _note(name, text):
    path = os.path.join(base_dir(), _safe_name(name), "SLOTS")
    if not text.endswith("\n"):
        text += "\n"
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def _cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return f.read().replace(b"\0", b" ").decode(errors="replace")
    except OSError:
        return ""


def _ready(path):
    """Port and pid from serve.ready, only if that pid is ours and still alive."""
    try:
        with open(path, encoding="utf-8") as f:
            parts = f.read().split()
    except OSError:
        return None
    if len(parts) < 2 or not parts[0].isdigit() or not parts[1].isdigit():
        return None
    port, pid = int(parts[0]), int(parts[1])
    if not _owned(pid):
        return None
    try:
        os.kill(pid, 0)
    except OSError:
        return None
    if os.environ.get("FEELD_SNAP_ANY_PID") != "1" and "llama-server" not in _cmdline(pid):
        return None
    return port, pid


def _http(url, method, path, key, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url.rstrip("/") + path, data=data, method=method)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    if key:
        req.add_header("Authorization", "Bearer " + key)
    try:
        with urllib.request.urlopen(req, timeout=2) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:200]
        raise RuntimeError(detail or str(exc)) from exc


def save_slots(name, ready_file=None, slot_dir=None):
    """Save live slots, then STOP the server pid, copy the dumps, and CONT.

    No listening server of ours writes "no server" and does not stop anything.
    A server that refuses the save writes "no dump" and does not stop anything.
    """
    name = create(name)
    ready_file = ready_file or os.path.join(_root(), ".cache", "serve.ready")
    slot_dir = slot_dir or os.path.join(_root(), ".cache", "slot-dumps")
    found = _ready(ready_file)
    if not found:
        _note(name, "no server")
        return "no server"
    port, pid = found
    url = f"http://127.0.0.1:{port}"
    key = os.environ.get("LLAMA_API_KEY", "")
    try:
        _status, raw = _http(url, "GET", "/slots", key)
        slots = json.loads(raw.decode() or "[]")
    except (OSError, ValueError, RuntimeError) as exc:
        _note(name, f"no dump: {exc}")
        return "no dump"
    if not isinstance(slots, list):
        _note(name, "no dump: slots was not a list")
        return "no dump"
    saved = []
    for slot in slots:
        if not isinstance(slot, dict):
            continue
        sid = slot.get("id", slot.get("id_slot"))
        if sid is None:
            continue
        filename = f"slot-{sid}.bin"
        try:
            _http(url, "POST", f"/slots/{sid}?action=save", key, {"filename": filename})
        except (OSError, RuntimeError) as exc:
            _note(name, f"no dump: {exc}")
            return "no dump"
        saved.append(filename)
    held = freeze([pid])
    try:
        dest = os.path.join(base_dir(), name, "slots")
        os.makedirs(dest, exist_ok=True)
        for filename in saved:
            src = os.path.join(slot_dir, filename)
            if os.path.isfile(src):
                shutil.copy2(src, os.path.join(dest, filename))
    finally:
        thaw(held)
    _note(name, f"saved {len(saved)}")
    return "saved"
