#!/usr/bin/env python3
"""Serve-time enforcement of config/security-gating.json for starter MCP picks. FAIL-CLOSED.

decide(name, entry, ctx) -> (allowed: bool, reason: str). A refused pick is dropped alone;
the base config and the rest of the swarm keep serving (failure_policy.never_stop_swarm).

  * gating file missing / unreadable / malformed  -> every starter pick refused
  * pick listed in the kill switch file            -> refused (live; re-read every start)
  * unknown or missing _tier                       -> refused
  * tier "audit" with no healthy guard declared    -> allowed with a warning (no_guard policy)
  * tier "risky"                                   -> refused unless ALL hold:
      - config/sandbox-spec.<name>.json exists with every sandbox_spec.fields key non-empty
      - expires_at is in the future, signed_at is not
      - <spec>.sig is an `ssh-keygen -Y sign -n familia-sandbox` signature of the spec file
        by the principal == admin_name, listed in the admin allowed-signers file
        (config/admin-allowed-signers, or SANDBOX_ALLOWED_SIGNERS)
      - a guard is declared healthy (FAMILIA_GUARD_HEALTHY=1) because no_guard is
        fail_closed_self_only; admin override: MCP_ADMIN_OVERRIDE=<admin_name> (logged)
"""
import datetime as dt
import json
import os
import shutil
import subprocess
import sys

NAMESPACE = "familia-sandbox"
KNOWN_TIERS = ("utility", "guard", "audit", "risky")


def _load(path):
    with open(path, encoding="utf-8-sig") as f:
        return json.load(f)


def _ts(value):
    v = str(value).strip().replace("Z", "+00:00")
    t = dt.datetime.fromisoformat(v)
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


class Gate:
    def __init__(self, root, gating_path=None, env=None, now=None):
        self.root = root
        self.env = os.environ if env is None else env
        self.now = now or dt.datetime.now(dt.timezone.utc)
        self.log = []
        path = gating_path or os.path.join(root, "config", "security-gating.json")
        try:
            g = _load(path)
            self.tiers = g["tiers"]
            self.spec_fields = list(g["sandbox_spec"]["fields"])
            self.spec_pattern = g["sandbox_spec"].get("file_pattern", "config/sandbox-spec.<name>.json")
            self.kill_file = g.get("kill_switch", {}).get("file", "state/disabled-models.json")
            if not isinstance(self.tiers, dict) or not self.spec_fields:
                raise ValueError("tiers/sandbox_spec.fields empty")
            self.error = None
        except (OSError, ValueError, KeyError, TypeError) as e:
            self.error = f"security gating unavailable ({path}: {e})"

    def _disabled(self):
        p = os.path.join(self.root, self.kill_file)
        if not os.path.exists(p):
            return set()
        try:
            d = _load(p)
        except (OSError, ValueError):
            return None  # unreadable kill switch: fail closed
        if isinstance(d, dict):
            d = d.get("disabled", [])
        return {str(x) for x in d} if isinstance(d, list) else None

    def _verify_sig(self, spec_path, admin):
        signers = self.env.get("SANDBOX_ALLOWED_SIGNERS") or os.path.join(self.root, "config", "admin-allowed-signers")
        sig = spec_path + ".sig"
        if not os.path.exists(sig):
            return f"no signature {os.path.basename(sig)}"
        if not os.path.exists(signers):
            return "no admin allowed-signers file"
        kg = shutil.which("ssh-keygen")
        if not kg:
            return "ssh-keygen not found, cannot verify"
        with open(spec_path, "rb") as f:
            r = subprocess.run([kg, "-Y", "verify", "-f", signers, "-I", admin, "-n", NAMESPACE, "-s", sig],
                               stdin=f, capture_output=True)
        return None if r.returncode == 0 else f"signature not valid for admin '{admin}'"

    def _sandbox(self, name):
        rel = self.spec_pattern.replace("<name>", name)
        p = os.path.join(self.root, rel)
        if not os.path.exists(p):
            return f"no sandbox spec {rel}"
        try:
            spec = _load(p)
        except (OSError, ValueError) as e:
            return f"sandbox spec unreadable ({e})"
        missing = [k for k in self.spec_fields if not spec.get(k)]
        if missing:
            return "sandbox spec missing " + ",".join(missing)
        if spec["name"] != name:
            return f"sandbox spec is for '{spec['name']}'"
        try:
            if _ts(spec["expires_at"]) <= self.now:
                return "sandbox spec expired"
            if _ts(spec["signed_at"]) > self.now:
                return "sandbox spec signed_at is in the future"
        except ValueError:
            return "sandbox spec has a bad timestamp"
        return self._verify_sig(p, str(spec["admin_name"]))

    def decide(self, name, entry):
        if self.error:
            return False, self.error
        disabled = self._disabled()
        if disabled is None:
            return False, "kill switch file unreadable"
        if name in disabled:
            return False, "disabled by kill switch"
        tier = entry.get("_tier")
        if tier not in KNOWN_TIERS:
            return False, f"unknown tier {tier!r}"
        if tier in ("utility", "guard"):
            return True, tier
        guard_ok = self.env.get("FAMILIA_GUARD_HEALTHY") == "1"
        if tier == "audit":
            return True, "audit" + ("" if guard_ok else " (WARNING: no healthy guard)")
        why = self._sandbox(name)
        if why:
            return False, f"risky: {why}"
        override = self.env.get("MCP_ADMIN_OVERRIDE", "")
        if not guard_ok and not override:
            return False, "risky: no healthy guard (fail_closed_self_only)"
        return True, "risky: signed sandbox" + (f", admin override by {override}" if override and not guard_ok else "")
