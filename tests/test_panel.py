#!/usr/bin/env python3
"""Panel: status port, fields, the accessible form, preview/save/undo, localhost-only."""
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


class AccessibleFormTests(unittest.TestCase):
    """The form is built for a keyboard, a switch, a mouse or a screen reader (see panel.py)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="panel-a11y-")
        self.old = (panel.ENV_PATH, panel.UNDO_DIR)
        panel.ENV_PATH = os.path.join(self.tmp, "panel.env")
        panel.UNDO_DIR = os.path.join(self.tmp, "undo")
        self.app = panel.App()

    def tearDown(self):
        panel.ENV_PATH, panel.UNDO_DIR = self.old

    def post(self, path, **fields):
        form = {k: [v] for k, v in fields.items()}
        form["token"] = [panel.TOKEN]
        return self.app.route("POST", path, form_=form)

    def test_every_page_passes_the_check(self):
        from lib import a11y_check
        bad = [(w, p) for w, h in panel.all_pages_html(self.app) for p in a11y_check.problems(h)]
        self.assertEqual(bad, [])

    def test_checker_catches_the_old_table_form(self):
        from lib import a11y_check
        old = '<!doctype html><title>x</title><table><tr><td>PORT</td><td><input name="PORT"></td></tr></table>' \
              '<select name="A"><option value=""></option></select><img src="a.png"><a href="#nope"></a>' \
              '<button tabindex="3">Save</button><script>1</script>'
        text = " ".join(a11y_check.problems(old))
        for frag in ("no lang", "<h1>", "<main>", "has no label", "no alt", "missing id", "tabindex=3",
                     "<script>", "<a> with no text"):
            self.assertIn(frag, text)

    def test_every_field_is_on_one_page_with_a_plain_label(self):
        keys = [k for _, _, _, ks in panel.SECTIONS for k in ks]
        self.assertEqual(sorted(keys), sorted(panel.FIELDS))
        for k in panel.FIELDS:
            self.assertTrue(panel.LABELS.get(k))

    def test_preview_writes_nothing_save_writes_undo_restores(self):
        s, h = self.post("/p/launch-network/preview", PORT="9944", EMBED_PORT="", HOST="")
        self.assertEqual(s, 200)
        self.assertIn("Model server port (PORT): default (9931) to 9944", h)
        self.assertFalse(os.path.exists(panel.ENV_PATH))
        s, h = self.post("/p/launch-network/save", PORT="9944", EMBED_PORT="9950", HOST="", do="save")
        self.assertEqual(s, 200, h)
        with open(panel.ENV_PATH, encoding="utf-8") as f:
            self.assertEqual(f.read(), ': "${PORT:=9944}"\n: "${EMBED_PORT:=9950}"\n')
        s, h = self.post("/undo")
        self.assertEqual(s, 200)
        self.assertIn("Undone", h)
        self.assertFalse(os.path.exists(panel.ENV_PATH))

    def test_saving_one_page_keeps_the_others(self):
        self.post("/p/launch-network/save", PORT="9944", EMBED_PORT="", HOST="", do="save")
        self.post("/p/launch-basics/save", PROFILE="lowram", MODELS_MAX="", REASONING="", LOCALE="",
                  LANGUAGE_MODE="", do="save")
        vals = panel.load_env()
        self.assertEqual((vals["PORT"], vals["PROFILE"]), ("9944", "lowram"))

    def test_error_keeps_what_was_typed_and_links_to_the_field(self):
        s, h = self.post("/p/launch-speed/preview", THREADS="3", CTX="100")
        self.assertEqual(s, 400)
        self.assertIn('role="alert"', h)
        self.assertIn('href="#f-CTX"', h)
        self.assertIn('value="3"', h)
        self.assertIn('aria-invalid="true"', h)
        self.assertFalse(os.path.exists(panel.ENV_PATH))

    def test_post_without_session_token_is_refused(self):
        s, _ = self.app.route("POST", "/p/launch-network/save", form_={"PORT": ["1"], "do": ["save"]})
        self.assertEqual(s, 403)
        self.assertFalse(os.path.exists(panel.ENV_PATH))

    def test_local_only(self):
        self.assertEqual(panel.HOST, "127.0.0.1")
        for h in ("127.0.0.1:9932", "localhost:9940", "[::1]:9932", "127.0.0.1"):
            self.assertTrue(panel.host_ok(h), h)
        for h in ("evil.example:9932", "127.0.0.1.evil.example", "192.168.1.5:9932", ""):
            self.assertFalse(panel.host_ok(h), h)
        self.assertTrue(panel.origin_ok(None))
        self.assertTrue(panel.origin_ok("http://127.0.0.1:9932"))
        self.assertFalse(panel.origin_ok("null"))
        self.assertFalse(panel.origin_ok("https://evil.example"))

    def test_embed_port_and_engine_chat_are_settable(self):
        self.assertEqual(panel.check("EMBED_PORT", "9950"), "9950")
        self.assertEqual(panel.check("ENGINE_CHAT", "edlm"), "edlm")
        with self.assertRaises(ValueError):
            panel.check("ENGINE_CHAT", "a b")


class LiveServerTests(unittest.TestCase):
    def test_serves_on_loopback_and_refuses_other_host_names(self):
        import socket
        import subprocess
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        tmp = tempfile.mkdtemp(prefix="panel-live-")
        env = dict(os.environ, PANEL_PORT=str(port))
        env.pop("PANEL_EXTRA", None)
        p = subprocess.Popen([sys.executable, os.path.join(ROOT, "scripts", "panel.py")], env=env, cwd=tmp,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        try:
            self.assertIn("127.0.0.1:%d" % port, p.stdout.readline())
            body = urllib.request.urlopen("http://127.0.0.1:%d/" % port, timeout=10).read().decode()
            self.assertIn('<html lang="en">', body)
            req = urllib.request.Request("http://127.0.0.1:%d/" % port, headers={"Host": "evil.example"})
            with self.assertRaises(urllib.error.HTTPError) as cm:
                urllib.request.urlopen(req, timeout=10)
            self.assertEqual(cm.exception.code, 403)
        finally:
            p.terminate()
            p.wait(10)
            p.stdout.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
