"""scripts/lib/metrics.py: config/metrics.json gates telemetry; one turbo switch turns it all off."""
import http.server
import json
import os
import shutil
import sys
import threading

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts", "lib"))
import metrics  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


@pytest.fixture
def root(tmp_path):
    (tmp_path / "config").mkdir()
    shutil.copy(os.path.join(REPO, "config/metrics.json"), tmp_path / "config")
    return tmp_path


def setcfg(root, **kv):
    p = root / "config/metrics.json"
    c = json.loads(p.read_text())
    c.update(kv)
    p.write_text(json.dumps(c))


def test_shipped_default_is_on():
    assert metrics.state(metrics.load(REPO), env={}) == (True, "on")


def test_each_turbo_switch_turns_off(root):
    cfg = metrics.load(str(root))
    assert not metrics.state(cfg, {}, turbo_flag=True)[0]
    assert not metrics.state(cfg, {"FAMILIA_TURBO": "1"})[0]
    assert metrics.state(cfg, {"FAMILIA_TURBO": "0"})[0]
    setcfg(root, turbo_button={"turbo": True})
    assert metrics.state(metrics.load(str(root)), {}) == (False, "turbo (config/metrics.json)")


def test_turbo_overrides_enabled_and_enabled_false(root):
    setcfg(root, enabled=False)
    assert not metrics.state(metrics.load(str(root)), {})[0]


def test_broken_config_defaults_on(tmp_path):
    (tmp_path / "config").mkdir()
    (tmp_path / "config/metrics.json").write_text("{x")
    assert metrics.state(metrics.load(str(tmp_path)), {})[0]


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        body = b'{"status":"ok"}' if self.path == "/health" else \
            b"# HELP x\nllamacpp:predicted_tokens_seconds 42.5\nllamacpp:prompt_tokens_seconds 100\n"
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


@pytest.fixture
def server():
    s = http.server.HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{s.server_address[1]}"
    s.shutdown()


def test_sampler_writes_rolling_state_when_on(root, server):
    setcfg(root, collect={"rolling_window_samples": 2, "tokens_per_second": True, "node_health": True})
    for _ in range(3):
        assert metrics.main(["sample", "--url", server, "--once", "--engine", "b1"], env={}, root=str(root)) == 0
    st = json.loads((root / "state/metrics.json").read_text())
    assert len(st["rolling"]) == 2 and st["rolling"][-1]["tokens_per_second"] == 42.5
    assert st["rolling"][-1]["health"] == "ok" and st["engine"] == "b1" and "initial" in st


def test_turbo_sampler_collects_nothing(root, server):
    assert metrics.main(["sample", "--url", server, "--once"], env={"FAMILIA_TURBO": "1"}, root=str(root)) == 0
    assert not (root / "state").exists()
    assert metrics.main(["sample", "--url", server, "--once", "--turbo"], env={}, root=str(root)) == 0
    assert not (root / "state").exists()


def test_sampler_refuses_non_loopback(root):
    assert metrics.main(["sample", "--url", "http://10.0.0.5:9931", "--once"], env={}, root=str(root)) == 2


def test_status_exit_codes(root, capsys):
    assert metrics.main(["status"], env={}, root=str(root)) == 0
    assert metrics.main(["status", "--turbo"], env={}, root=str(root)) == 3
    assert "off (turbo" in capsys.readouterr().out
