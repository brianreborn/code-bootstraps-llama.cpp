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
        for key in ("PROFILE", "MODELS_MAX", "VARIANT", "TOOLS", "GPU_LAYERS", "PORT", "EMBED_PORT",
                    "THREADS", "CTX", "REASONING", "HOST", "LOAD_MODE", "LOCALE",
                    "LANGUAGE_MODE", "WORKDIR", "REPACK", "TOOLS_RUNTIME", "SWAP_CODER",
                    "DETACH_MODE", "RAISE", "COPY_KEY", "NO_BROWSER", "BUILD", "FEELD_SNAP_FS", "ENGINE_CHAT"):
            self.assertIn(key, panel.FIELDS)
        self.assertNotIn("GGUF_HOME", panel.FIELDS)

    def test_wake_lock_is_not_a_panel_option(self):
        """WAKE_LOCK is mandatory on Android and must never be a user-configurable option."""
        self.assertNotIn("WAKE_LOCK", panel.FIELDS)
        self.assertNotIn("WAKE_LOCK", panel.DEFAULTS)
        self.assertNotIn("WAKE_LOCK", panel.CHOICES)
        self.assertNotIn("WAKE_LOCK", panel.HINTS)

    def test_detach_mode_choices(self):
        """DETACH_MODE must offer exactly the four supported detach methods."""
        self.assertIn("DETACH_MODE", panel.CHOICES)
        for choice in ("foreground", "nohup", "tmux", "screen"):
            self.assertIn(choice, panel.CHOICES["DETACH_MODE"])
        self.assertEqual(panel.DEFAULTS.get("DETACH_MODE"), "foreground")

    def test_mcp_cannot_be_disabled_via_panel(self):
        """No panel field must offer an option that silences MCP.
        MCP_CONFIG is not a panel field; there is no MCP on/off toggle."""
        # MCP_CONFIG must not be user-settable through the panel
        self.assertNotIn("MCP_CONFIG", panel.FIELDS)
        # No field whose name contains 'MCP' should appear (no MCP_ENABLE, MCP_MODE, etc.)
        for field in panel.FIELDS:
            self.assertNotIn("MCP", field.upper(),
                             msg=f"Field {field!r} exposes MCP as a panel option — MCP must always be on")

    def test_tools_auto_default_is_not_lean(self):
        """TOOLS default must be 'auto' and auto must not resolve to lean (lowram != lean tools)."""
        self.assertEqual(panel.DEFAULTS.get("TOOLS"), "auto")
        # 'lean' is a valid explicit user choice but must not be the default
        choices = panel.CHOICES.get("TOOLS", ())
        if choices:
            self.assertEqual(choices[0], "auto",
                             "First TOOLS choice should be 'auto' (the default)")

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
