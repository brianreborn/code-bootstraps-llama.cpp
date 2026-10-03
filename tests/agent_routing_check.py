#!/usr/bin/env python3
"""Which router model names does scripts/agent.py request? (fake server, no model)
    python3 tests/agent_routing_check.py   -> JSON lines: locale, mode, prompt, env, models requested"""
import json, os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_agent import FakeServer, BUILTINS, AGENT

CASES = []
for loc in ("en", "ja", "ja-JP", "ja_JP", "zh", "de"):
    for mode in ("off", "native", "swap", "interpret"):
        for prompt in ("list the files", "ファイルを一覧表示して"):
            CASES.append((loc, mode, prompt, {}))
CASES += [("ja", "native", "ファイルを一覧表示して", {"AGENT_MODEL": "general"}),
          ("ja", "native", "list the files", {"LLAMA_ARG_MODEL": "/tmp/x.gguf", "MODEL_GENERAL": "x", "MODEL_CODER": "x"})]
for loc, mode, prompt, env in CASES:
    fake = FakeServer(BUILTINS, ["done"] * 3)
    try:
        e = dict(os.environ, **env)
        r = subprocess.run([sys.executable, AGENT, "--url", fake.url, "--key-file", os.devnull, "--locale", loc,
                            "--language-mode", mode, prompt], capture_output=True, text=True, timeout=60, env=e,
                           stdin=subprocess.DEVNULL)
        print(json.dumps({"locale": loc, "mode": mode, "prompt": prompt, "env": env, "rc": r.returncode,
                          "models": [c.get("model") for c in fake.chats]}, ensure_ascii=False))
    finally:
        fake.close()
