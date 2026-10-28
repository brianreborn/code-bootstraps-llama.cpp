"""scripts/lib/mcp_load.py: merges enabled starter picks into the base MCP config."""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts", "lib"))
import mcp_load  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def write(tmp_path, name, obj):
    p = tmp_path / name
    p.write_text(json.dumps(obj))
    return str(p)


BASE = {"mcpServers": {"example": {"command": "python3", "cwd": "@ROOT@", "args": ["x.py"]}}}
STARTER = {"mcpServers": {
    "time": {"enabled": True, "_desc": "d", "command": "uvx", "args": ["t==1"]},
    "git": {"enabled": False, "command": "uvx", "args": ["g", "--repository", "@ROOT@"]},
    "todo": {"enabled": True, "command": "TODO", "args": []},
    "fam": {"enabled": True, "command": "python3", "cwd": "@FAMILIA_ROOT@/x"},
    "example": {"enabled": True, "command": "evil"},
}}


def test_merges_only_enabled_and_runnable(tmp_path):
    cfg, added = mcp_load.build("/r", write(tmp_path, "b.json", BASE),
                                write(tmp_path, "s.json", STARTER), set(), {"FAMILIA_ROOT": ""})
    s = cfg["mcpServers"]
    assert added == ["time"]
    assert s["time"] == {"command": "uvx", "args": ["t==1"]}
    assert s["example"]["cwd"] == "/r" and s["example"]["command"] == "python3"  # base wins
    assert "git" not in s and "todo" not in s and "fam" not in s


def test_picks_env_enables_and_fills_root(tmp_path):
    cfg, added = mcp_load.build("/r", write(tmp_path, "b.json", BASE),
                                write(tmp_path, "s.json", STARTER), {"git"}, {"FAMILIA_ROOT": "/f"})
    assert "git" in added and "fam" in added
    assert cfg["mcpServers"]["git"]["args"][-1] == "/r"
    assert cfg["mcpServers"]["fam"]["cwd"] == "/f/x"


def test_broken_starter_keeps_base(tmp_path):
    bad = tmp_path / "s.json"
    bad.write_text("{nope")
    cfg, added = mcp_load.build("/r", write(tmp_path, "b.json", BASE), str(bad), set())
    assert added == [] and list(cfg["mcpServers"]) == ["example"]


def test_shipped_starter_adds_nothing_by_default(tmp_path):
    out = tmp_path / "eff.json"
    rc = mcp_load.main(["--root", ROOT, "--base", os.path.join(ROOT, "config/mcp-servers.json"),
                        "--starter", os.path.join(ROOT, "config/mcp-servers.starter.json"),
                        "--picks", "", "--out", str(out)])
    assert rc == 0
    assert list(json.loads(out.read_text())["mcpServers"]) == ["example"]
