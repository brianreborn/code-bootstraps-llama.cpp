#!/usr/bin/env python3
"""Model-selection audit: which models every launcher downloads and serves, per role.

    tests/model-selection-matrix.sh [WORKDIR]     (needs bash, pwsh for the Windows half,
                                                  and a llama-server binary for the router check)

For every combination of launcher x PROFILE x LANGUAGE_MODE x system locale x installed opt-ins
(plus TOOLS, explicit LOCALE, PROFILE=auto and env-override grids) it runs the REAL launcher
scripts in a throw-away copy of the repository with these stubs:
  - curl / curl.exe: records each Hugging Face URL and writes a placeholder whose text is the
    manifest sha256 of that file; sha256sum / Get-FileHash read it back. The selection logic
    (which entries, which directories, parking of other files) runs unchanged; the real
    sha256 values are checked against the Hugging Face API separately (--hf).
  - llama-server: records its argv and LLAMA_* environment and exits.
  - Windows (pwsh on Linux): Get-CimInstance, Get-Culture, scripts/fetch-llama.ps1, lib/open-ui.ps1.
  - macOS (start.command): uname, sysctl, defaults.  Termux: PREFIX, getprop.
Then the REAL pinned llama-server is started as a router on each distinct effective preset
(models are listed, never loaded) and GET /models gives the exact per-role child arguments
(-m path, ctx, parallel, threads, ngl). That is what the router would run.
Assertions (exit 1 on failure, WORKDIR/assertions.txt): the expected models per combination;
decoys (stray/mmproj/mtp/.part files, populated HF caches via LLAMA_CACHE, HF_HOME,
HF_HUB_CACHE and ~/.cache/huggingface) never add or change a model; model-picking flags are
refused in every spelling; env overrides work on every launcher; all launchers write the
same effective preset for the same settings; start.ps1/serve.ps1 also pass under a
Windows PowerShell 5.1 emulation (grid "ps51", tests/ps51_emulation.py).
"""
import concurrent.futures as cf
import hashlib
import itertools
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "/tmp/model-selection-matrix")
OPTS = set(a for a in sys.argv[1:] if a.startswith("-"))
PWSH = os.environ.get("PWSH") or shutil.which("pwsh")   # pwsh half is skipped when absent
MANIFEST = json.load(open(os.path.join(ROOT, "config", "models-manifest.json")))
CANDS = MANIFEST["candidates"]
SHORT = {"LFM2.5-1.2B-Instruct-Q4_K_M.gguf": "LFM2.5-1.2B", "Qwen3.5-2B-Q4_K_M.gguf": "Qwen3.5-2B",
         "Laya-Q8_0.gguf": "Laya-Q8", "LFM2.5-350M-Q4_K_M.gguf": "LFM2.5-350M",
         "Qwen3.5-0.8B-Q4_K_M.gguf": "Qwen3.5-0.8B", "Julia-1-Q8_0.gguf": "Julia-1",
         "Qwen3.5-4B-Q4_K_M.gguf": "Qwen3.5-4B", "HY-MT1.5-1.8B-Q4_K_M.gguf": "HY-MT1.5-1.8B",
         "Qwen3.5-0.8B-Japanese-SFT-v2-Q4_K_M.gguf": "JA-SFT-0.8B"}
DEFAULTS = {c["role"]: c["file"] for c in CANDS if c["pick"] == "default"}
REAL_LLAMA = None
for cand in [os.environ.get("REAL_LLAMA_SERVER", "")] + sorted(
        __import__("glob").glob(os.path.join(ROOT, "bin", "llama-b*-linux-x64-cpu", "llama-server"))):
    if cand and os.access(cand, os.X_OK):
        REAL_LLAMA = cand; break


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, check=True, **kw)


# ---------------------------------------------------------------- stubs
def write_stubs():
    st = os.path.join(WORK, "stubs"); mac = os.path.join(WORK, "stubs-mac"); termux = os.path.join(WORK, "stubs-termux")
    for d in (st, mac, termux):
        os.makedirs(d, exist_ok=True)
    with open(os.path.join(WORK, "shamap.txt"), "w") as f:
        for c in CANDS:
            f.write(f"{c['file']}\t{c['sha256']}\n")
    files = {
        f"{st}/curl": r'''#!/bin/bash
# stub: record Hugging Face/GitHub downloads, write "<sha256>" as the file; anything else fails
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; https://*|http://*) url="$1" ;; esac; shift; done
if [ -n "$out" ] && [[ "$url" == https://huggingface.co/* ]]; then
  echo "$url" >> "$CAPTURE_DIR/downloads.txt"
  f="${url##*/}"; sha="$(awk -F'\t' -v f="$f" '$1==f {print $2; exit}' "$SHAMAP")"
  printf '%s\n' "${sha:-0000000000000000000000000000000000000000000000000000000000000000}" > "$out"; exit 0
fi
[ -n "$url" ] && echo "$url" >> "$CAPTURE_DIR/other-curl.txt"
exit 7
''',
        f"{st}/sha256sum": '#!/bin/bash\nfor f; do printf "%s  %s\\n" "$(head -c 64 "$f")" "$f"; done\n',
        f"{st}/llama-server-stub": r'''#!/bin/bash
# stub router: record argv, LLAMA_* environment and the effective preset, then exit
printf '%s\n' "$@" > "$CAPTURE_DIR/argv.txt"
env | grep -E '^(LLAMA_|HF_|HUGGINGFACE_|XDG_CACHE_HOME=|HOME=|MODEL_ENDPOINT)' | sort > "$CAPTURE_DIR/env.txt"
prev=""; for a in "$@"; do [ "$prev" = "--models-preset" ] && cp "$a" "$CAPTURE_DIR/preset.ini"; prev="$a"; done
exit 0
''',
        f"{st}/icacls": '#!/bin/bash\nexit 0\n',   # ps51 grid: Test-Windows is true there
        f"{mac}/uname": '#!/bin/bash\ncase "$1" in -m) echo arm64 ;; -o) echo Darwin ;; *) echo Darwin ;; esac\n',
        f"{mac}/sysctl": '''#!/bin/bash
case "$2" in hw.memsize) echo 17179869184 ;; hw.physicalcpu) echo 8 ;; hw.perflevel0.physicalcpu) echo 4 ;;
  hw.logicalcpu) echo 8 ;; hw.optional.arm64) echo 1 ;; *) exit 1 ;; esac
''',
        f"{mac}/defaults": '#!/bin/bash\n[ -n "$FAKE_APPLE_LOCALE" ] && { echo "$FAKE_APPLE_LOCALE"; exit 0; }; exit 1\n',
        f"{termux}/getprop": '#!/bin/bash\ncase "$1" in persist.sys.locale) echo "$FAKE_ANDROID_LOCALE" ;; *) echo "" ;; esac\n',
    }
    for p, body in files.items():
        with open(p, "w") as f:
            f.write(body)
        os.chmod(p, 0o755)
    shutil.copy(f"{st}/curl", f"{st}/curl.exe")
    pf = os.path.join(WORK, "stubs-pwshfile"); os.makedirs(pf, exist_ok=True)
    with open(os.path.join(pf, "Get-CimInstance.ps1"), "w") as f:
        f.write('param([Parameter(Position=0)][string]$ClassName)\n'
                'if ($ClassName -eq "Win32_Processor") { [pscustomobject]@{NumberOfCores=8;NumberOfLogicalProcessors=8} }\n'
                'else { [pscustomobject]@{TotalPhysicalMemory=[double]16790638592} }\n')
    return st, mac, termux


