"""Fleet scorecard hand-off to PR rate panel (fleet-ops#11167): the panel pairs
each day's orchestrate hand-off runs (the issues and workflow_dispatch events;
the daily sweep is a schedule event and stays out) with the PRs opened that day
from orch/ branches, and reports the same-day rate per hand-off."""
import json
import pathlib
import re
import sqlite3

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DASHBOARD = ROOT / "config/grafana/dashboards/fleet-scorecard.json"
TITLE = "Hand-off to PR rate"
PR_QUERY = "is:pr head:orch/ repo:Nishfleet/fleet-ops"
ALLOWED = {"ROUND", "COALESCE", "SUBSTRING", "COUNT", "IN", "FROM", "JOIN"}

RUNS = [
    ("2026-10-29T05:03:00Z", "issues"),
    ("2026-10-29T09:40:00Z", "issues"),
    ("2026-10-29T12:15:00Z", "workflow_dispatch"),
    ("2026-10-29T02:00:00Z", "schedule"),
    ("2026-10-28T11:58:00Z", "workflow_dispatch"),
    ("2026-10-28T02:00:00Z", "schedule"),
    ("2026-10-28T02:10:00Z", "schedule"),
    ("2026-10-26T05:03:00Z", "issues"),
    ("2026-10-26T07:00:00Z", "issues"),
    ("2026-10-26T09:00:00Z", "issues"),
    ("2026-10-26T12:00:00Z", "issues"),
    ("2026-10-26T15:00:00Z", "issues"),
]
PRS = [
    ("2026-10-29T13:24:29Z",),
    ("2026-10-28T13:00:00Z",),
]
EXPECTED = {
    "2026-10-29": (3, 1, 33.3),
    "2026-10-28": (1, 1, 100.0),
    "2026-10-26": (5, 0, 0.0),
}


def _panel():
    return next(p for p in json.loads(DASHBOARD.read_text())["panels"] if p["title"].startswith(TITLE))


def _expression():
    return next(t for t in _panel()["targets"] if t["refId"] == "C")["expression"]


def _rate():
    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE A (created_at TEXT, event TEXT)")
    db.execute("CREATE TABLE B (created_at TEXT)")
    db.executemany("INSERT INTO A VALUES (?, ?)", RUNS)
    db.executemany("INSERT INTO B VALUES (?)", PRS)
    return {row[0]: (row[1], row[2], row[3]) for row in db.execute(_expression())}


def test_panel_reads_one_run_frame_and_one_pr_frame():
    panel = _panel()
    targets = {t["refId"]: t for t in panel["targets"]}
    assert panel["type"] == "table"
    assert panel["timeFrom"] == "14d"
    assert panel["hideTimeOverride"] is True
    assert targets["A"]["queryType"] == "Workflow_Runs"
    assert targets["A"]["options"] == {"owner": "Nishfleet", "repository": "fleet-ops", "workflow": "agent-dispatch.yml"}
    assert targets["B"]["queryType"] == "Pull_Requests"
    assert targets["B"]["options"]["query"] == PR_QUERY
    assert targets["B"]["options"]["timeField"] == 1
    assert all(targets[ref]["hide"] is True for ref in "AB")
    assert targets["C"]["type"] == "sql"


def test_expression_calls_only_functions_the_engine_allows():
    expression = _expression()
    assert set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(", expression)) <= ALLOWED
    assert "FROM A" in expression and "FROM B" in expression
    assert "event IN ('issues', 'workflow_dispatch')" in expression


def test_the_sweep_stays_out_of_the_denominator():
    day = "2026-10-27"
    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE A (created_at TEXT, event TEXT)")
    db.execute("CREATE TABLE B (created_at TEXT)")
    db.executemany("INSERT INTO A VALUES (?, ?)", [(f"{day}T02:00:00Z", "schedule"), (f"{day}T02:10:00Z", "schedule")])
    assert db.execute(_expression()).fetchall() == []


@pytest.mark.parametrize("day,expected", sorted(EXPECTED.items()))
def test_hand_off_to_pr_rate_per_day(day, expected):
    assert _rate()[day] == expected
