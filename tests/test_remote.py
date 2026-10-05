#!/usr/bin/env python3
"""Remote brief shape and local-client argv. No real grok/agy/claude/codex process."""
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
from lib import remote  # noqa: E402


class BriefTests(unittest.TestCase):
    def test_media_is_a_path_and_text_is_clipped(self):
        wav = os.path.join(tempfile.gettempdir(), "clip.wav")
        brief = remote.build_brief(
            "ask", "hear clip.wav", "/work",
            [{"path": "a.py", "body": "x" * 5000}, {"path": wav, "body": "RIFF" + "z" * 5000},
             {"path": ".secrets/api-keys", "body": "super-secret-value"}],
            {"name": "exec_shell_command", "args": "python3 hello.py"},
            {"name": "read_file", "text": "tool-output"},
            redact="super-secret-value")
        self.assertLessEqual(len(brief), remote.BRIEF_MAX)
        self.assertIn("kind=audio", brief)
        self.assertIn("path=" + wav, brief)
        self.assertNotIn("RIFF", brief)
        self.assertNotIn("super-secret-value", brief)
        self.assertIn("omitted", brief)
        self.assertLess(brief.count("x"), 400)

    def test_local_client_omits_text_bodies(self):
        brief = remote.build_brief("ask", "t", "/w", [{"path": "a.py", "body": "print(1)"}], {}, {}, files_only=True)
        self.assertIn("path=a.py", brief)
        self.assertNotIn("print(1)", brief)