# ---------------------------------------------------------------- sandboxes
def placeholder(path, file):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sha = next(c["sha256"] for c in CANDS if c["file"] == file)
    with open(path, "w") as f:
        f.write(sha + "\n")


def make_sandbox(d, install, prefetched, extra=None, ps51=False):
    os.makedirs(d)
    for n in ("config", "scripts"):
        shutil.copytree(os.path.join(ROOT, n), os.path.join(d, n), ignore=shutil.ignore_patterns("__pycache__"))
    if ps51:   # Windows PowerShell 5.1: no $IsWindows / $IsLinux / $IsMacOS (tests/ps51_emulation.py)
        sys.path.insert(0, os.path.join(ROOT, "tests")); __import__("ps51_emulation").rewrite(os.path.join(d, "scripts"))
    for n in ("start.sh", "start.command", "start.bat"):
        shutil.copy2(os.path.join(ROOT, n), d)
    # Windows: the binary is not the subject here, and the UI opener would poll for 10 minutes
    with open(os.path.join(d, "scripts", "fetch-llama.ps1"), "w") as f:
        f.write('Write-Output $env:STUB_LLAMA\n')
    with open(os.path.join(d, "scripts", "lib", "open-ui.ps1"), "w") as f:
        f.write('param([int]$Port, [switch]$NoBrowser, [switch]$CopyKey, [int]$ParentPid)\n')
    os.makedirs(os.path.join(d, "models"))
    if prefetched:   # serve.sh / serve.ps1 run alone: the defaults are already installed
        for role, file in DEFAULTS.items():
            placeholder(os.path.join(d, "models", role, file), file)
    if install == "optin":   # after fetch-models --locale ja and --language
        placeholder(os.path.join(d, "models-optional/locale/ja/Qwen3.5-0.8B-Japanese-SFT-v2-Q4_K_M.gguf"),
                    "Qwen3.5-0.8B-Japanese-SFT-v2-Q4_K_M.gguf")
        placeholder(os.path.join(d, "models-optional/language/HY-MT1.5-1.8B-Q4_K_M.gguf"), "HY-MT1.5-1.8B-Q4_K_M.gguf")
    if extra:
        extra(d)
    os.makedirs(os.path.join(d, "capture"))
    return d


# ---------------------------------------------------------------- jobs
LAUNCHERS = ["start.sh", "serve.sh", "start.command", "termux", "start.ps1", "serve.ps1"]
PROFILES = ["default", "lowram"]
MODES = ["(unset)", "native", "swap", "interpret", "off", "auto"]
LOCALES = ["en_US", "ja_JP", "ja-JP", "ja_JP.UTF-8", "Japanese_Japan.932", "zh_CN", "zh-Hant-TW", "de_DE", "C", "(unset)"]
INSTALLS = ["defaults", "optin"]


def job(launcher, profile="default", mode="(unset)", locale="(unset)", install="defaults", tools="auto",
        explicit_locale=None, grid="main", mem=None, env_extra=None, args_extra=None, extra=None, label=""):
    return dict(launcher=launcher, profile=profile, mode=mode, locale=locale, install=install, tools=tools,
                explicit_locale=explicit_locale, grid=grid, mem=mem, env_extra=env_extra or {},
                args_extra=args_extra or [], extra=extra, label=label, ps51=(grid == "ps51"))


def jobs_all():
    J = []
    for l, p, m, loc, i in itertools.product(LAUNCHERS, PROFILES, MODES, LOCALES, INSTALLS):
        J.append(job(l, p, m, loc, i))
    for l, t, p, m in itertools.product(LAUNCHERS, ["auto", "full", "lean", ""], PROFILES, ["native", "swap"]):
        J.append(job(l, p, m, "ja_JP", "optin", tools=t, grid="tools"))
    for l, el, m in itertools.product(LAUNCHERS, ["ja", "ja-JP", "JA_jp", "Japanese_Japan.932", "zh-TW", "de", "en"], ["native", "swap", "interpret"]):
        J.append(job(l, "default", m, "en_US", "optin", explicit_locale=el, grid="locale-env"))
    for l, mem, loc in itertools.product(LAUNCHERS, [4 * 2**30, 16 * 2**30], ["en_US", "ja_JP"]):
        if l.endswith(".ps1") or mem == 16 * 2**30:
            J.append(job(l, "auto", "(unset)", loc, "defaults", mem=mem, grid="profile-auto"))
    # Windows PowerShell 5.1 emulation (Windows code paths taken, 6+ variables absent)
    for l, p, m, loc in itertools.product(["start.ps1", "serve.ps1"], PROFILES, ["(unset)", "swap", "interpret", "auto"], ["en-US", "ja-JP"]):
        J.append(job(l, p, m, loc, "optin", grid="ps51"))
    return J


