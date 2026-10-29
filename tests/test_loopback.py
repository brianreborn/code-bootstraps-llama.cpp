"""scripts/lib/loopback.py (used by cockpit.py, agent.py, lib/remote.py) against the shared
table tests/loopback-cases.txt.   python3 tests/test_loopback.py"""
import os
import sys
import unittest
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
from lib.loopback import is_loopback  # noqa: E402
from lib import remote  # noqa: E402


def cases():
    with open(os.path.join(ROOT, "tests", "loopback-cases.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("#"):
                continue
            v, want = line.rsplit("|", 1)
            yield v, want == "1"


class T(unittest.TestCase):
    def test_table(self):
        n = 0
        for v, want in cases():
            n += 1
            with self.subTest(v=v):
                self.assertEqual(is_loopback(v), want)
        self.assertGreater(n, 20)

    def test_cockpit_uses_shared_helper(self):
        sys.path.insert(0, os.path.join(ROOT, "scripts", "lib"))
        src = open(os.path.join(ROOT, "scripts", "cockpit.py"), encoding="utf-8").read()
        self.assertIn("from loopback import is_loopback", src)

    def test_remote_check_url(self):
        for url in ("http://127.0.0.1:9931", "http://localhost:1", "http://[::1]:9931", "http://127.0.0.5:1"):
            remote.check_url(url, "k")  # no exit
        for url in ("http://192.168.1.2:9931", "http://0.0.0.0:1", "http://[::]:1"):
            with self.assertRaises(SystemExit):
                remote.check_url(url, "k")
        remote.check_url("https://192.168.1.2:9931", "k")
        self.assertEqual(urllib.parse.urlparse("http://[::1]:1").hostname, "::1")


if __name__ == "__main__":
    unittest.main()
