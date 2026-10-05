#!/usr/bin/env python3
"""Minimal example MCP server (stdio, one JSON-RPC message per line).

llama-server spawns it from config/mcp-servers.json and exposes its tools as
example_<tool>. It has no dependencies and touches nothing on disk, so it is
safe to keep enabled. Replace it with real MCP servers as needed.
"""
import datetime
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib.lockmem import try_lock_process

TOOLS = [
    {
        "name": "utc_now",
        "description": "Return the current date and time in UTC (ISO 8601).",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "word_count",
        "description": "Count the lines, words and characters of a text.",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string", "description": "Text to count"}},
            "required": ["text"],
        },
    },
]


def call_tool(name, args):
    if name == "utc_now":
        return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    if name == "word_count":
        text = str(args.get("text", ""))
        return json.dumps({"lines": len(text.splitlines()), "words": len(text.split()), "chars": len(text)})
    raise KeyError(name)


def handle(req):
    method, params = req.get("method"), req.get("params") or {}
    if method == "initialize":
        return {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
                "serverInfo": {"name": "example", "version": "0.1"}}
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": TOOLS}
    if method == "tools/call":
        try:
            text = call_tool(params.get("name"), params.get("arguments") or {})
        except KeyError:
            raise ValueError(f"unknown tool: {params.get('name')}")
        return {"content": [{"type": "text", "text": text}]}
    raise LookupError(f"method not found: {method}")


def main():
    try_lock_process("mcp-example-server.py")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        if req.get("id") is None:  # notification, no reply
            continue
        resp = {"jsonrpc": "2.0", "id": req["id"]}
        try:
            resp["result"] = handle(req)
        except LookupError as e:
            resp["error"] = {"code": -32601, "message": str(e)}
        except Exception as e:  # noqa: BLE001
            resp["error"] = {"code": -32602, "message": str(e)}
        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