def decoy_extra(kind):
    def f(d):
        m = os.path.join(d, "models")
        if kind == "role-dir":       # two extra .gguf in the coder directory
            # several names, so the directory order puts a decoy last at least once (the router
            # takes the LAST non-mmproj .gguf it sees; NTFS lists alphabetically, ext4 by hash)
            for nm in ("aaa-decoy.gguf", "zzz-decoy.gguf", "Qwen3.5-4B-Q4_K_M.gguf", "decoy-1.gguf", "decoy-2.gguf"):
                placeholder(os.path.join(m, "coder", nm), "Qwen3.5-0.8B-Q4_K_M.gguf")
        elif kind == "top-level":    # a .gguf directly in models/
            placeholder(os.path.join(m, "decoy.gguf"), "Qwen3.5-0.8B-Q4_K_M.gguf")
        elif kind == "extra-dir":    # a new subdirectory
            placeholder(os.path.join(m, "extra", "decoy.gguf"), "Qwen3.5-0.8B-Q4_K_M.gguf")
        elif kind == "mmproj":       # a projector-named file in a role directory (never parked)
            placeholder(os.path.join(m, "coder", "decoy-mmproj-F16.gguf"), "Qwen3.5-0.8B-Q4_K_M.gguf")
        elif kind == "draft":        # a speculative-draft-named file (mtp-*)
            placeholder(os.path.join(m, "coder", "mtp-decoy.gguf"), "Qwen3.5-0.8B-Q4_K_M.gguf")
        elif kind == "stale-part":   # leftovers of an interrupted / failed download
            placeholder(os.path.join(m, "coder", "Qwen3.5-0.8B-Q4_K_M.gguf.part"), "Qwen3.5-0.8B-Q4_K_M.gguf")
            placeholder(os.path.join(m, "coder", "old.gguf.bad"), "Qwen3.5-0.8B-Q4_K_M.gguf")
        elif kind == "inactive":     # a parked model from an earlier --fallback
            placeholder(os.path.join(d, "models-inactive", "coder", "Qwen3.5-0.8B-Q4_K_M.gguf"), "Qwen3.5-0.8B-Q4_K_M.gguf")
        elif kind == "language-dir":  # a decoy next to HY-MT in the interpreter directory
            placeholder(os.path.join(d, "models-optional", "language", "AAA-decoy.gguf"), "Qwen3.5-0.8B-Q4_K_M.gguf")
        elif kind == "fallback-installed":  # user ran fetch-models --fallback earlier (0.8B coder active)
            for role in ("coder",):
                shutil.rmtree(os.path.join(m, role), ignore_errors=True)
                placeholder(os.path.join(m, role, "Qwen3.5-0.8B-Q4_K_M.gguf"), "Qwen3.5-0.8B-Q4_K_M.gguf")
                placeholder(os.path.join(d, "models-inactive", role, DEFAULTS[role]), DEFAULTS[role])
        elif kind in ("hf-cache", "hf-home", "hf-hub-cache", "home-hf-cache"):
            base = {"hf-cache": "hfcache", "hf-home": "hfhome/hub", "hf-hub-cache": "hfhub",
                    "home-hf-cache": "home/.cache/huggingface/hub"}[kind]
            c = os.path.join(d, base, "models--someorg--Decoy-GGUF")
            os.makedirs(os.path.join(c, "refs")); rev = "0123456789abcdef0123456789abcdef01234567"   # the cache needs a 40-hex commit
            open(os.path.join(c, "refs", "main"), "w").write(rev)
            placeholder(os.path.join(c, "snapshots", rev, "Decoy-Q4_K_M.gguf"), "Qwen3.5-0.8B-Q4_K_M.gguf")
    return f


def jobs_decoy():
    J = []
    kinds = ["role-dir", "top-level", "extra-dir", "mmproj", "draft", "stale-part", "inactive", "fallback-installed",
             "hf-cache", "hf-home", "hf-hub-cache", "home-hf-cache"]
    for l, k in itertools.product(["start.sh", "serve.sh", "start.ps1", "serve.ps1"], kinds):
        e = {"hf-cache": {"LLAMA_CACHE": "@SANDBOX@/hfcache"}, "hf-home": {"HF_HOME": "@SANDBOX@/hfhome"},
             "hf-hub-cache": {"HF_HUB_CACHE": "@SANDBOX@/hfhub"}, "home-hf-cache": {"HOME": "@SANDBOX@/home"}}.get(k, {})
        J.append(job(l, "default", "(unset)", "en_US", "defaults", grid="decoy", extra=k, env_extra=e, label=k))
    for l in ["start.sh", "serve.sh", "start.ps1", "serve.ps1"]:
        J.append(job(l, "default", "interpret", "ja_JP", "optin", grid="decoy", extra="language-dir", label="language-dir"))
    return J


