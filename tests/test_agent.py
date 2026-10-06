#!/usr/bin/env python3
"""Regression tests for scripts/agent.py against a fake llama-server (stdlib only, no model).

    python3 tests/test_agent.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
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
    turns: a list of calls, or a string (final answer). With tool_choice none it answers.
    `reasoning` is a string, or a list of stream pieces. `sse` returns text/event-stream
    when the request sets stream; otherwise the body is one JSON object, as before."""

    def __init__(self, tools, script, reasoning=None, sse=False):
        self.tools, self.script, self.executed, self.chats, self.remote_bodies = tools, list(script), [], [], []
        self.sse = sse
        if isinstance(reasoning, list):
            self.reasoning_parts = [str(p) for p in reasoning]
        elif reasoning:
            self.reasoning_parts = [str(reasoning)]
        else:
            self.reasoning_parts = []
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

            def reply_sse(self, msg):
                def chunk(delta, finish=None, timings=None):
                    obj = {"choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
                    if timings is not None:
                        obj["timings"] = timings
                    return "data: " + json.dumps(obj) + "\n\n"
                parts = [chunk({"role": "assistant"})]
                for piece in fake.reasoning_parts:
                    parts.append(chunk({"reasoning_content": piece}))
                if msg.get("content"):
                    parts.append(chunk({"content": msg["content"]}))
                for i, tc in enumerate(msg.get("tool_calls") or []):
                    fn = tc["function"]
                    args = fn.get("arguments") or ""
                    head, tail = args[:1], args[1:]
                    parts.append(chunk({"tool_calls": [{
                        "index": i, "id": tc.get("id", ""), "type": "function",
                        "function": {"name": fn["name"], "arguments": head}}]}))
                    if tail:
                        parts.append(chunk({"tool_calls": [{"index": i, "function": {"arguments": tail}}]}))
                finish = "tool_calls" if msg.get("tool_calls") else "stop"
                parts.append(chunk({}, finish, {"predicted_per_second": 3, "prompt_per_second": 4}))
                parts.append("data: [DONE]\n\n")
                b = "".join(parts).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
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
                if body.get("model") == "remote-model":
                    fake.remote_bodies.append(body)
                    msg = {"role": "assistant", "content": "PATCH"}
                    return self.reply({"choices": [{"message": msg}], "timings": {}})
                fake.chats.append(body)
                turn = fake.script.pop(0) if fake.script and body.get("tool_choice") != "none" else "summary"
                if isinstance(turn, str):
                    msg = {"role": "assistant", "content": turn}
                else:
                    msg = {"role": "assistant", "content": "", "tool_calls": [
                        {"id": f"c{len(fake.chats)}-{i}", "type": "function",
                         "function": {"name": c["name"], "arguments": json.dumps(c["args"])}} for i, c in enumerate(turn)]}
                if fake.reasoning_parts:
                    msg["reasoning_content"] = "".join(fake.reasoning_parts)
                if fake.sse and body.get("stream"):
                    return self.reply_sse(msg)
                self.reply({"choices": [{"message": msg}], "timings": {}})

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def run_agent(fake, *args, stdin=subprocess.DEVNULL, prompt="do the task", remote_dir=None, env_extra=None):
    own = remote_dir is None
    if own:
        remote_dir = tempfile.mkdtemp(prefix="agent-remote-")
    env = os.environ.copy()
    env.pop("REASONING", None)
    if env_extra:
        env.update(env_extra)
    env["AGENT_REMOTE_DIR"] = remote_dir
    cmd = [sys.executable, AGENT, "--url", fake.url, "--key-file", os.devnull, "--locale", "en", *args, prompt]
    try:
        return subprocess.run(cmd, stdin=stdin, capture_output=True, text=True, timeout=60, env=env)
    finally:
        if own:
            shutil.rmtree(remote_dir, ignore_errors=True)


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
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("why=repeat", r.stderr)
        self.assertIn("remote=off", r.stderr)

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
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("why=limit", r.stderr)

    def test_three_unknown_tools_exit_stuck(self):
        fake = FakeServer(BUILTINS, [[call("nope"), call("nope"), call("nope")], "should-not-run"])
        try:
            r = run_agent(fake, "--yes")
        finally:
            fake.close()
        self.assertEqual(fake.executed, [], r.stderr)
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("why=errors", r.stderr)
        self.assertNotIn("should-not-run", r.stdout)

    def test_auto_remote_sends_one_terse_brief(self):
        d = tempfile.mkdtemp(prefix="agent-remote-")
        fake = FakeServer(BUILTINS, [[call("exec_shell_command", command="python3 hello.py")]] * 6)
        try:
            os.makedirs(os.path.join(d, "keys"))
            with open(os.path.join(d, "keys", "work.key"), "w", encoding="utf-8") as f:
                f.write("rk-test-key\n")
            state = {
                "auto": True, "login": "work", "session": "s1",
                "logins": {"work": {"via": "http", "url": fake.url, "model": "remote-model"}},
                "sessions": {"work/s1": {"workspace": "", "last": "", "pending": None, "remote_id": ""}},
            }
            with open(os.path.join(d, "remote.json"), "w", encoding="utf-8") as f:
                json.dump(state, f)
            r = run_agent(fake, "--yes", remote_dir=d)
        finally:
            fake.close()
            shutil.rmtree(d, ignore_errors=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("summary", r.stdout)
        self.assertIn("PATCH", r.stdout)
        self.assertEqual(len(fake.remote_bodies), 1, r.stderr)
        body = fake.remote_bodies[0]
        self.assertNotIn("tools", body)
        self.assertEqual(body["max_tokens"], 384)
        brief = body["messages"][-1]["content"]
        self.assertIn("why=repeat", brief)
        self.assertLessEqual(len(brief), 1600)
        self.assertNotIn("rk-test-key", brief)


class ConnectionTests(unittest.TestCase):
    def test_server_gone_is_one_line(self):
        # Windows test (qodesh): closing the server mid-run printed a ConnectionResetError traceback
        import socket
        srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1)
        port = srv.getsockname()[1]

        def reset_once():   # accept, then close with RST (SO_LINGER 0) like a killed server
            c, _ = srv.accept()
            c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\x01\x00\x00\x00\x00\x00\x00\x00")
            c.close()
        t = threading.Thread(target=reset_once, daemon=True); t.start()
        try:
            r = subprocess.run([sys.executable, AGENT, "--url", f"http://127.0.0.1:{port}", "--key-file", os.devnull,
                                "--locale", "en", "x"], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
        finally:
            srv.close()
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("Traceback", r.stderr)
        self.assertIn("lost the connection", r.stderr)


class ReasoningTests(unittest.TestCase):
    def _one(self, reasoning=None, sse=False, env=None, model=None, script=None):
        script = script if script is not None else ["done"]
        fake = FakeServer(BUILTINS, script, reasoning=reasoning, sse=sse)
        args = ("--model", model) if model else ()
        try:
            return fake, run_agent(fake, *args, env_extra=env)
        finally:
            fake.close()

    def test_empty_and_off_send_nothing(self):
        for env in (None, {"REASONING": ""}, {"REASONING": "off"}):
            fake, r = self._one(env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
            body = fake.chats[0]
            self.assertNotIn("chat_template_kwargs", body)
            self.assertNotIn("stream", body)
            self.assertNotIn("[think]", r.stderr)

    def test_on_sets_enable_thinking_for_general_and_coder_only(self):
        for model in ("coder", "general"):
            fake, r = self._one(env={"REASONING": "on"}, model=model)
            self.assertEqual(r.returncode, 0, r.stderr)
            body = fake.chats[0]
            self.assertIs(body["stream"], True)
            self.assertIs(body["chat_template_kwargs"]["enable_thinking"], True)
        fake, r = self._one(env={"REASONING": "on"}, model="decision")
        self.assertEqual(r.returncode, 0, r.stderr)
        body = fake.chats[0]
        self.assertNotIn("chat_template_kwargs", body)
        self.assertNotIn("stream", body)
        fake, r = self._one(env={"REASONING": "auto"}, model="coder")
        self.assertEqual(r.returncode, 0, r.stderr)
        body = fake.chats[0]
        self.assertIs(body["stream"], True)
        self.assertNotIn("chat_template_kwargs", body)

    def test_json_reasoning_is_printed_and_tools_still_run(self):
        # The fake server ignores stream and returns one JSON body, which is what test_agent always did.
        fake, r = self._one(reasoning="plan the edit", env={"REASONING": "on"},
                            script=[[call("read_file", path="a.txt")], "done"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("[think] plan the edit", r.stderr)
        self.assertEqual(fake.executed, [("read_file", {"path": "a.txt"})], r.stderr)
        self.assertEqual(r.stdout.strip(), "done")
        self.assertIs(fake.chats[0]["chat_template_kwargs"]["enable_thinking"], True)
        self.assertEqual(fake.chats[1]["messages"][2].get("reasoning_content"), "plan the edit")

    def test_off_still_prints_reasoning_that_arrived(self):
        fake, r = self._one(reasoning="already thinking", env={"REASONING": "off"})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("chat_template_kwargs", fake.chats[0])
        self.assertIn("[think] already thinking", r.stderr)
        self.assertEqual(r.stdout.strip(), "done")

    def test_sse_prints_think_tokens_as_they_arrive(self):
        fake, r = self._one(reasoning=["hel", "lo"], sse=True, env={"REASONING": "on"},
                            script=[[call("read_file", path="a.txt")], "done"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("[think] hello", r.stderr)
        self.assertEqual(r.stderr.count("[think]"), 2, r.stderr)  # one thought per step
        self.assertEqual(fake.executed, [("read_file", {"path": "a.txt"})], r.stderr)
        self.assertEqual(r.stdout.strip(), "done")
        self.assertIn("3.0 tok/s", r.stderr)
        self.assertEqual(fake.chats[1]["messages"][2].get("reasoning_content"), "hello")

    def test_unknown_reasoning_fails(self):
        fake = FakeServer(BUILTINS, ["done"])
        try:
            r = run_agent(fake, env_extra={"REASONING": "yes"})
        finally:
            fake.close()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("unknown REASONING", r.stderr)
        self.assertEqual(fake.chats, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
