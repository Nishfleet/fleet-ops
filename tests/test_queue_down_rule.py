"""queue-down rules (fleet-ops#10204 part B): the real SQL, read out with yq and run in sqlite,
fires only when the newest finished agent-dispatch run (skipped and cancelled ignored) is a startup_failure."""
import json
import pathlib
import shutil
import sqlite3
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RULES = ROOT / "config/grafana/provisioning/alerting/queue-down.yaml"
YQ = shutil.which("yq")


def _rules():
    assert YQ, "yq must be on PATH to read the alert rules"
    out = subprocess.run([YQ, "-o=json", ".groups[].rules", str(RULES)], capture_output=True, text=True, check=True)
    return {r["uid"]: r for r in json.loads(out.stdout)}


def _down(rule, runs):
    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE A (id INTEGER, status TEXT, conclusion TEXT)")
    db.executemany("INSERT INTO A VALUES (?, 'completed', ?)", list(enumerate(runs, 1)))
    sql = next(d for d in rule["data"] if d["refId"] == "C")["model"]["expression"]
    rows = db.execute(sql).fetchall()
    return rows[0][0] if rows else None


@pytest.mark.parametrize("uid", sorted(_rules()))
def test_only_a_newest_startup_failure_fires(uid):
    rule = _rules()[uid]
    assert _down(rule, ["success", "startup_failure"]) == 1
    assert _down(rule, ["startup_failure", "success"]) == 0
    assert _down(rule, ["startup_failure", "skipped", "cancelled"]) == 1
    assert _down(rule, ["success", "failure"]) == 0
    assert _down(rule, []) is None


def test_two_rules_share_one_query_and_differ_in_wait_and_severity():
    rules = _rules()
    assert len(rules) == 2
    a, b = (rules["queue-down-fleet-ops"], rules["queue-down-2h-fleet-ops"])
    assert a["data"] == b["data"]
    assert (a["for"], a["labels"]["severity"]) == ("30m", "warning")
    assert (b["for"], b["labels"]["severity"]) == ("2h", "critical")
    for r in (a, b):
        assert r["labels"]["signal"] == "queue-down"
        assert (r["execErrState"], r["noDataState"]) == ("Error", "OK")