def jobs_env():
    J = []
    cases = [("LLAMA_ARG_MODEL", {"LLAMA_ARG_MODEL": "/tmp/decoy.gguf"}, []),
             ("LLAMA_ARG_HF_REPO", {"LLAMA_ARG_HF_REPO": "someorg/Decoy-GGUF:Q4_K_M"}, []),
             ("HF_ENDPOINT+MODEL_ENDPOINT", {"HF_ENDPOINT": "https://evil.example", "MODEL_ENDPOINT": "https://evil.example"}, []),
             ("MODELS_MAX=3", {"MODELS_MAX": "3"}, []),
             ("PROFILE=lowram env", {"PROFILE": "lowram"}, []),
             ("passthrough -m", {}, ["-m", "/tmp/decoy.gguf"]),
             ("passthrough --model", {}, ["--model", "/tmp/decoy.gguf"]),
             ("passthrough -hf", {}, ["-hf", "someorg/Decoy-GGUF:Q4_K_M"]),
             ("passthrough --ctx-size", {}, ["--ctx-size", "2048"]),
             ("passthrough --models-preset", {}, ["--models-preset", "/tmp/x.ini"]),
             ("passthrough --models-dir", {}, ["--models-dir", "@SANDBOX@/other-models"]),
             ("passthrough --hf-repo", {}, ["--hf-repo", "someorg/Decoy-GGUF:Q4_K_M"]),
             ("passthrough -mu", {}, ["-mu", "https://example.invalid/decoy.gguf"]),
             ("passthrough --models_preset", {}, ["--models_preset", "/tmp/x.ini"]),
             ("passthrough --MODEL=x", {}, ["--MODEL=/tmp/decoy.gguf"]),
             ("passthrough --Hf_Repo", {}, ["--Hf_Repo", "someorg/Decoy-GGUF:Q4_K_M"]),
             ("passthrough --Api_Key", {}, ["--Api_Key", "x"]),
             ("passthrough --tools", {}, ["--tools", "read_file"])]
    for l in ["start.sh", "serve.sh", "start.ps1", "serve.ps1"]:
        for name, env, args in cases:
            if name == "PROFILE=lowram env":
                J.append(job(l, "(env)", "(unset)", "en_US", "defaults", grid="env", env_extra=env, label=name))
            else:
                J.append(job(l, "default", "(unset)", "en_US", "defaults", grid="env", env_extra=env, args_extra=args, label=name))
    for l in ["start.ps1", "serve.ps1"]:   # a negative value after a serve.ps1 parameter (start.ps1 routes it)
        J.append(job(l, "default", "(unset)", "en_US", "defaults", grid="env", args_extra=["-GpuLayers", "-1"], label="ps -GpuLayers -1"))
    for l in ["start.sh", "serve.sh"]:   # sh-only overrides
        J.append(job(l, "default", "(unset)", "en_US", "defaults", grid="env", label="MODELS_DIR=other",
                     env_extra={"MODELS_DIR": "@SANDBOX@/other-models"},
                     extra="other-models"))
        J.append(job(l, "default", "(unset)", "en_US", "defaults", grid="env", label="MODELS_PRESET=other",
                     env_extra={"MODELS_PRESET": "@SANDBOX@/other.ini"}, extra="other-preset"))
        J.append(job(l, "default", "(unset)", "en_US", "defaults", grid="env", label="MANIFEST=other",
                     env_extra={"MANIFEST": "@SANDBOX@/other-manifest.json"}, extra="other-manifest"))
    return J


def other_extra(kind):
    def f(d):
        if kind == "other-models":   # a complete second model set whose coder is the 0.8B fallback
            placeholder(os.path.join(d, "other-models", "coder", "Qwen3.5-0.8B-Q4_K_M.gguf"), "Qwen3.5-0.8B-Q4_K_M.gguf")
            for role in ("general", "decision"):
                placeholder(os.path.join(d, "other-models", role, DEFAULTS[role]), DEFAULTS[role])
        elif kind == "other-preset":
            with open(os.path.join(d, "other.ini"), "w") as fh:
                fh.write("version = 1\n[coder]\nmodel = /tmp/decoy.gguf\n")
        elif kind == "other-manifest":
            m = json.load(open(os.path.join(d, "config", "models-manifest.json")))
            for c in m["candidates"]:
                if c["pick"] == "fallback" and c["role"] == "coder":
                    c["pick"] = "default"
                elif c["pick"] == "default" and c["role"] == "coder":
                    c["pick"] = "x"
            with open(os.path.join(d, "other-manifest.json"), "w") as fh:
                json.dump(m, fh, indent=2)
    return f


