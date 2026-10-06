#!/usr/bin/env python3
"""Transaction record and /local. No network, no real grok/agy/claude/codex."""
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
from lib import tx  # noqa: E402

AGENT = os.path.join(ROOT, "scripts", "agent.py")


class TxTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="tx-")
        self._prev = os.environ.get("AGENT_REMOTE_DIR")
        os.environ["AGENT_REMOTE_DIR"] = self.dir

    def tearDown(self):
        if self._prev is None:
            os.environ.pop("AGENT_REMOTE_DIR", None)
        else:
            os.environ["AGENT_REMOTE_DIR"] = self._prev
        shutil.rmtree(self.dir, ignore_errors=True)

    def _by_name(self):
        return {rec["name"]: rec for rec in tx.load()["tx"]}

    def test_nested_commit_is_not_durable_until_outer(self):
        self.assertEqual(tx.begin("outer"), 0)
        self.assertEqual(tx.begin("inner"), 0)
        self.assertEqual(tx.commit(), 0)
        rows = tx.load()["tx"]
        by = {rec["name"]: rec for rec in rows}
        self.assertEqual(by["inner"]["state"], "committed")
        self.assertEqual(by["inner"]["parent"], "outer")
        self.assertEqual(by["outer"]["state"], "open")
        self.assertEqual(by["inner"]["snap"], "inner")
        self.assertEqual(by["outer"]["snap"], "outer")
        self.assertFalse(tx.is_durable(rows, by["inner"]))
        self.assertFalse(tx.is_durable(rows, by["outer"]))
        self.assertEqual(tx.commit(), 0)
        rows = tx.load()["tx"]
        by = {rec["name"]: rec for rec in rows}
        self.assertTrue(tx.is_durable(rows, by["outer"]))
        self.assertTrue(tx.is_durable(rows, by["inner"]))
        path = os.path.join(self.dir, "tx.json")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.dir).st_mode), 0o700)

    def test_rollback_drops_writes_and_leaves_unrelated_file(self):
        keep = os.path.join(self.dir, "unrelated.txt")
        declared = os.path.join(self.dir, "declared.txt")
        with open(keep, "w", encoding="utf-8") as f:
            f.write("stay")
        with open(declared, "w", encoding="utf-8") as f:
            f.write("declared")
        self.assertEqual(tx.begin("job"), 0)
        self.assertEqual(tx.declare_write(declared), 0)
        self.assertEqual(tx.rollback(), 0)
        rec = self._by_name()["job"]
        self.assertEqual(rec["writes"], [])
        self.assertEqual(rec["state"], "rolledback")
        with open(keep, encoding="utf-8") as f:
            self.assertEqual(f.read(), "stay")
        with open(declared, encoding="utf-8") as f:
            self.assertEqual(f.read(), "declared")

    def test_savepoint_rollback_keeps_the_outer_open(self):
        self.assertEqual(tx.begin("outer"), 0)
        self.assertEqual(tx.begin("inner"), 0)
        self.assertEqual(tx.declare_write("/tmp/declared-only"), 0)
        self.assertEqual(tx.rollback(), 0)
        by = self._by_name()
        self.assertEqual(by["inner"]["state"], "rolledback")
        self.assertEqual(by["inner"]["writes"], [])
        self.assertEqual(by["outer"]["state"], "open")

    def test_status_shows_heuristic_after_rollback(self):
        self.assertEqual(tx.begin("h"), 0)
        self.assertEqual(tx.declare_write("/tmp/h"), 0)
        self.assertEqual(tx.set_outcome("heuristic"), 0)
        self.assertEqual(tx.rollback(), 0)
        rec = self._by_name()["h"]
        self.assertEqual(rec["state"], "rolledback")
        self.assertEqual(rec["writes"], [])
        self.assertEqual(rec["outcome"], "heuristic")
        out = subprocess.run(
            [sys.executable, AGENT, "--locale", "en", "--key-file", os.devnull, "/local status"],
            capture_output=True, text=True, env=os.environ.copy(), timeout=30)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("h rolledback null h writes=0 heuristic", out.stdout)

    def test_commit_and_rollback_with_nothing_open(self):
        env = os.environ.copy()
        base = [sys.executable, AGENT, "--locale", "en", "--key-file", os.devnull]
        for word in ("commit", "rollback"):
            out = subprocess.run(base + [f"/remote {word}"], capture_output=True, text=True, env=env, timeout=30)
            self.assertEqual(out.returncode, 1, out.stderr)
            tx_lines = [line for line in out.stderr.splitlines() if line.startswith("tx:")]
            self.assertEqual(tx_lines, ["tx: nothing open"])


class SnapTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="snap-")
        self._prev = os.environ.get("AGENT_REMOTE_DIR")
        os.environ["AGENT_REMOTE_DIR"] = self.dir

    def tearDown(self):
        if self._prev is None:
            os.environ.pop("AGENT_REMOTE_DIR", None)
        else:
            os.environ["AGENT_REMOTE_DIR"] = self._prev
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_declare_keeps_the_before_image(self):
        from lib import snap
        path = os.path.join(self.dir, "note.txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write("before")
        self.assertEqual(tx.begin("job"), 0)
        self.assertEqual(tx.declare_write(path), 0)
        with open(path, "w", encoding="utf-8") as f:
            f.write("after")
        with open(snap.blob("job", 0), encoding="utf-8") as f:
            self.assertEqual(f.read(), "before")
        with open(path, encoding="utf-8") as f:
            self.assertEqual(f.read(), "after")
        self.assertEqual(snap.driver(), "virtual")

    def test_freeze_stops_only_our_child(self):
        from lib import snap
        child = subprocess.Popen(["sleep", "30"])
        try:
            held = snap.freeze([child.pid, os.getpid(), 1])
            self.assertEqual(held, [child.pid])
            self.assertEqual(snap._state(child.pid), "T")
            snap.thaw(held)
            self.assertNotEqual(snap._state(child.pid), "T")
        finally:
            child.kill()
            child.wait(timeout=5)


class LocalTests(unittest.TestCase):
    def test_local_rejects_unknown_and_runs_fake_grok(self):
        d = tempfile.mkdtemp(prefix="tx-local-")
        bindir = os.path.join(d, "bin")
        os.makedirs(bindir)
        marker = os.path.join(d, "ran")
        # Not named python3: FEELD_LOCAL_BIN is first on PATH, and a python3 there would
        # recurse through the fake grok shebang.
        bad = os.path.join(bindir, "evil")
        with open(bad, "w", encoding="utf-8") as f:
            f.write(
                "#!/usr/bin/python3\n"
                "import pathlib\n"
                f"pathlib.Path({marker!r}).write_text('ran')\n"
                "print('should-not-run')\n"
            )
        os.chmod(bad, 0o755)
        fake = os.path.join(bindir, "grok")
        with open(fake, "w", encoding="utf-8") as f:
            f.write(
                "#!/usr/bin/python3\n"
                "import sys\n"
                "print('grok-out')\n"
                "print(' '.join(sys.argv[1:]))\n"
            )
        os.chmod(fake, 0o755)
        env = os.environ.copy()
        env["AGENT_REMOTE_DIR"] = d
        env["FEELD_LOCAL_BIN"] = bindir
        base = [sys.executable, AGENT, "--locale", "en", "--key-file", os.devnull, "--cwd", "/tmp"]
        try:
            refused = subprocess.run(base + ["/local evil"], capture_output=True, text=True, env=env, timeout=30)
            self.assertEqual(refused.returncode, 1, refused.stderr)
            self.assertNotIn("should-not-run", refused.stdout)
            self.assertFalse(os.path.exists(marker))
            ran = subprocess.run(base + ["/local grok hello"], capture_output=True, text=True, env=env, timeout=30)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            self.assertIn("grok-out", ran.stdout)
            self.assertIn("hello", ran.stdout)
            shared = subprocess.run(base + ["/local begin job"], capture_output=True, text=True, env=env, timeout=30)
            self.assertEqual(shared.returncode, 0, shared.stderr)
            seen = subprocess.run(base + ["/remote status"], capture_output=True, text=True, env=env, timeout=30)
            self.assertEqual(seen.returncode, 0, seen.stderr)
            self.assertIn("job open null job writes=0 -", seen.stdout)
        finally:
            shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
