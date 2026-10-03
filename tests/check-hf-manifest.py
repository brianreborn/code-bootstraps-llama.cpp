#!/usr/bin/env python3
"""Re-verify config/models-manifest.json against the Hugging Face API: for every entry, the
pinned revision must exist and the file at that revision must have exactly the manifest's
sha256 (LFS oid) and size. Also checks that every "model =" path in config/models-preset.ini
names a manifest file in the manifest's directory.   python3 tests/check-hf-manifest.py"""
import json, os, re, sys, urllib.request
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
m = json.load(open(os.path.join(ROOT, "config", "models-manifest.json")))
bad = 0
rows = []
for c in m["candidates"]:
    url = f"https://huggingface.co/api/models/{c['repo']}/tree/{c['revision']}"
    try:
        tree = json.load(urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "check-hf-manifest"}), timeout=30))
    except Exception as e:
        rows.append((c["pick"], c["role"], c["repo"], c["file"], "API ERROR " + str(e))); bad += 1; continue
    f = next((t for t in tree if t.get("path") == c["file"]), None)
    if not f:
        rows.append((c["pick"], c["role"], c["repo"], c["file"], "FILE NOT AT REVISION")); bad += 1; continue
    oid, size = (f.get("lfs") or {}).get("oid"), (f.get("lfs") or {}).get("size", f.get("size"))
    ok = oid == c["sha256"] and size == c["bytes"]
    bad += not ok
    rows.append((c["pick"], c["role"], c["repo"], c["file"], ("OK" if ok else "MISMATCH") + f" (HF sha256 {oid[:12]}..., {size} bytes)"))
# the revision must also be a commit of that repo (the tree endpoint accepts branch names too)
for c in m["candidates"]:
    if not re.fullmatch(r"[0-9a-f]{40}", c["revision"]):
        rows.append((c["pick"], c["role"], c["repo"], c["file"], "REVISION IS NOT A COMMIT SHA")); bad += 1
# preset model paths vs manifest
files = {(c.get("dir") or f"models/{c['role']}") + "/" + c["file"] for c in m["candidates"]}
for line in open(os.path.join(ROOT, "config", "models-preset.ini")):
    mm = re.match(r"^model\s*=\s*(\S+)", line)
    if mm:
        ok = mm.group(1) in files
        bad += not ok
        rows.append(("preset", "", "", mm.group(1), "OK (manifest entry)" if ok else "NOT IN MANIFEST"))
for r in rows:
    print("\t".join(r))
sys.exit(1 if bad else 0)