# ---------------------------------------------------------------- running
def prepare(j, n, stubs):
    st, mac, termux = stubs
    d = os.path.join(WORK, "sb", f"{n:05d}")
    prefetched = j["launcher"] in ("serve.sh", "serve.ps1")
    ex = None
    if j["label"] == "passthrough --models-dir":
        ex = other_extra("other-models")
    elif j["extra"] in ("other-models", "other-preset", "other-manifest"):
        ex = other_extra(j["extra"])
    elif j["extra"]:
        ex = decoy_extra(j["extra"])
    make_sandbox(d, j["install"], prefetched, ex, ps51=j["ps51"])
    cap = os.path.join(d, "capture")
    env = {k: v.replace("@SANDBOX@", d) for k, v in j["env_extra"].items()}
    env.update({"CAPTURE_DIR": cap, "SHAMAP": os.path.join(WORK, "shamap.txt"), "NO_BROWSER": "1"})
    if j["mode"] != "(unset)":
        env["LANGUAGE_MODE"] = j["mode"]
    if j["explicit_locale"] is not None:
        env["LOCALE"] = j["explicit_locale"]
    port = str(30000 + n)
    j.update(sandbox=d, capture=cap, port=port)
    if j["launcher"].endswith(".ps1") and j["args_extra"]:
        # llama-server flags: run exactly as start.bat / a terminal does (pwsh -File), since
        # in-process invocation binds them differently. Get-CimInstance comes from a script on
        # PATH; the models are pre-installed with fresh stamps so no hashing is needed.
        stamps = os.path.join(d, ".cache", "verified"); os.makedirs(stamps, exist_ok=True)
        for role, file in DEFAULTS.items():
            pth = os.path.join(d, "models", role, file)
            if not os.path.exists(pth):
                placeholder(pth, file)
            st_ = os.stat(pth)
            sha = next(c["sha256"] for c in CANDS if c["file"] == file)
            open(os.path.join(stamps, sha), "w").write(f"{st_.st_size} {int(st_.st_mtime)}\n")
        stub = os.path.join(d, "llama-server-stub")
        shutil.copy(os.path.join(st, "llama-server-stub"), stub)
        env.update({"STUB_LLAMA": stub, "PATH": os.path.join(WORK, "stubs-pwshfile") + ":" + st + ":" + os.environ["PATH"],
                    "HOME": os.environ.get("HOME", "/tmp")})
        cmd = [PWSH, "-NoProfile", "-File", os.path.join(d, "scripts", j["launcher"]), "-Port", port, "-ToolsRuntime", "host"]
        if j["launcher"] == "serve.ps1":
            cmd += ["-LlamaServer", stub]
        j["sh"] = dict(cmd=cmd + [a.replace("@SANDBOX@", d) for a in j["args_extra"]], env=env)
        return j
    if j["launcher"].endswith(".ps1"):
        env["STUB_LLAMA"] = os.path.join(st, "llama-server-stub")
        argl = [f"-Port {port}", "-ToolsRuntime host"]
        if j["profile"] in ("default", "lowram", "auto"):
            argl.append(f"-RamProfile {j['profile']}")
        if j["tools"] != "auto":
            argl.append(f"-Tools '{j['tools']}'")
        if j["launcher"] == "serve.ps1":
            argl.append(f"-LlamaServer '{env['STUB_LLAMA']}'")
        argl += j["args_extra"]   # unquoted: parsed as on the start.bat / serve.ps1 command line
        culture = "" if j["locale"] in ("(unset)",) else j["locale"]
        j["ps"] = dict(sandbox=d, script="scripts/start.ps1" if j["launcher"] == "start.ps1" else "scripts/serve.ps1",
                       argline=" ".join(argl), env=env, mem=j["mem"] or 16397616 * 1024, culture=culture, stubs=st)
        return j
    # bash launchers
    base = {k: os.environ[k] for k in ("HOME", "TERM") if k in os.environ and k not in env}
    path = st + ":" + os.environ["PATH"]
    env.update(base)
    env.update({"PORT": port, "TOOLS_RUNTIME": "host", "LLAMA_SERVER": os.path.join(st, "llama-server-stub")})
    if j["profile"] in ("default", "lowram", "auto"):
        env["PROFILE"] = j["profile"]
    if j["tools"] != "auto":
        env["TOOLS"] = j["tools"]
    loc = "" if j["locale"] == "(unset)" else j["locale"]
    if j["launcher"] == "start.command":
        path = mac + ":" + path
        if loc: env["FAKE_APPLE_LOCALE"] = loc
        cmd = ["/bin/bash", os.path.join(d, "start.command")]
    elif j["launcher"] == "termux":
        path = termux + ":" + path
        env["PREFIX"] = "/data/data/com.termux/files/usr"
        if loc: env["FAKE_ANDROID_LOCALE"] = loc
        cmd = ["bash", os.path.join(d, "start.sh")]
    else:
        if loc: env["LANG"] = loc
        cmd = ["bash", os.path.join(d, "start.sh" if j["launcher"] == "start.sh" else "scripts/serve.sh")] + [a.replace("@SANDBOX@", d) for a in j["args_extra"]]
    env["PATH"] = path
    j["sh"] = dict(cmd=cmd, env=env)
    return j


def run_sh(j):
    # output to a file, not a pipe: start.sh's UI helper keeps the pipe open until it sees
    # serve.sh gone, and a pipe reader would only reap serve.sh after EOF
    with open(os.path.join(j["capture"], "output.txt"), "w") as f:
        r = subprocess.run(j["sh"]["cmd"], env=j["sh"]["env"], cwd=j["sandbox"], stdout=f, stderr=subprocess.STDOUT, timeout=120)
    text = open(os.path.join(j["capture"], "output.txt")).read()
    status = "ok" if r.returncode == 0 else "error: " + " ".join(
        [l for l in text.splitlines() if re.search(r"serve\.sh:|start:|fetch-models\.sh:.*(mismatch|no manifest)|not allowed", l)
         and ("WARNING" not in l)][-1:] or
        [re.sub(r"\x1b\[[0-9;]*m", "", m.group(0)) for m in [re.search(
            r"(Cannot validate argument on parameter '\w+'|parameter name '[^']*' is ambiguous|"
            r"Cannot process argument transformation on parameter '\w+'|A positional parameter cannot be found[^\n.]*)", text)] if m] or
        [f"exit {r.returncode}"])
    j["rc"] = r.returncode
    with open(os.path.join(j["capture"], "status.txt"), "w") as f:
        f.write(status)


def run_ps(jobs):
    if not jobs:
        return
    if not PWSH:
        for j in jobs:
            open(os.path.join(j["capture"], "status.txt"), "w").write("skipped: pwsh not found")
        return
    chunks = [jobs[i::4] for i in range(4)]   # 4 pwsh processes (also shows per-process hash order)
    procs = []
    for i, ch in enumerate(chunks):
        p = os.path.join(WORK, f"jobs-{i}.json")
        json.dump([j["ps"] for j in ch], open(p, "w"))
        procs.append(subprocess.Popen([PWSH, "-NoProfile", "-File", os.path.join(ROOT, "tests", "model-selection-matrix.ps1"), "-Jobs", p],
                                      stdout=subprocess.DEVNULL, stderr=open(os.path.join(WORK, f"pwsh-{i}.err"), "w")))
    for p in procs:
        p.wait()


# ---------------------------------------------------------------- results
def norm_preset(text, d):
    return text.replace(d, "<ROOT>") if text else ""


def parse_preset(text):
    secs, cur = {}, None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(";"):
            continue
        m = re.match(r"^\[(.*)\]$", line)
        if m:
            cur = m.group(1); secs.setdefault(cur, {}); continue
        m = re.match(r"^([A-Za-z0-9_-]+)\s*=\s*(.*)$", line)
        if m and cur is not None:
            secs[cur][m.group(1)] = m.group(2)
    return secs


