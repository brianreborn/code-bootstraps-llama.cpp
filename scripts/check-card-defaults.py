#!/usr/bin/env python3
"""Developers only: the preset must use each model's card defaults (#51).

For every served section of config/models-preset.ini, find the model it serves
(its "model =" key, else the first manifest candidate of that role) and compare
the effective sampling keys and ctx-size with the manifest's card fields
(card_defaults, card_sampling_modes, card_ctx; written by familia's
scripts/model_db.py from the model's Hugging Face repo).

A value that differs from the card fails unless the section (or an inherited one)
says why, in a comment:
    ; override KEY: reason (at least 10 characters)
    ; card-set: LABEL           use another card set; needs ; override card-set: reason
Keys the preset leaves unset are compared at llama.cpp's defaults (b11374).
A model whose card states nothing is not checked. Exit 1 on any failure."""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEYS = ("temp", "top-p", "top-k", "min-p", "repeat-penalty", "presence-penalty", "frequency-penalty")
LLAMA_DEFAULTS = {"temp": 0.8, "top-p": 0.95, "top-k": 40, "min-p": 0.05,
                  "repeat-penalty": 1.0, "presence-penalty": 0.0, "frequency-penalty": 0.0}
SERVED = ("general", "coder", "decision", "language")   # [embed] is a separate process
OVR_RE = re.compile(r"^;\s*override\s+([\w.-]+)\s*:\s*(.+?)\s*$")
SET_RE = re.compile(r"^;\s*card-set\s*:\s*(.+?)\s*$")


def parse_preset(path):
    secs, cur = {}, None
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            s = line.strip()
            m = re.match(r"^\[(.+)\]$", s)
            if m:
                cur = secs.setdefault(m.group(1), {"keys": {}, "override": {}, "card_set": None, "line": n})
                continue
            if cur is None or not s:
                continue
            if s.startswith(";") or s.startswith("#"):
                o, c = OVR_RE.match(s), SET_RE.match(s)
                if o:
                    cur["override"][o.group(1)] = (o.group(2), n)
                elif c:
                    cur["card_set"] = c.group(1)
                continue
            if "=" in s:
                k, v = s.split("=", 1)
                cur["keys"][k.strip()] = v.strip()
    return secs


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def check(preset_path, manifest_path):
    secs = parse_preset(preset_path)
    with open(manifest_path, encoding="utf-8") as f:
        cands = [c for c in json.load(f)["candidates"] if "file" in c]
    errors, warns, checked = [], [], 0
    for name, sec in secs.items():
        if name == "*":
            continue
        loc = re.match(r"^locale\.([\w-]+)\.(\w+)$", name)
        role = loc.group(2) if loc else name
        if role not in SERVED:
            continue
        chain = [sec] + ([secs[role]] if loc and role in secs else []) + ([secs["*"]] if "*" in secs else [])
        model = sec["keys"].get("model")
        if model:
            c = next((c for c in cands if c["file"] == os.path.basename(model)), None)
        else:
            c = next((c for c in cands if c.get("role") == role and not c.get("dir", "").startswith("models-optional/locale")), None)
        if c is None:
            errors.append("[%s]: no manifest candidate for %s" % (name, model or "role " + role))
            continue
        if not c.get("db_id"):
            errors.append("[%s] %s: no model database entry (run familia scripts/model_db.py backfill --bootstraps %s)" % (name, c["file"], ROOT))
            continue

        def get(k):
            for s in chain:
                if k in s["keys"]:
                    return s["keys"][k]
            return None

        def reason(k):
            for s in chain:
                if k in s["override"]:
                    return s["override"][k]
            return None

        used = set()
        want_set = sec["card_set"]          # not inherited: a set label belongs to one model's card
        modes = c.get("card_sampling_modes") or {}
        if want_set:
            w = want_set.lower().strip()   # exact label, else unique prefix, else substring
            hit = ([k for k in modes if k.lower().strip() == w] or [k for k in modes if k.lower().startswith(w)]
                   or [k for k in modes if w in k.lower()])
            if len(hit) != 1:
                errors.append("[%s] %s: card-set %r matches %d card sets (%s)" % (name, c["file"], want_set, len(hit), "; ".join(modes) or "none"))
                continue
            card = modes[hit[0]]
            if hit[0] != c.get("card_default_set"):
                used.add("card-set")
                if not reason("card-set") or len(reason("card-set")[0]) < 10:
                    errors.append("[%s] %s: card-set %r is not the card's default (%r) and has no '; override card-set: reason'"
                                  % (name, c["file"], hit[0], c.get("card_default_set")))
        else:
            card = c.get("card_defaults") or {}
        for k, v in sorted(card.items()):
            if k not in KEYS:
                continue
            have = get(k)
            eff = num(have) if have is not None else LLAMA_DEFAULTS[k]
            checked += 1
            if eff is not None and abs(eff - float(v)) < 1e-9:
                continue
            used.add(k)
            r = reason(k)
            if not r or len(r[0]) < 10:
                errors.append("[%s] %s: %s = %s (%s) but the card says %s; set it or add '; override %s: reason'"
                              % (name, c["file"], k, have if have is not None else LLAMA_DEFAULTS[k],
                                 "preset" if have is not None else "llama.cpp default", v, k))
        cctx = c.get("card_ctx") or c.get("ctx")
        have = get("ctx-size")
        if cctx and have and int(num(have) or 0) != int(cctx):
            used.add("ctx-size")
            r = reason("ctx-size")
            if not r or len(r[0]) < 10:
                errors.append("[%s] %s: ctx-size = %s but the model's context is %s (%s); add '; override ctx-size: reason'"
                              % (name, c["file"], have, cctx, "card" if c.get("card_ctx") else "GGUF"))
        for k, (r, n) in sec["override"].items():
            if k not in used and name != "*":
                warns.append("[%s] line %d: override %s is not needed (value matches the card)" % (name, n, k))
    return errors, warns, checked


def main(argv):
    preset = argv[1] if len(argv) > 1 else os.path.join(ROOT, "config", "models-preset.ini")
    manifest = argv[2] if len(argv) > 2 else os.path.join(ROOT, "config", "models-manifest.json")
    errors, warns, n = check(preset, manifest)
    for w in warns:
        print("check-card-defaults: warning: " + w)
    for e in errors:
        print("check-card-defaults: " + e)
    if errors:
        return 1
    print("check-card-defaults: OK %s (%d card values checked)" % (os.path.relpath(preset, ROOT), n))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
