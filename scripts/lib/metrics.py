#!/usr/bin/env python3
"""Runtime gate + local sampler for config/metrics.json (docs/metrics-and-turbo.md).

Default ON. ONE switch turns ALL collection off (the "turbo button"), any of:
  config/metrics.json turbo_button.turbo: true  |  FAMILIA_TURBO=1  |  serve.sh/serve.ps1 --turbo
Turbo overrides `enabled`. A missing or broken metrics.json means the default (on), never a crash.

  metrics.py status [--turbo]          print "on" or "off (<reason>)"; exit 0 on, 3 off
  metrics.py sample --url URL --key-file F [--interval S] [--once]
      poll llama-server /metrics + /health into the rolling window in state/metrics.json
      (privacy.state_file). Exits at once, writing nothing, when metrics are off.
Local-only: URL must be loopback (privacy.local_only / no_external_upload).
"""
import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
DEFAULTS = {"enabled": True, "turbo_button": {"turbo": False},
            "collect": {"tokens_per_second": True, "latency_ms": True, "ram_vram_usage": True,
                        "node_health": True, "model_engine_microcode_version": True,
                        "rolling_window_samples": 64},
            "privacy": {"local_only": True, "state_file": "state/metrics.json"}}
LOOPBACK = {"127.0.0.1", "::1", "localhost"}


def load(root=ROOT):
    cfg = json.loads(json.dumps(DEFAULTS))
    try:
        with open(os.path.join(root, "config", "metrics.json"), encoding="utf-8-sig") as f:
            user = json.load(f)
        for k, v in user.items():
            if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                cfg[k].update(v)
            else:
                cfg[k] = v
    except (OSError, ValueError) as e:
        print(f"metrics: config/metrics.json unreadable ({e}); using defaults (on)", file=sys.stderr)
    return cfg


def state(cfg, env=None, turbo_flag=False):
    """(on: bool, reason: str)."""
    env = os.environ if env is None else env
    if turbo_flag:
        return False, "turbo (--turbo)"
    if env.get("FAMILIA_TURBO", "") not in ("", "0"):
        return False, "turbo (FAMILIA_TURBO)"
    if (cfg.get("turbo_button") or {}).get("turbo") is True:
        return False, "turbo (config/metrics.json)"
    if cfg.get("enabled") is False:
        return False, "disabled (config/metrics.json enabled:false)"
    return True, "on"


def parse_prom(text):
    out = {}
    for line in text.splitlines():
        if line.startswith("#") or " " not in line:
            continue
        name, _, val = line.rpartition(" ")
        try:
            out[name.split("{")[0]] = float(val)
        except ValueError:
            pass
    return out


def mem_kb():
    try:
        with open("/proc/meminfo") as f:
            m = {ln.split(":")[0]: int(ln.split()[1]) for ln in f if ln.split()[1:2] and ln.split()[1].isdigit()}
        return {"total_kb": m.get("MemTotal"), "available_kb": m.get("MemAvailable")}
    except OSError:
        return None


def get(url, key, timeout=5):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}"} if key else {})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 (loopback only, checked)
        body = r.read().decode("utf-8", "replace")
    return body, (time.monotonic() - t0) * 1000.0


def sample_once(cfg, url, key):
    col = cfg["collect"]
    s = {"ts": time.time()}
    if col.get("node_health"):
        try:
            get(url + "/health", key)
            s["health"] = "ok"
        except Exception as e:  # noqa: BLE001
            s["health"] = f"down: {type(e).__name__}"
    try:
        body, ms = get(url + "/metrics", key)
        p = parse_prom(body)
        if col.get("latency_ms"):
            s["latency_ms"] = round(ms, 1)
        if col.get("tokens_per_second"):
            s["tokens_per_second"] = p.get("llamacpp:predicted_tokens_seconds")
            s["prompt_tokens_per_second"] = p.get("llamacpp:prompt_tokens_seconds")
    except Exception as e:  # noqa: BLE001
        s["metrics_error"] = type(e).__name__
    if col.get("ram_vram_usage"):
        s["ram"] = mem_kb()
    return s


def write_state(root, cfg, s, engine=None):
    path = os.path.join(root, cfg["privacy"].get("state_file") or "state/metrics.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        with open(path, encoding="utf-8") as f:
            st = json.load(f)
    except (OSError, ValueError):
        st = {}
    win = int(cfg["collect"].get("rolling_window_samples") or 64)
    st.setdefault("initial", s)
    st["rolling"] = (st.get("rolling") or [])[-(win - 1):] + [s] if win > 0 else []
    if engine and cfg["collect"].get("model_engine_microcode_version"):
        st["engine"] = engine
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f)
    os.replace(tmp, path)
    return path


def main(argv=None, env=None, root=ROOT):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    a1 = sub.add_parser("status")
    a1.add_argument("--turbo", action="store_true")
    a2 = sub.add_parser("sample")
    a2.add_argument("--url", required=True)
    a2.add_argument("--key-file", default="")
    a2.add_argument("--interval", type=float, default=5.0)
    a2.add_argument("--engine", default="")
    a2.add_argument("--turbo", action="store_true")
    a2.add_argument("--once", action="store_true")
    a = ap.parse_args(argv)
    cfg = load(root)
    on, why = state(cfg, env, a.turbo)
    if a.cmd == "status":
        print("on" if on else f"off ({why})")
        return 0 if on else 3
    if not on:
        print(f"metrics off ({why}): sampler not started", file=sys.stderr)
        return 0
    host = urllib.parse.urlsplit(a.url).hostname or ""
    if host not in LOOPBACK:
        print(f"metrics: refusing non-loopback URL {a.url} (local_only)", file=sys.stderr)
        return 2
    key = ""
    if a.key_file:
        with open(a.key_file, encoding="utf-8") as f:
            key = next((ln.strip() for ln in f if ln.strip() and not ln.startswith("#")), "")
    base = a.url.rstrip("/")
    while True:
        write_state(root, cfg, sample_once(cfg, base, key), a.engine)
        if a.once:
            return 0
        time.sleep(max(a.interval, 0.5))


if __name__ == "__main__":
    sys.exit(main())