def collect(j):
    c = j["capture"]
    rd = lambda n: open(os.path.join(c, n)).read() if os.path.exists(os.path.join(c, n)) else ""
    j["status"] = rd("status.txt").strip() or "error: no status"
    j["downloads"] = [l for l in rd("downloads.txt").splitlines() if l]
    j["argv"] = [l for l in rd("argv.txt").splitlines()]
    j["envcap"] = rd("env.txt")
    j["preset"] = norm_preset(rd("preset.ini"), j["sandbox"])
    j["output"] = rd("output.txt")
    lj = os.path.join(j["sandbox"], ".cache", "language.json")
    j["language_json"] = json.load(open(lj)) if os.path.exists(lj) else None
    tree = []
    for base in ("models", "models-optional", "models-inactive"):
        for dp, _, fs in os.walk(os.path.join(j["sandbox"], base)):
            for fn in fs:
                tree.append(os.path.relpath(os.path.join(dp, fn), j["sandbox"]))
    j["tree"] = sorted(tree)
    if j["status"] == "ok" and not j["argv"]:
        j["status"] = "ok (no server started)"


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def router_resolve(j):
    """start the real router with the captured argv/env and read GET /models (nothing is loaded)"""
    if not REAL_LLAMA or not j["argv"]:
        return None
    for _ in range(3):   # a random free port can be taken in between: retry
        r = _router_resolve(j)
        if not (isinstance(r, dict) and "HTTP server error" in str(r.get("error", ""))):
            return r
    return r


def _router_resolve(j):
    argv = list(j["argv"])
    port = free_port()
    for i, a in enumerate(argv):
        if a == "--port":
            argv[i + 1] = str(port)
    # HOME defaults to an empty directory, so the box's own ~/.cache/huggingface never shows up;
    # LLAMA_CACHE / HF_* / HOME come from what the launcher really exported (envcap)
    env = {"PATH": os.environ["PATH"], "HOME": os.path.join(WORK, "empty-home"), "LLAMA_API_KEY": "audit-key"}
    os.makedirs(env["HOME"], exist_ok=True)
    for line in j["envcap"].splitlines():
        k, _, v = line.partition("=")
        if k.startswith("LLAMA_ARG_") or k in ("LLAMA_CACHE", "HF_ENDPOINT", "MODEL_ENDPOINT", "HF_HOME", "HF_HUB_CACHE",
                                               "HUGGINGFACE_HUB_CACHE", "XDG_CACHE_HOME", "HOME"):
            env[k] = v
    log = open(os.path.join(j["capture"], "router.log"), "w")
    p = subprocess.Popen([REAL_LLAMA] + argv, env=env, cwd=j["sandbox"], stdout=log, stderr=subprocess.STDOUT,
                         start_new_session=True)
    data = None
    try:
        for _ in range(100):
            if p.poll() is not None:
                break
            try:
                req = urllib.request.Request(f"http://127.0.0.1:{port}/models", headers={"Authorization": "Bearer audit-key"})
                data = json.load(urllib.request.urlopen(req, timeout=2)); break
            except Exception:
                time.sleep(0.1)
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGTERM)
            try: p.wait(5)
            except subprocess.TimeoutExpired: os.killpg(p.pid, signal.SIGKILL)
        log.close()
    if data is None:
        tail = open(os.path.join(j["capture"], "router.log")).read().strip().splitlines()[-1:]
        return {"error": tail[0] if tail else "router did not answer"}
    out = {}
    for m in data.get("data", []):
        args = m.get("status", {}).get("args", [])
        out[m["id"]] = {"args": args, "source": m.get("source")}
    return out


def argval(args, *names):
    for i, a in enumerate(args):
        if a in names and i + 1 < len(args):
            return args[i + 1]
    return None


def role_view(res, role, sandbox):
    if not res or "error" in res or role not in res:
        return None
    a = res[role]["args"]
    mp = argval(a, "-m", "--model")
    return {"model": os.path.basename(mp) if mp else None, "model_path": (mp or "").replace(sandbox, "<ROOT>"),
            "ctx": argval(a, "-c", "--ctx-size"), "np": argval(a, "-np", "--parallel"),
            "kvslot": argval(a, "--kv-unified-per-slot"), "t": argval(a, "-t", "--threads"),
            "tb": argval(a, "-tb", "--threads-batch"), "ngl": argval(a, "-ngl", "--n-gpu-layers", "--gpu-layers"),
            "mmproj": argval(a, "-mm", "--mmproj"), "draft": argval(a, "-md", "--model-draft", "--spec-draft-model"),
            "hf": argval(a, "-hf", "--hf-repo")}


# ---------------------------------------------------------------- main
def main():
    if os.path.exists(WORK):
        shutil.rmtree(WORK)
    os.makedirs(os.path.join(WORK, "sb"))
    stubs = write_stubs()
    J = jobs_all() + jobs_decoy() + jobs_env()
    if "--smoke" in OPTS:   # a few combinations per launcher, for checking the harness itself
        J = [j for j in J if j["grid"] == "main" and j["profile"] == "lowram" and j["locale"] in ("ja-JP", "en_US")
             and j["mode"] in ("swap", "(unset)") and j["install"] == "optin"] + [j for j in J if j["grid"] == "decoy" and j["label"] == "role-dir"]
    t0 = time.time()
    for n, j in enumerate(J):
        prepare(j, n, stubs)
    print(f"[matrix] {len(J)} combinations prepared in {time.time() - t0:.0f}s", file=sys.stderr)
    shj = [j for j in J if "sh" in j]; psj = [j for j in J if "ps" in j]
    t0 = time.time()
    with cf.ThreadPoolExecutor(6) as ex:
        fut = ex.submit(run_ps, psj)
        list(ex.map(run_sh, shj))
        fut.result()
    print(f"[matrix] ran {len(shj)} bash + {len(psj)} pwsh combinations in {time.time() - t0:.0f}s", file=sys.stderr)
    for j in J:
        collect(j)
    # router resolution, once per distinct (argv minus port, env, preset, model tree)
    cache = {}
    t0 = time.time()
    for j in J:
        if not j["argv"]:
            j["router"] = None; continue
        av = [a.replace(j["sandbox"], "<ROOT>") for a in j["argv"]]
        av = [x for i, x in enumerate(av) if not (i > 0 and av[i - 1] == "--port")]
        key = hashlib.sha256(json.dumps([av, j["envcap"].replace(j["sandbox"], "<ROOT>"), j["preset"], j["tree"]]).encode()).hexdigest()
        if key not in cache:
            cache[key] = router_resolve(j)
        res = cache[key]
        j["router_key"] = key[:8]
        j["router"] = res
    print(f"[matrix] {len(cache)} distinct router configurations checked with {REAL_LLAMA} in {time.time() - t0:.0f}s", file=sys.stderr)
    out = []
    for j in J:
        res = j.get("router")
        roles = {r: role_view(res, r, j["sandbox"]) for r in ("general", "coder", "decision", "language")}
        extra = sorted(k for k in (res or {}) if k not in ("general", "coder", "decision", "language", "error"))
        out.append({k: j[k] for k in ("launcher", "profile", "mode", "locale", "install", "tools", "explicit_locale", "grid",
                                     "mem", "label", "status", "downloads", "argv", "preset", "language_json", "tree")}
                   | {"envcap": j["envcap"].replace(j["sandbox"], "<ROOT>"), "argv": [a.replace(j["sandbox"], "<ROOT>") for a in j["argv"]],
                      "roles": roles, "extra_models": extra,
                      "router_error": (res or {}).get("error") if isinstance(res, dict) else None,
                      "other_curl": [], "router_key": j.get("router_key"),
                      "output": j["output"].replace(j["sandbox"], "<ROOT>")[-3000:]})
    json.dump(out, open(os.path.join(WORK, "results.json"), "w"), indent=1)
    print(f"[matrix] results: {os.path.join(WORK, 'results.json')}", file=sys.stderr)
    fails = assertions(out)
    with open(os.path.join(WORK, "assertions.txt"), "w") as f:
        f.write("".join(x + "\n" for x in fails))
    checked = sum(1 for r in out if r["grid"] in ASSERT_GRIDS)
    if fails:
        print(f"[matrix] FAIL: {len(fails)} assertion(s), see {os.path.join(WORK, 'assertions.txt')}:", file=sys.stderr)
        for x in fails[:20]:
            print("  " + x, file=sys.stderr)
        sys.exit(1)
    print(f"[matrix] OK: {checked} combinations match the expected model selection", file=sys.stderr)


