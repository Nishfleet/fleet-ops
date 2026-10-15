import json
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
YQ = shutil.which("yq")


def _router_rows():
    assert YQ, "yq must be on PATH to read the router config"
    out = subprocess.run([YQ, "-o=json", ".model_list", str(ROOT / "config/litellm-proxy.yaml")], capture_output=True, text=True, check=True).stdout
    return [row["litellm_params"] for row in json.loads(out)]


def _plans():
    return json.loads((ROOT / "config/paid-plans.json").read_text())


def _bases(rows, prepaid_only=False):
    return [r.get("api_base", "") for r in rows if not prepaid_only or "prepaid" in (r.get("tags") or [])]


def test_every_live_paid_plan_keeps_a_router_row():
    bases = _bases(_router_rows())
    gone = [p["name"] for p in _plans() if not p.get("rows_pending") and not any(b.startswith(p["api_base"]) for b in bases)]
    assert not gone, f"paid plans with no router row: {gone}. Changing config/paid-plans.json needs Nish (CODEOWNERS)"


def test_every_prepaid_row_is_a_listed_plan():
    plans = [p["api_base"] for p in _plans()]
    unlisted = sorted({b for b in _bases(_router_rows(), prepaid_only=True) if not any(b.startswith(p) for p in plans)})
    assert not unlisted, f"prepaid rows not in config/paid-plans.json: {unlisted}. Changing config/paid-plans.json needs Nish (CODEOWNERS)"
