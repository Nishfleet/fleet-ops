"""The owner's caps (fleet-ops#10935): ci.yml under 50 lines, under 11 alert rules.

Two PRs moved a cap to fit their change (#11688 raised the CI line cap, #11689 added
an 11th alert rule). A change that needs more goes to the owner, not into the cap.
Alert rules are Prometheus `alert:` rules plus Grafana-provisioned rules.
"""
import pathlib

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]


def _rules(pattern: str) -> list[dict]:
    files = sorted(ROOT.glob(pattern))
    docs = [yaml.safe_load(f.read_text()) or {} for f in files]
    return [r for d in docs for g in d.get("groups", []) for r in g.get("rules", [])]


def test_ci_is_under_50_lines():
    lines = len((ROOT / ".github/workflows/ci.yml").read_text().splitlines())
    assert lines < 50, f"ci.yml has {lines} lines; the owner's cap is under 50. Ask the owner first."


def test_under_12_alert_rules():
    prometheus = [r["alert"] for r in _rules("rootfs/etc/prometheus/*_rules.yml") if "alert" in r]
    grafana = [r["title"] for r in _rules("config/grafana/provisioning/alerting/*.yaml")]
    alerts = prometheus + grafana
    assert len(alerts) < 12, f"{len(alerts)} alert rules {alerts}; the owner's cap is under 12. Ask the owner first."
