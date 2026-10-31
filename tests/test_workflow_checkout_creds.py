"""H2: every actions/checkout must set persist-credentials: false."""
import pathlib
import yaml

WF = pathlib.Path(__file__).resolve().parents[1] / ".github" / "workflows"


def test_checkout_never_persists_credentials():
    found = 0
    for f in sorted(WF.glob("*.yml")):
        doc = yaml.safe_load(f.read_text())
        for name, job in (doc.get("jobs") or {}).items():
            for step in job.get("steps", []):
                if str(step.get("uses", "")).startswith("actions/checkout"):
                    found += 1
                    w = step.get("with") or {}
                    assert w.get("persist-credentials") is False, f"{f.name}:{name} checkout persists credentials"
    assert found
