"""sweep-stale rule (fleet-ops#9278 item 5): the real SQL, read out with yq and run in
sqlite, fires only when the newest finished agent-dispatch run is 3 hours old, and also
when the read window holds no finished run at all. A read that returns no frame at all is
NoData, which the rule treats as firing too, because a disabled workflow looks the same."""
import json
import pathlib
import shutil
import sqlite3
import subprocess
from datetime import datetime, timedelta, timezone

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RULES = ROOT / "config/grafana/provisioning/alerting/sweep-stale.yaml"
YQ = shutil.which("yq")
NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
AGE_HOURS = 3


def _rule():
    assert YQ, "yq must be on PATH to read the alert rules"
    out = subprocess.run([YQ, "-o=json", ".groups[].rules", str(RULES)], capture_output=True, text=True, check=True)
    (rule,) = json.loads(out.stdout)
    return rule


def _unix_timestamp(*value):
    when = datetime.strptime(value[0], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) if value else NOW
    return int(when.timestamp())


def _stale(rule, hours_old, status="completed"):
    db = sqlite3.connect(":memory:")
    db.create_function("UNIX_TIMESTAMP", -1, _unix_timestamp)
    db.execute("CREATE TABLE A (id INTEGER, created_at TEXT, status TEXT)")
    db.executemany(
        "INSERT INTO A VALUES (?, ?, ?)",
        [(i, (NOW - timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ"), status) for i, h in enumerate(hours_old, 1)],
    )
    sql = next(d for d in rule["data"] if d["refId"] == "C")["model"]["expression"]
    (row,) = db.execute(sql).fetchall()
    return row[0]


def test_fires_only_when_the_newest_finished_run_is_three_hours_old():
    rule = _rule()
    assert _stale(rule, [0.5]) == 0
    assert _stale(rule, [AGE_HOURS - 0.5]) == 0
    assert _stale(rule, [AGE_HOURS + 0.5]) == 1
    assert _stale(rule, [AGE_HOURS + 0.5, 0.5]) == 0
    assert _stale(rule, []) == 1


def test_a_run_that_has_not_finished_is_not_liveness():
    assert _stale(_rule(), [0.5], status="queued") == 1


def test_it_reads_agent_dispatch_runs_and_warns_without_paging():
    rule = _rule()
    (query,) = [d for d in rule["data"] if d["refId"] != "C"]
    assert query["datasourceUid"] == query["model"]["datasource"]["uid"] == "fleet-github"
    assert query["model"]["queryType"] == "Workflow_Runs"
    assert query["model"]["options"]["workflow"] == "agent-dispatch.yml"
    assert rule["labels"] == {"severity": "warning", "signal": "sweep-stale"}
    assert (rule["for"], rule["execErrState"], rule["noDataState"]) == ("30m", "Error", "Alerting")
    assert "cannot read GitHub" in rule["annotations"]["summary"]
