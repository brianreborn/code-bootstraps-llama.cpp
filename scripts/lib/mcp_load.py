#!/usr/bin/env python3
"""Build the effective MCP servers config that serve.sh / serve.ps1 hand to llama-server.

Merges config/mcp-servers.json (base, always wins on a name clash) with the ENABLED picks
of config/mcp-servers.starter.json. A pick is enabled by `"enabled": true` in the starter
file or by naming it in MCP_PICKS (comma list). Placeholder picks (command "TODO"), picks
whose placeholders cannot be filled, and doc-only `_*` keys are dropped with a warning.
A broken starter file never breaks serving: the base config is still emitted.

Usage: mcp_load.py --root ROOT --base BASE [--starter STARTER] [--picks a,b] --out OUT
"""
import argparse
import json
import os
import sys

TAG = "mcp_load"


def warn(msg):
    print(f"{TAG}: {msg}", file=sys.stderr)


def load_json(path):
    with open(path, encoding="utf-8-sig") as f:
        return json.load(f)


def subst(value, env):
    """Replace @ROOT@/@FAMILIA_ROOT@; return None when a placeholder has no value."""
    if isinstance(value, str):
        for key, val in env.items():
            token = f"@{key}@"
            if token in value:
                if not val:
                    return None
                value = value.replace(token, val)
        return value
    if isinstance(value, list):
        out = [subst(v, env) for v in value]
        return None if any(v is None for v in out) else out
    if isinstance(value, dict):
        out = {k: subst(v, env) for k, v in value.items()}
        return None if any(v is None for v in out.values()) else out
    return value


def clean(entry):
    return {k: v for k, v in entry.items() if not k.startswith("_") and k != "enabled"}


def starter_picks(starter, wanted):
    """Yield (name, entry) for enabled starter picks, in file order."""
    servers = starter.get("mcpServers") if isinstance(starter, dict) else None
    if not isinstance(servers, dict):
        warn("starter file has no mcpServers object; no starter picks")
        return
    for name in wanted - set(servers):
        warn(f"MCP_PICKS names unknown pick '{name}'; ignored")
    for name, entry in servers.items():
        if not isinstance(entry, dict):
            continue
        if entry.get("enabled") is True or name in wanted:
            yield name, entry


def build(root, base_path, starter_path, picks, env=None):
    env = dict(env or {})
    env.setdefault("ROOT", root)
    env.setdefault("FAMILIA_ROOT", os.environ.get("FAMILIA_ROOT", ""))
    base = load_json(base_path) if base_path else {"mcpServers": {}}
    servers = dict(base.get("mcpServers") or {})
    for name, entry in list(servers.items()):
        filled = subst(entry, env)
        if filled is None:
            warn(f"base server '{name}' has an unfilled placeholder; dropped")
            del servers[name]
        else:
            servers[name] = filled
    added = []
    if starter_path and os.path.exists(starter_path):
        try:
            starter = load_json(starter_path)
        except (OSError, ValueError) as e:
            warn(f"cannot read {starter_path} ({e}); no starter picks")
            starter = {}
        for name, entry in starter_picks(starter, picks):
            if name in servers:
                warn(f"pick '{name}' is already in the base config; base wins")
                continue
            if not entry.get("command") or entry.get("command") == "TODO":
                warn(f"pick '{name}' has no runnable command yet (doc-TODO); skipped")
                continue
            filled = subst(clean(entry), env)
            if filled is None:
                warn(f"pick '{name}' needs a placeholder that is not set (e.g. FAMILIA_ROOT); skipped")
                continue
            servers[name] = filled
            added.append(name)
    return {"mcpServers": servers}, added


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--base", default="")
    ap.add_argument("--starter", default="")
    ap.add_argument("--picks", default=os.environ.get("MCP_PICKS", ""))
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    picks = {p.strip() for p in a.picks.split(",") if p.strip()}
    cfg, added = build(a.root, a.base, a.starter, picks)
    tmp = a.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.replace(tmp, a.out)
    if added:
        warn("starter picks enabled: " + ", ".join(added))
    return 0


if __name__ == "__main__":
    sys.exit(main())
