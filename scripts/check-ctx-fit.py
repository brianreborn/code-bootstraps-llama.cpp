#!/usr/bin/env python3
"""Fail when a preset or profile asks more context than a role's model was trained for.

Every manifest candidate must record n_ctx_train (GGUF <arch>.context_length at the pinned
revision, scripts/lib/gguf_ctx.py). Each [role] ctx-size in config/models-preset.ini and every
"<role>.ctx-size=N" profile overlay in scripts/serve.sh / serve.ps1 must be <= the n_ctx_train of
that role's pick=default model. serve.sh / serve.ps1 also fit at runtime (any installed model);
this check keeps the shipped defaults honest. RoPE/YaRN stretching is opt-in and not checked.
Developers only."""
import json, os, re, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
man = json.load(open(os.path.join(root, "config", "models-manifest.json")))["candidates"]
rc = 0
for c in man:
    if not isinstance(c.get("n_ctx_train"), int) or c["n_ctx_train"] <= 0:
        print("check-ctx-fit: %s has no n_ctx_train" % c.get("file")); rc = 1
limit = {}
for c in man:
    if c.get("pick") == "default" and isinstance(c.get("n_ctx_train"), int):
        limit[c["role"]] = min(limit.get(c["role"], 1 << 30), c["n_ctx_train"])

sec, preset = "", {}
for line in open(os.path.join(root, "config", "models-preset.ini")):
    m = re.match(r"^\[(.*)\]", line)
    if m: sec = m.group(1); continue
    m = re.match(r"^([A-Za-z0-9_-]+)\s*=\s*(\S+)", line)
    if m: preset.setdefault(sec, {})[m.group(1)] = m.group(2)

def want(where, role, key, val):
    global rc
    if role in limit and val.isdigit() and int(val) > limit[role]:
        print("check-ctx-fit: %s: %s %s=%s exceeds n_ctx_train %d" % (where, role, key, val, limit[role])); rc = 1

for role in limit:
    s = preset.get(role, {})
    if any(k in s for k in ("rope-scaling", "rope-scale", "yarn-orig-ctx")): continue
    for k in ("ctx-size", "batch-size", "ubatch-size", "kv-unified-per-slot"):
        if k in s: want("models-preset.ini", role, k, s[k])
for f in ("scripts/serve.sh", "scripts/serve.ps1"):
    for m in re.finditer(r"\b(general|coder|decision|embed|language)\.(ctx-size|kv-unified-per-slot)=(\d+)", open(os.path.join(root, f)).read()):
        want(f, m.group(1), m.group(2), m.group(3))
print("check-ctx-fit: %s (%d candidates, limits %s)" % ("OK" if rc == 0 else "FAIL", len(man), limit))
sys.exit(rc)
