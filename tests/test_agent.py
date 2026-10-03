#!/usr/bin/env python3
"""Regression tests for scripts/agent.py against a fake llama-server (stdlib only, no model).

    python3 tests/test_agent.py
"""
import json
import os
import subprocess
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT = os.path.join(ROOT, "scripts", "agent.py")


def tool(name, typ="server", write=False):
    return {"tool": name, "type": typ, "permissions": {"write": write}, "display_name": name,
            "definition": {"type": "function", "function": {"name": name, "parameters": {"type": "object"}}}}


BUILTINS = [tool("read_file"), tool("grep_search"), tool("get_info"),
            tool("exec_shell_command", write=True), tool("write_file", write=True), tool("edit_file", write=True)]


def call(name, **args):
    return {"name": name, "args": args}


class FakeServer:
    """Serves GET/POST /tools and /v1/chat/completions. `script` is the list of assistant
    turns: a list of calls, or a string (final answer). With tool_choice none it answers."""

    def __init__(self, tools, script):
        self.tools, self.script, self.executed, self.chats = tools, list(script), [], []
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def reply(self, obj):
                b = json.dumps(obj).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)

            def do_GET(self):
                self.reply(fake.tools if self.path == "/tools" else {})

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if self.path == "/tools":
                    fake.executed.append((body["tool"], body["params"]))
                    return self.reply({"plain_text_response": "ok\n\n[exit code: 0]"})
                fake.chats.append(body)
                turn = fake.script.pop(0) if fake.script and body.get("tool_choice") != "none" else "summary"
                if isinstance(turn, str):
                    msg = {"role": "assistant", "content": turn}
                else:
                    msg = {"role": "assistant", "content": "", "tool_calls": [
                        {"id": f"c{len(fake.chats)}-{i}", "type": "function",
                         "function": {"name": c["name"], "arguments": json.dumps(c["args"])}} for i, c in enumerate(turn)]}
                self.reply({"choices": [{"message": msg}], "timings": {}})

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def run_agent(fake, *args, stdin=subprocess.DEVNULL):
    cmd = [sys.executable, AGENT, "--url", fake.url, "--key-file", os.devnull, "--locale", "en", *args, "do the task"]
    return subprocess.run(cmd, stdin=stdin, capture_output=True, text=True, timeout=60)


class ApprovalTests(unittest.TestCase):
    def test_tool_not_offered_is_refused(self):
        # review round 3, HIGH 1: --tools read_file, the model calls exec_shell_command anyway
        fake = FakeServer(BUILTINS, [[call("exec_shell_command", command="id")], "done"])
        try:
            r = run_agent(fake, "--tools", "read_file")
        finally:
            fake.close()
        self.assertEqual(fake.executed, [], r.stderr)
        self.assertIn("was not offered", r.stderr)
        self.assertEqual([t["function"]["name"] for t in fake.chats[0]["tools"]], ["read_file"])

    def test_write_tool_without_answer_is_denied(self):
        for stdin in (subprocess.DEVNULL, None):   # end of input, and stdin closed
            fake = FakeServer(BUILTINS, [[call("exec_shell_command", command="id")], "done"])
            try:
                if stdin is None:
                    cmd = [sys.executable, AGENT, "--url", fake.url, "--key-file", os.devnull, "--locale", "en", "x"]
                    r = subprocess.run(["sh", "-c", 'exec "$@" <&-', "sh", *cmd], capture_output=True, text=True, timeout=60)
                else:
                    r = run_agent(fake, stdin=stdin)
            finally:
                fake.close()
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(fake.executed, [], r.stderr)

    def test_yes_runs_write_tool(self):
        fake = FakeServer(BUILTINS, [[call("exec_shell_command", command="id")], "done"])
        try:
            r = run_agent(fake, "--yes")
        finally:
            fake.close()
        self.assertEqual(fake.executed, [("exec_shell_command", {"command": "id"})], r.stderr)

    def test_read_only_builtin_runs_unasked(self):
        fake = FakeServer(BUILTINS, [[call("read_file", path="a.txt")], "done"])
        try:
            r = run_agent(fake)
        finally:
            fake.close()
        self.assertEqual(fake.executed, [("read_file", {"path": "a.txt"})], r.stderr)

    def test_mcp_tool_named_like_a_builtin_asks(self):
        # classification by type, not by name: an MCP "read_file" is not a read-only built-in
        tools = [tool("read_file", typ="mcp"), tool("write_file", write=True)]
        fake = FakeServer(tools, [[call("read_file", path="a.txt")], "done"])
        try:
            r = run_agent(fake)
        finally:
            fake.close()
        self.assertEqual(fake.executed, [], r.stderr)

    def test_read_only_mcp_tool_asks(self):
        fake = FakeServer(BUILTINS + [tool("example_utc_now", typ="mcp")], [[call("example_utc_now")], "done"])
        try:
            r = run_agent(fake)
        finally:
            fake.close()
        self.assertEqual(fake.executed, [], r.stderr)


