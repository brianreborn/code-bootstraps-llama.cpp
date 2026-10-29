#!/usr/bin/env python3
"""Issue #77: every code path creates the per-port API key the same way (docs/api-key-design.md).
The shell (instance-key.sh), Python (snap.ensure_instance_key, used by cockpit.py, agent.py,
recover.py) and PowerShell (instance-key.ps1, used by serve.ps1 and open-ui.ps1) helpers must all
create ${XDG_CONFIG_HOME}/familia/instances/<port>/api-keys (dir 700, file 600) only when missing,
agree on one key under a concurrent first start, adopt the legacy key, never rotate, and still
work where hard links are refused (Android/Termux). Keys are compared, never printed."""
import os, shutil, stat, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "lib"))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
fails = []
def ok(c, m): print(("ok   " if c else "FAIL ") + m); (None if c else fails.append(m))
def mode(p): return stat.S_IMODE(os.stat(p).st_mode)
def first(p):
    for l in open(p, encoding="utf-8"):
        if l.strip() and not l.startswith("#"):
            return l.strip()
SH = '. "$ROOT/scripts/lib/instance-key.sh"; f=$(instance_key_file "$P"); instance_key_ensure "$f" "${LEG:-}" 2>/dev/null'

T = tempfile.mkdtemp()
old_env = dict(os.environ)
try:
    os.environ.update(XDG_CONFIG_HOME=os.path.join(T, "xdg"), HOME=T, ROOT=ROOT)
    for k in ("API_KEY_FILE", "LLAMA_API_KEY", "APPDATA"):
        os.environ.pop(k, None)
    import snap
    kf = lambda p: os.path.join(T, "xdg", "familia", "instances", str(p), "api-keys")

    # Python creates the same file the shell helper resolves, with the same modes
    ok(snap.instance_key_file(9941) == kf(9941), "python resolves the same per-port path as instance-key.sh")
    snap.ensure_instance_key(kf(9941))
    ok(mode(kf(9941)) == 0o600 and mode(os.path.dirname(kf(9941))) == 0o700, "python: file 600, dir 700")
    k = first(kf(9941)); ok(len(k) == 48, "python: 24-byte hex key like instance-key.sh")
    subprocess.run(["sh", "-c", SH], env=dict(os.environ, P="9941"), check=True)
    ok(first(kf(9941)) == k, "shell keeps the key python created (never rotated)")
    snap.ensure_instance_key(kf(9941)); ok(first(kf(9941)) == k, "python never rotates")
    ok(not [n for n in os.listdir(os.path.dirname(kf(9941))) if n.endswith(".tmp")], "no temp file left")

    # previously-missing paths: clients now create the per-port key instead of finding nothing
    import cockpit
    ok(cockpit.instance_key(9942) and os.path.isfile(kf(9942)), "cockpit.py creates the per-port key when missing")
    ok(cockpit.instance_key(9942) == first(kf(9942)), "cockpit.py: stable across calls")
    import agent
    ok(agent.default_key("http://127.0.0.1:9943") == first(kf(9943)), "agent.py creates the per-port key when missing")
    ok(snap.local_api_key() and os.path.isfile(kf(os.environ.get("PORT") or 9931)), "snap.local_api_key creates the default-port key")
    # explicit API_KEY_FILE override is used as given, never created by a client
    os.environ["API_KEY_FILE"] = os.path.join(T, "explicit-missing")
    snap.key_file_candidates(9944)
    ok(not os.path.exists(os.environ["API_KEY_FILE"]) and not os.path.exists(kf(9944)), "clients do not create an explicit API_KEY_FILE")
    del os.environ["API_KEY_FILE"]

    # concurrent first start: shell and python racers agree on one key
    def sh_racer(_):
        subprocess.run(["sh", "-c", SH], env=dict(os.environ, P="9945"), check=True)
    def py_racer(_):
        snap.ensure_instance_key(kf(9945))
    with ThreadPoolExecutor(12) as ex:
        list(ex.map(lambda i: (sh_racer if i % 2 else py_racer)(i), range(12)))
    ok(first(kf(9945)) is not None and mode(kf(9945)) == 0o600, "mixed shell/python race: one key, 600")

    # legacy checkout key adopted by python as by shell
    leg = os.path.join(T, "legacy-api-keys"); open(leg, "w").write("# old\nlegacy-" + os.urandom(4).hex() + "\n")
    snap.ensure_instance_key(kf(9946), leg)
    subprocess.run(["sh", "-c", SH], env=dict(os.environ, P="9947", LEG=leg), check=True)
    ok(first(kf(9946)) == first(leg) == first(kf(9947)), "legacy key adopted (python and shell)")

    # Android/Termux: link(2) is denied by SELinux, so ln always fails
    fake = os.path.join(T, "bin"); os.makedirs(fake)
    open(os.path.join(fake, "ln"), "w").write("#!/bin/sh\necho 'ln: Permission denied' >&2\nexit 1\n"); os.chmod(os.path.join(fake, "ln"), 0o755)
    nolink = dict(os.environ, P="9948", PATH=fake + os.pathsep + os.environ["PATH"])
    subprocess.run(["sh", "-c", SH], env=nolink, check=True)
    ok(os.path.isfile(kf(9948)) and first(kf(9948)) and mode(kf(9948)) == 0o600, "shell creates the key when hard links are refused (Termux)")
    k = first(kf(9948)); subprocess.run(["sh", "-c", SH], env=nolink, check=True)
    ok(first(kf(9948)) == k, "shell without hard links never overwrites")
    real_link = os.link
    def denied(*a, **kw): raise PermissionError(13, "Permission denied")
    os.link = denied
    try:
        snap.ensure_instance_key(kf(9949)); k = first(kf(9949)); snap.ensure_instance_key(kf(9949))
        ok(k and first(kf(9949)) == k and mode(kf(9949)) == 0o600, "python creates (once) when hard links are refused")
    finally:
        os.link = real_link

    # recover.py run by hand (no API_KEY_FILE) resolves and creates the per-port key
    import recover  # noqa: F401  (import only: its main() loops forever)
    from lib.snap import key_file_candidates
    ok(key_file_candidates(9950)[0] == kf(9950) and os.path.isfile(kf(9950)), "recover.py's resolver creates the per-port key")

    # PowerShell twin (serve.ps1, open-ui.ps1)
    pwsh = shutil.which("pwsh")
    if pwsh:
        ps = ('. "%s"; $f = Get-InstanceKeyFile 9951; Initialize-InstanceKey $f "%s" | Out-Null; '
              'Initialize-InstanceKey (Get-InstanceKeyFile 9952) "" | Out-Null; Write-Output $f') % (
            os.path.join(ROOT, "scripts", "lib", "instance-key.ps1"), leg)
        out = subprocess.run([pwsh, "-NoProfile", "-Command", ps], capture_output=True, text=True, check=True).stdout.strip().splitlines()[-1]
        ok(out == kf(9951) and first(kf(9951)) == first(leg), "pwsh: same path, legacy adopted")
        ok(mode(kf(9952)) == 0o600 and mode(os.path.dirname(kf(9952))) == 0o700 and len(first(kf(9952))) == 48, "pwsh: fresh key, 600/700")
        k = first(kf(9941))
        subprocess.run([pwsh, "-NoProfile", "-Command", '. "%s"; Initialize-InstanceKey (Get-InstanceKeyFile 9941) "" | Out-Null' % os.path.join(ROOT, "scripts", "lib", "instance-key.ps1")], check=True, capture_output=True)
        ok(first(kf(9941)) == k, "pwsh keeps an existing key (never rotated)")
    else:
        print("skip pwsh checks (pwsh not found)")
finally:
    os.environ.clear(); os.environ.update(old_env)
    shutil.rmtree(T, ignore_errors=True)
print("test_instance_key_paths: ok" if not fails else "%d failure(s)" % len(fails)); sys.exit(1 if fails else 0)
