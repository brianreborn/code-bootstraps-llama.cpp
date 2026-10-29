"""scripts/lib/mcp_gate.py: security-gating.json enforced fail-closed for starter MCP picks."""
import datetime as dt
import json
import os
import shutil
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts", "lib"))
import mcp_gate  # noqa: E402
import mcp_load  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
NOW = dt.datetime(2026, 10, 28, tzinfo=dt.timezone.utc)
RISKY = {"_tier": "risky", "command": "shannon", "args": []}


@pytest.fixture
def root(tmp_path):
    (tmp_path / "config").mkdir()
    shutil.copy(os.path.join(REPO, "config/security-gating.json"), tmp_path / "config")
    return tmp_path


def spec(root, name="pent", **over):
    s = {"name": name, "admin_name": "brian", "admin_signature": "ssh-sig",
         "signed_at": "2026-10-27T00:00:00Z", "isolation": "vm", "network_policy": "none",
         "targets": ["staging"], "data_policy": "report-only", "expires_at": "2026-11-30T00:00:00Z"}
    s.update(over)
    p = root / "config" / f"sandbox-spec.{name}.json"
    p.write_text(json.dumps(s))
    return p


def sign(root, path, principal="brian"):
    key = root / "adminkey"
    if not key.exists():
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
    pub = (root / "adminkey.pub").read_text().strip()
    (root / "config" / "admin-allowed-signers").write_text(f"{principal} {pub}\n")
    subprocess.run(["ssh-keygen", "-q", "-Y", "sign", "-f", str(key), "-n", "familia-sandbox", str(path)],
                   check=True, capture_output=True)


def gate(root, **env):
    return mcp_gate.Gate(str(root), env=env, now=NOW)


def test_missing_gating_file_refuses_everything(tmp_path):
    ok, why = mcp_gate.Gate(str(tmp_path), env={}).decide("time", {"_tier": "utility"})
    assert not ok and "unavailable" in why


def test_utility_ok_unknown_tier_refused(root):
    assert gate(root).decide("time", {"_tier": "utility"})[0]
    assert not gate(root).decide("x", {})[0]


def test_kill_switch(root):
    (root / "state").mkdir()
    (root / "state/disabled-models.json").write_text('{"disabled": ["time"]}')
    assert gate(root).decide("time", {"_tier": "utility"}) == (False, "disabled by kill switch")
    (root / "state/disabled-models.json").write_text("{bad")
    assert not gate(root).decide("git", {"_tier": "utility"})[0]


def test_audit_allowed_with_warning(root):
    ok, why = gate(root).decide("a", {"_tier": "audit"})
    assert ok and "WARNING" in why


def test_risky_without_spec_refused(root):
    ok, why = gate(root, FAMILIA_GUARD_HEALTHY="1").decide("pent", RISKY)
    assert not ok and "no sandbox spec" in why


def test_risky_unsigned_refused(root):
    spec(root)
    ok, why = gate(root, FAMILIA_GUARD_HEALTHY="1").decide("pent", RISKY)
    assert not ok and "signature" in why


def test_risky_signed_allowed_only_with_guard(root):
    sign(root, spec(root))
    assert gate(root, FAMILIA_GUARD_HEALTHY="1").decide("pent", RISKY)[0]
    ok, why = gate(root).decide("pent", RISKY)
    assert not ok and "guard" in why
    assert gate(root, MCP_ADMIN_OVERRIDE="brian").decide("pent", RISKY)[0]


def test_risky_wrong_admin_tampered_expired(root):
    p = spec(root)
    sign(root, p, principal="mallory")
    assert not gate(root, FAMILIA_GUARD_HEALTHY="1").decide("pent", RISKY)[0]
    sign(root, p)
    p.write_text(p.read_text().replace("staging", "production"))
    assert not gate(root, FAMILIA_GUARD_HEALTHY="1").decide("pent", RISKY)[0]
    p2 = spec(root, expires_at="2026-10-01T00:00:00Z")
    sign(root, p2)
    ok, why = gate(root, FAMILIA_GUARD_HEALTHY="1").decide("pent", RISKY)
    assert not ok and "expired" in why
    p3 = spec(root, targets=[])
    sign(root, p3)
    assert "missing targets" in gate(root, FAMILIA_GUARD_HEALTHY="1").decide("pent", RISKY)[1]


def test_loader_drops_refused_pick_keeps_rest(root, tmp_path):
    base = tmp_path / "b.json"
    base.write_text('{"mcpServers": {"example": {"command": "python3"}}}')
    st = tmp_path / "s.json"
    st.write_text(json.dumps({"mcpServers": {"time": {"enabled": True, "_tier": "utility", "command": "uvx"},
                                             "pent": dict(RISKY, enabled=True)}}))
    cfg, added = mcp_load.build(str(root), str(base), str(st), set(), {}, gate(root))
    assert added == ["time"] and set(cfg["mcpServers"]) == {"example", "time"}