# ---------------------------------------------------------------- regression assertions
# The expected outcome of every combination, written down independently of the scripts:
#  - start.* launchers download exactly the 3 default files (pinned URL), serve.* download nothing;
#  - general/coder/decision = the 3 defaults; general = JA-SFT only with LANGUAGE_MODE=swap, a ja
#    locale and the model installed; a "language" role only with interpret, a non-English locale
#    and HY-MT installed; no other model is listed;
#  - per-role ctx/parallel/models-max follow the profile;
#  - a combination may only refuse to start with a language-mode error, and then starts nothing.
ASSERT_GRIDS = ("main", "tools", "locale-env", "profile-auto", "ps51")
DEF_URLS = sorted(f"https://huggingface.co/{c['repo']}/resolve/{c['revision']}/{c['file']}" for c in CANDS if c["pick"] == "default")
PARAMS = {"default": ({"general": "16384", "coder": "32768", "decision": "8192"}, {"general": "2", "coder": "4", "decision": "2"}, "2"),
          "lowram": ({"general": "8192", "coder": "16384", "decision": "4096"}, {"general": "1", "coder": "2", "decision": "1"}, "1")}


def lang_code(r):
    loc = r["explicit_locale"] if r["explicit_locale"] is not None else ("" if r["locale"] == "(unset)" else r["locale"])
    l = re.split(r"[-_]", loc.split(".")[0].split("@")[0])[0].lower()
    return "en" if l in ("", "c", "posix") else l


def effective_profile(r):
    if r["profile"] in ("default", "lowram"):
        return r["profile"]
    if r["profile"] == "auto":
        if r["launcher"] == "termux" or (r["mem"] or 16 * 2**30) < 6 * 2**30:
            return "lowram"
        return "default"
    return None


def assertions(rows):
    fails = []
    fails += assertions_decoy_env(rows) + assertions_parity(rows)
    for r in rows:
        if r["grid"] not in ASSERT_GRIDS:
            continue
        tag = f"{r['grid']}/{r['launcher']}/{r['profile']}/{r['mode']}/{r['locale']}/{r['install']}/tools={r['tools']}/LOCALE={r['explicit_locale']}"
        lc = lang_code(r)
        mode = "native" if r["mode"] in ("(unset)", "auto") else r["mode"]
        if lc == "en":
            mode = "off"
        want_general = "Qwen3.5-0.8B-Japanese-SFT-v2-Q4_K_M.gguf" if (mode == "swap" and lc == "ja") else DEFAULTS["general"]
        want_lang = "HY-MT1.5-1.8B-Q4_K_M.gguf" if mode == "interpret" else None
        need_optin = (mode == "swap") or (mode == "interpret")
        can_start = not need_optin or (r["install"] == "optin" and (mode == "interpret" or lc == "ja"))
        started = r["status"] == "ok"
        if not can_start:
            if started:
                fails.append(f"{tag}: started, but {mode} has no installed model")
            elif not re.search(r"LANGUAGE_MODE|LanguageMode", r["status"]):
                fails.append(f"{tag}: refused for another reason: {r['status'][:120]}")
            elif r["argv"]:
                fails.append(f"{tag}: refused but a server was started")
            continue
        if not started or r.get("router_error"):
            fails.append(f"{tag}: did not start: {r['status'][:100]} {r.get('router_error') or ''}")
            continue
        want_dl = DEF_URLS if r["launcher"] in ("start.sh", "start.command", "termux", "start.ps1") else []
        if sorted(r["downloads"]) != want_dl:
            fails.append(f"{tag}: downloads {r['downloads']}")
        got = {k: (v or {}).get("model") for k, v in r["roles"].items()}
        want = {"general": want_general, "coder": DEFAULTS["coder"], "decision": DEFAULTS["decision"], "language": want_lang}
        if got != want:
            fails.append(f"{tag}: models {got} != {want}")
        if r["extra_models"]:
            fails.append(f"{tag}: extra models listed: {r['extra_models']}")
        for role in ("general", "coder", "decision", "language"):
            v = r["roles"][role] or {}
            if v.get("mmproj") or v.get("draft") or v.get("hf"):
                fails.append(f"{tag}: {role} has mmproj/draft/hf {v}")
        prof = effective_profile(r)
        if prof:
            ctx, np_, mmax = PARAMS[prof]
            for role in ("general", "coder", "decision"):
                v = r["roles"][role] or {}
                if v.get("ctx") != ctx[role] or v.get("np") != np_[role]:
                    fails.append(f"{tag}: {role} ctx/parallel {v.get('ctx')}/{v.get('np')}, want {ctx[role]}/{np_[role]} ({prof})")
            a = r["argv"]
            got_max = next((a[i + 1] for i, x in enumerate(a) if x == "--models-max" and i + 1 < len(a)), None)
            if got_max != mmax:
                fails.append(f"{tag}: models-max {got_max}, want {mmax} ({prof})")
    return fails


