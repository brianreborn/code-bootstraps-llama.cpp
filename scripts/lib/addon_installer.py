#!/usr/bin/env python3
"""Print "<url> <sha256>" for a starter pick's pinned _installer; exit 1 (fail-closed) otherwise.

Used by scripts/install-addon.sh and scripts/install-addon.ps1. Looks in mcpServers and in
every addons.<group> of config/mcp-servers.starter.json. Only https URLs and a 64-hex sha256.
"""
import json
import re
import sys


def find(starter, pick):
    groups = [starter.get("mcpServers", {})]
    groups += [g for k, g in (starter.get("addons") or {}).items() if isinstance(g, dict) and not k.startswith("_")]
    for g in groups:
        if isinstance(g.get(pick), dict):
            return g[pick]
    return None


def installer(starter, pick):
    entry = find(starter, pick)
    if entry is None:
        return None, f"unknown pick '{pick}'"
    inst = entry.get("_installer")
    if not isinstance(inst, dict):
        return None, f"pick '{pick}' has no pinned _installer (see its _install note)"
    url, sha = str(inst.get("url", "")), str(inst.get("sha256", "")).lower()
    if not url.startswith("https://"):
        return None, f"pick '{pick}': installer url must be https"
    if not re.fullmatch(r"[0-9a-f]{64}", sha):
        return None, f"pick '{pick}': installer sha256 missing or malformed; refusing"
    return (url, sha), None


def main(argv):
    if len(argv) != 3:
        print("usage: addon_installer.py STARTER PICK", file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8-sig") as f:
        starter = json.load(f)
    res, err = installer(starter, argv[2])
    if err:
        print(f"install-addon: {err}", file=sys.stderr)
        return 1
    print(f"{res[0]} {res[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