class LaunchPlanTests(unittest.TestCase):
    def test_grok_and_claude_start_then_resume(self):
        spec = {"via": "grok", "args": []}
        argv, sid, started, stdin = remote.plan_launch(spec, "brief", [], "/w", "", "/tmp/p.txt")
        self.assertTrue(started)
        self.assertIsNone(stdin)
        self.assertIn("--session-id", argv)
        self.assertNotIn("--resume", argv)
        self.assertIn("--prompt-file", argv)
        argv2, sid2, started2, _ = remote.plan_launch(spec, "brief", [], "/w", sid, "/tmp/p.txt")
        self.assertFalse(started2)
        self.assertEqual(sid2, sid)
        self.assertIn("--resume", argv2)
        self.assertNotIn("--session-id", argv2)

        spec = {"via": "claude", "args": ["--model", "opus"]}
        argv, sid, started, _ = remote.plan_launch(spec, "brief", [], "/w", "", "/tmp/p.txt")
        self.assertTrue(started)
        self.assertIn("--session-id", argv)
        self.assertIn("--max-turns", argv)
        self.assertEqual(argv[-1], "brief")
        argv2, _, started2, _ = remote.plan_launch(spec, "next", [], "/w", sid, "/tmp/p.txt")
        self.assertFalse(started2)
        self.assertIn("--resume", argv2)
        self.assertIn(sid, argv2)

    def test_agy_codex_and_exec_files(self):
        argv, sid, started, _ = remote.plan_launch({"via": "agy"}, "brief", [], "/w", "", "/tmp/p.txt")
        self.assertTrue(started)
        self.assertEqual(sid, "")
        self.assertNotIn("--conversation", argv)
        argv2, _, started2, _ = remote.plan_launch({"via": "agy"}, "brief", [], "/w", "conv-1", "/tmp/p.txt")
        self.assertFalse(started2)
        self.assertEqual(argv2[argv2.index("--conversation") + 1], "conv-1")

        img = "/tmp/pic.png"
        wav = "/tmp/clip.wav"
        argv, _, started, _ = remote.plan_launch({"via": "codex"}, "brief", [img, wav], "/w", "", "/tmp/p.txt")
        self.assertTrue(started)
        self.assertEqual(argv[:2], ["codex", "exec"])
        self.assertIn(img, argv)
        self.assertNotIn(wav, argv)  # audio is a path= line, not codex -i
        argv2, _, started2, _ = remote.plan_launch({"via": "codex"}, "brief", [img], "/w", "thr-9", "/tmp/p.txt")
        self.assertFalse(started2)
        self.assertEqual(argv2[2:4], ["resume", "thr-9"])

        spec = {"via": "exec", "bin": "tool", "args": ["{new}", "{session}"]}
        argv, _, started, stdin = remote.plan_launch(spec, "brief", [wav], "/w", "", "/tmp/p.txt")
        self.assertTrue(started)
        self.assertEqual(argv[0], "tool")
        self.assertEqual(argv[1], "1")
        self.assertEqual(stdin, "brief")
        self.assertEqual(argv[-1], wav)
        argv2, _, started2, _ = remote.plan_launch(spec, "brief", [wav], "/w", "sess", "/tmp/p.txt")
        self.assertFalse(started2)
        self.assertEqual(argv2[1], "0")
        self.assertEqual(argv2[2], "sess")

    def test_exec_login_hands_off_audio_path(self):
        d = tempfile.mkdtemp(prefix="remote-exec-")
        wav = os.path.join(d, "clip.wav")
        with open(wav, "wb") as f:
            f.write(b"RIFF-not-a-real-wav")
        script = os.path.join(d, "fake-client.py")
        with open(script, "w", encoding="utf-8") as f:
            f.write(textwrap.dedent("""\
                import sys
                data = sys.stdin.read()
                open(sys.argv[1], "w", encoding="utf-8").write(data + "\\n" + "\\n".join(sys.argv[2:]))
                print("heard")
                print("session_id=sess-7")
                """))
        log = os.path.join(d, "seen.txt")
        env = os.environ.copy()
        env["AGENT_REMOTE_DIR"] = d
        agent = os.path.join(ROOT, "scripts", "agent.py")
        base = [sys.executable, agent, "--locale", "en", "--key-file", os.devnull]
        r = subprocess.run(base + [f"/remote login ear exec {sys.executable} {script} {log}"],
                           capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        r = subprocess.run(base + ["--cwd", d, f"/remote ask describe {wav}"],
                           capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("heard", r.stdout)
        self.assertIn("start", r.stderr)
        with open(log, encoding="utf-8") as f:
            seen = f.read()
        self.assertIn("kind=audio", seen)
        self.assertIn(wav, seen)
        self.assertNotIn("RIFF", seen)
        r = subprocess.run(base + ["--cwd", d, "/remote ask again"],
                           capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("resume", r.stderr)
        with open(os.path.join(d, "remote.json"), encoding="utf-8") as f:
            state = json.load(f)
        self.assertEqual(state["sessions"]["ear/default"]["remote_id"], "sess-7")

    def test_ask_does_not_hold_the_lock_and_take_uses_the_saved_workspace(self):
        d = tempfile.mkdtemp(prefix="remote-lock-")
        other = tempfile.mkdtemp(prefix="remote-ws-")
        script = os.path.join(d, "fake-client.py")
        with open(script, "w", encoding="utf-8") as f:
            f.write(textwrap.dedent("""\
                import fcntl, os, sys
                lock = os.path.join(os.environ["AGENT_REMOTE_DIR"], "remote.json.lock")
                held = open(lock, "a+b")
                try:
                    fcntl.flock(held.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    print("unlocked")
                    fcntl.flock(held.fileno(), fcntl.LOCK_UN)
                except BlockingIOError:
                    print("locked")
                print(os.getcwd())
                print("session_id=s1")
                """))
        env = os.environ.copy()
        env["AGENT_REMOTE_DIR"] = d
        agent = os.path.join(ROOT, "scripts", "agent.py")
        base = [sys.executable, agent, "--locale", "en", "--key-file", os.devnull]
        r = subprocess.run(base + [f"/remote login ear exec {sys.executable} {script}"],
                           capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        r = subprocess.run(base + ["--cwd", d, "/remote ask hello"],
                           capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("unlocked", r.stdout.splitlines())
        state = {
            "auto": False, "login": "ear", "session": "default",
            "logins": {"ear": {"via": "exec", "bin": sys.executable, "args": [script]}},
            "sessions": {
                "-/default": {"workspace": other, "last": "", "pending": {
                    "why": "repeat", "brief": "task\n", "workspace": other}},
            },
        }
        with open(os.path.join(d, "remote.json"), "w", encoding="utf-8") as f:
            json.dump(state, f)
        r = subprocess.run(base + ["--cwd", d, "/remote take"],
                           capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        self.assertIn("unlocked", lines)
        self.assertIn(os.path.realpath(other), lines)


if __name__ == "__main__":
    unittest.main(verbosity=2)