def check_started(r, tag, want, fails, ctx=None):
    """r started a server whose router lists exactly general/coder/decision with the wanted files"""
    if r["status"] != "ok" or r.get("router_error"):
        fails.append(f"{tag}: did not start: {r['status'][:100]} {r.get('router_error') or ''}"); return
    got = {k: (v or {}).get("model") for k, v in r["roles"].items()}
    w = {"general": DEFAULTS["general"], "coder": DEFAULTS["coder"], "decision": DEFAULTS["decision"], "language": None} | want
    if got != w:
        fails.append(f"{tag}: models {got} != {w}")
    if r["extra_models"]:
        fails.append(f"{tag}: extra models listed: {r['extra_models']}")
    for role, v in r["roles"].items():
        if v and (v.get("mmproj") or v.get("draft") or v.get("hf")):
            fails.append(f"{tag}: {role} has mmproj/draft/hf {v}")
        if v and ctx and v.get("ctx") != ctx:
            fails.append(f"{tag}: {role} ctx {v.get('ctx')}, want {ctx} (extra args apply to every role)")


REFUSED = {"passthrough --Api_Key", "passthrough --tools", "passthrough -m", "passthrough --model", "passthrough -hf", "passthrough --models-preset", "passthrough --models-dir",
           "passthrough --hf-repo", "passthrough -mu", "passthrough --models_preset", "passthrough --MODEL=x", "passthrough --Hf_Repo"}


def assertions_decoy_env(rows):
    """decoys (stray files, HF caches) never change the served models; env/flag overrides behave as documented"""
    fails = []
    for r in rows:
        tag = f"{r['grid']}/{r['launcher']}/{r['label']}"
        if r["grid"] == "decoy":
            want = {}
            if r["label"] == "fallback-installed" and r["launcher"].startswith("serve"):
                # the user chose the 0.8B coder with fetch-models --fallback; start.* re-installs the defaults
                want = {"coder": "Qwen3.5-0.8B-Q4_K_M.gguf"}
            if r["label"] == "language-dir":
                want = {"language": "HY-MT1.5-1.8B-Q4_K_M.gguf"}
            check_started(r, tag, want, fails)
        elif r["grid"] == "env":
            lab = r["label"]
            if lab in REFUSED:
                # serve.ps1 -File: PowerShell itself rejects some before the script runs (-m is ambiguous,
                # --model binds to the int -ModelsMax); either way nothing starts
                if r["argv"] or not re.search(r"not allowed|is ambiguous|Cannot process argument transformation|would be read as",
                                              r["status"] + r["output"]):
                    fails.append(f"{tag}: not refused (status {r['status'][:80]})")
            elif lab == "ps -GpuLayers -1":
                check_started(r, tag, {}, fails)
                a = r["argv"]
                if "--n-gpu-layers" not in a or a[a.index("--n-gpu-layers") + 1] != "-1":
                    fails.append(f"{tag}: --n-gpu-layers not -1: {a}")
            elif lab == "passthrough --ctx-size":
                check_started(r, tag, {}, fails, ctx="2048")
            elif lab == "MODELS_DIR=other":
                check_started(r, tag, {"coder": "Qwen3.5-0.8B-Q4_K_M.gguf"}, fails)
            elif lab == "MODELS_PRESET=other":   # [coder] model = /tmp/decoy.gguf, which does not exist
                if r["argv"] or "file not found" not in r["status"] + r["output"]:
                    fails.append(f"{tag}: a missing custom model file was not refused ({r['status'][:80]})")
            elif lab == "MANIFEST=other":   # start.sh fetches the new default coder; serve.sh keeps the installed 2B (still listed)
                check_started(r, tag, {"coder": "Qwen3.5-0.8B-Q4_K_M.gguf"} if r["launcher"].startswith("start") else {}, fails)
            else:
                check_started(r, tag, {}, fails)
                a = r["argv"]
                mm = next((a[i + 1] for i, x in enumerate(a) if x == "--models-max" and i + 1 < len(a)), None)
                if lab == "MODELS_MAX=3" and mm != "3":
                    fails.append(f"{tag}: models-max {mm}, want 3 (MODELS_MAX)")
                if lab == "PROFILE=lowram env" and ((r["roles"]["coder"] or {}).get("ctx") != "16384" or mm != "1"):
                    fails.append(f"{tag}: PROFILE=lowram not applied (coder ctx {(r['roles']['coder'] or {}).get('ctx')}, models-max {mm})")
            if "--models-dir" in r["argv"]:
                fails.append(f"{tag}: --models-dir passed to the router")
    return fails


def assertions_parity(rows):
    """every launcher writes the same effective preset for the same settings (byte for byte)"""
    fails, groups = [], {}
    for r in rows:
        if r["grid"] in ("main", "tools", "locale-env", "ps51") and r["status"] == "ok" and r["preset"]:
            loc = lang_code(r)
            key = (r["profile"], r["mode"] if r["mode"] not in ("(unset)", "auto") else "native", loc, r["install"], r["tools"])
            groups.setdefault(key, {}).setdefault(r["preset"], []).append(f"{r['grid']}/{r['launcher']}/{r['locale']}/{r['explicit_locale']}")
    for key, variants in groups.items():
        if len(variants) > 1:
            fails.append(f"parity {key}: {len(variants)} different presets: " + " | ".join(v[0] + f" (+{len(v) - 1})" for v in variants.values()))
    return fails


if __name__ == "__main__":
    main()