class RepeatGuardTests(unittest.TestCase):
    def test_identical_command_runs_once_then_forced_answer(self):
        py = [call("exec_shell_command", command="python3 hello.py")]
        fake = FakeServer(BUILTINS, [py] * 10)
        try:
            r = run_agent(fake, "--yes", "--max-steps", "12")
        finally:
            fake.close()
        self.assertEqual(fake.executed, [("exec_shell_command", {"command": "python3 hello.py"})], r.stderr)
        self.assertEqual(r.stderr.count("skipped repeat"), 2, r.stderr)
        self.assertEqual(fake.chats[-1].get("tool_choice"), "none")   # 1 run + 2 skips, then no tools
        self.assertEqual(len(fake.chats), 4)
        self.assertEqual(r.stdout.strip(), "summary")
        self.assertEqual(r.returncode, 0)

    def test_run_edit_run_edit_run(self):
        # review round 3, MED 4: each edit starts a new state, so the same command may run again
        run = [call("exec_shell_command", command="python3 t.py")]
        script = [run, [call("edit_file", path="t.py", edits=[{"old_text": "a", "new_text": "b"}])], run,
                  [call("edit_file", path="t.py", edits=[{"old_text": "b", "new_text": "c"}])], run, "done"]
        fake = FakeServer(BUILTINS, script)
        try:
            r = run_agent(fake, "--yes")
        finally:
            fake.close()
        self.assertEqual([t for t, _ in fake.executed],
                         ["exec_shell_command", "edit_file", "exec_shell_command", "edit_file", "exec_shell_command"], r.stderr)
        self.assertNotIn("skipped repeat", r.stderr)
        self.assertEqual(r.stdout.strip(), "done")

    def test_identical_write_after_command_is_skipped(self):
        # write X, run, write X (same content): nothing new, skipped
        w = [call("write_file", path="hello.py", content="print('hi')")]
        run = [call("exec_shell_command", command="python3 hello.py")]
        fake = FakeServer(BUILTINS, [w, run, w, "done"])
        try:
            r = run_agent(fake, "--yes")
        finally:
            fake.close()
        self.assertEqual([t for t, _ in fake.executed], ["write_file", "exec_shell_command"], r.stderr)
        self.assertEqual(r.stderr.count("skipped repeat"), 1)

    def test_last_step_has_no_tools(self):
        fake = FakeServer(BUILTINS, [[call("read_file", path=f"f{i}")] for i in range(10)])
        try:
            r = run_agent(fake, "--max-steps", "3")
        finally:
            fake.close()
        self.assertEqual(len(fake.executed), 2, r.stderr)
        self.assertEqual(fake.chats[-1].get("tool_choice"), "none")
        self.assertEqual(r.stdout.strip(), "summary")


if __name__ == "__main__":
    unittest.main(verbosity=2)
