#!/usr/bin/env python3
"""Minimal coding agent for llama-server (stdlib only, runs on Termux/Windows/Linux).

It asks the router's "coder" model for tool calls and runs them through the
server's own built-in tools and MCP tools (POST /tools), so file access and
shell commands happen wherever the server's --tools-runtime puts them.

  python3 scripts/agent.py --cwd ./workspace "create hello.py that prints hi, then run it"

Tools that need the "write" permission ask before running unless --yes.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_key(path):
    if not path or not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                return line
    return None


class Client:
    def __init__(self, url, key, cwd=None):
        self.url, self.key, self.cwd = url.rstrip("/"), key, cwd

    def req(self, method, path, body=None, timeout=3600):
        headers = {"Content-Type": "application/json"}
        if self.key:
            headers["Authorization"] = "Bearer " + self.key
        if self.cwd and path == "/tools":
            headers["x-tool-cwd"] = self.cwd
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(self.url + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(r, timeout=timeout) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            raise SystemExit(f"HTTP {e.code} on {path}: {e.read().decode(errors='replace')}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("prompt")
    ap.add_argument("--url", default=os.environ.get("LLAMA_URL", "http://127.0.0.1:" + os.environ.get("PORT", "9931")))
    ap.add_argument("--key-file", default=os.environ.get("API_KEY_FILE", os.path.join(ROOT, ".secrets", "api-keys")))
    ap.add_argument("--model", default=os.environ.get("AGENT_MODEL", "coder"))
    ap.add_argument("--cwd", default=None, help="tool working directory (host path, or /work inside a container runtime)")
    ap.add_argument("--max-steps", type=int, default=12)
    ap.add_argument("--max-tokens", type=int, default=1024)
    ap.add_argument("--yes", action="store_true", help="do not ask before tools that write")
    ap.add_argument("--json-log", default=None, help="append every step as JSON lines to this file")
    a = ap.parse_args()

    cwd = a.cwd
    if cwd and not cwd.startswith("/") and os.path.isdir(cwd):
        cwd = os.path.abspath(cwd)
    c = Client(a.url, read_key(a.key_file), cwd)

    tools = c.req("GET", "/tools")
    defs = [t["definition"] for t in tools]
    needs_write = {t["tool"] for t in tools if (t.get("permissions") or {}).get("write")}
    names = [t["tool"] for t in tools]
    print(f"[agent] model={a.model} tools={','.join(names)} cwd={cwd or '(server cwd)'}", file=sys.stderr)

    messages = [
        {"role": "system", "content": "You are a careful coding agent. Use the tools to inspect, create, edit and run files. "
                                      "Use relative paths. Keep answers short. When the task is done, reply with a one-line summary."},
        {"role": "user", "content": a.prompt},
    ]
    log = open(a.json_log, "a", encoding="utf-8") if a.json_log else None
    for step in range(1, a.max_steps + 1):
        t0 = time.time()
        res = c.req("POST", "/v1/chat/completions", {
            "model": a.model, "messages": messages, "tools": defs, "max_tokens": a.max_tokens,
        })
        msg = res["choices"][0]["message"]
        timings = res.get("timings") or {}
        print(f"[agent] step {step}: {time.time()-t0:.1f}s, gen {timings.get('predicted_per_second', 0):.1f} tok/s, "
              f"prompt {timings.get('prompt_per_second', 0):.1f} tok/s", file=sys.stderr)
        if log:
            log.write(json.dumps({"step": step, "message": msg, "timings": timings}) + "\n")
        calls = msg.get("tool_calls") or []
        messages.append({k: v for k, v in msg.items() if k in ("role", "content", "tool_calls", "reasoning_content")})
        if not calls:
            print(msg.get("content") or "")
            return 0
        for call in calls:
            fn = call["function"]["name"]
            try:
                params = json.loads(call["function"].get("arguments") or "{}")
            except json.JSONDecodeError as e:
                out = json.dumps({"error": f"invalid JSON arguments: {e}"})
            else:
                print(f"[tool] {fn} {json.dumps(params)[:300]}", file=sys.stderr)
                if fn in needs_write and not a.yes:
                    if input(f"allow {fn}? [y/N] ").strip().lower() != "y":
                        out = json.dumps({"error": "denied by user"})
                        messages.append({"role": "tool", "tool_call_id": call.get("id", ""), "content": out})
                        continue
                r = c.req("POST", "/tools", {"tool": fn, "params": params})
                out = r["plain_text_response"] if "plain_text_response" in r else json.dumps(r)
            print(f"[tool] -> {out[:300]!r}", file=sys.stderr)
            if log:
                log.write(json.dumps({"step": step, "tool": fn, "result": out[:4000]}) + "\n")
            messages.append({"role": "tool", "tool_call_id": call.get("id", ""), "content": out})
    print("[agent] max steps reached", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
