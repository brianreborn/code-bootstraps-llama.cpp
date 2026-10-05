#!/usr/bin/env python3
"""Panel status uses the port recorded in .cache/serve.ready."""
import os
import sys
import tempfile
import unittest
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import panel  # noqa: E402


class ReadyPortTests(unittest.TestCase):
    def test_ready_file_port_is_the_one_probed(self):
        tmp = tempfile.mkdtemp(prefix="panel-ready-")
        os.makedirs(os.path.join(tmp, ".cache"))
        with open(os.path.join(tmp, ".cache", "serve.ready"), "w", encoding="utf-8") as f:
            f.write("9944 99\n")
        seen = []

        def fake_open(url, timeout=1):
            seen.append(url)

            class Resp:
                def read(self, n):
                    return b"ok"

            return Resp()

        old_root = panel.ROOT
        old_open = urllib.request.urlopen
        panel.ROOT = tmp
        urllib.request.urlopen = fake_open
        try:
            self.assertEqual(panel.server_line({"PORT": "9931"}), "up")
        finally:
            panel.ROOT = old_root
            urllib.request.urlopen = old_open
        self.assertEqual(seen, ["http://127.0.0.1:9944/health"])

    def test_missing_ready_file_is_down(self):
        tmp = tempfile.mkdtemp(prefix="panel-down-")
        old_root = panel.ROOT
        panel.ROOT = tmp
        try:
            self.assertEqual(panel.server_line({}), "down")
        finally:
            panel.ROOT = old_root


if __name__ == "__main__":
    unittest.main(verbosity=2)
