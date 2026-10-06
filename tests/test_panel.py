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


class FieldTests(unittest.TestCase):
    def test_major_settings_are_fields(self):
        for key in ("PROFILE", "MODELS_MAX", "VARIANT", "TOOLS", "GPU_LAYERS", "PORT",
                    "THREADS", "CTX", "REASONING", "HOST", "LOAD_MODE", "LOCALE",
                    "LANGUAGE_MODE", "WORKDIR", "REPACK", "TOOLS_RUNTIME", "SWAP_CODER"):
            self.assertIn(key, panel.FIELDS)
        self.assertNotIn("GGUF_HOME", panel.FIELDS)

    def test_check_refuses_unknown_and_accepts_auto(self):
        self.assertEqual(panel.check("LANGUAGE_MODE", "auto"), "auto")
        self.assertEqual(panel.check("REASONING", "on"), "on")
        self.assertEqual(panel.check("LOAD_MODE", "mlock"), "mlock")
        self.assertEqual(panel.check("HOST", "::1"), "::1")
        for key, bad in (("PROFILE", "nope"), ("REASONING", "yes"), ("LANGUAGE_MODE", "yes"),
                         ("LOAD_MODE", "pin"), ("PORT", "0"), ("MODELS_MAX", "9"),
                         ("CTX", "100"), ("TOOLS_RUNTIME", "bogus"), ("HOST", "bad host")):
            with self.assertRaises(ValueError):
                panel.check(key, bad)

    def test_write_env_omits_defaults(self):
        tmp = tempfile.mkdtemp(prefix="panel-env-")
        old = panel.ENV_PATH
        panel.ENV_PATH = os.path.join(tmp, "panel.env")
        try:
            panel.write_env({
                "PROFILE": "auto",
                "PORT": "9944",
                "REASONING": "off",
                "LANGUAGE_MODE": "auto",
                "THREADS": "auto",
                "LOAD_MODE": "auto",
                "HOST": "127.0.0.1",
                "MODELS_MAX": "2",
            })
            with open(panel.ENV_PATH, encoding="utf-8") as fh:
                text = fh.read()
        finally:
            panel.ENV_PATH = old
        self.assertEqual(text, ': "${PORT:=9944}"\n: "${LANGUAGE_MODE:=auto}"\n')
        for key in ("PROFILE", "REASONING", "THREADS", "LOAD_MODE", "HOST", "MODELS_MAX"):
            self.assertNotIn(key, text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
