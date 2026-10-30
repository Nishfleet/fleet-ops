"""Fleet scorecard hand-off to PR rate panel (fleet-ops#11167): each day's PRs opened
from orch/ branches over those plus the hand-offs that ended with no PR (issues
labelled handoff-ended, bucketed by last update day)."""
import json
import pathlib
import re
import sqlite3

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DASHBOARD = ROOT / "config/grafana/dashboards/fleet-scorecard.json"
TITLE = "Hand-off to PR rate"
PR_QUERY = "is:pr head:orch/ repo:Nishfleet/fleet-ops"
ENDED_QUERY = "is:issue label:handoff-ended repo:Nishfleet/fleet-ops"
ALLOWED = {"ROUND", "COALESCE", "SUBSTRING", "COUNT", "FROM", "JOIN"}

ENDED = [("2026-10-29T09:00:00Z",), ("2026-10-29T10:00:00Z",), ("2026-10-28T09:00:00Z",), ("2026-10-26T09:00:00Z",)]
PRS = [
    ("2026-10-29T13:24:29Z",),
    ("2026-10-29T14:00:00Z",),
    ("2026-10-28T13:00:00Z",),
    ("2026-10-27T13:00:00Z",),
]
EXPECTED = {
    "2026-10-29": (4, 2, 50.0),
    "2026-10-28": (2, 1, 50.0),
    "2026-10-27": (1, 1, 100.0),
}


def _panel():
    return next(p for p in json.loads(DASHBOARD.read_text())["panels"] if p["title"].startswith(TITLE))


def _expression():
    return next(t for t in _panel()["targets"] if t["refId"] == "C")["expression"]


def _rate():
    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE A (updated_at TEXT)")
    db.execute("CREATE TABLE B (created_at TEXT)")
    db.executemany("INSERT INTO A VALUES (?)", ENDED)
    db.executemany("INSERT INTO B VALUES (?)", PRS)
    return {row[0]: (row[1], row[2], row[3]) for row in db.execute(_expression())}


def test_panel_reads_one_ended_frame_and_one_pr_frame():
    panel = _panel()
    targets = {t["refId"]: t for t in panel["targets"]}
    assert panel["type"] == "table"
    assert panel["timeFrom"] == "14d"
    assert panel["hideTimeOverride"] is True
    assert targets["A"]["queryType"] == "Issues"
    assert targets["A"]["options"] == {"query": ENDED_QUERY, "timeField": 1}
    assert targets["B"]["queryType"] == "Pull_Requests"
    assert targets["B"]["options"] == {"query": PR_QUERY, "timeField": 1}
    assert all(targets[ref]["hide"] is True for ref in "AB")
    assert targets["C"]["type"] == "sql"


def test_expression_calls_only_functions_the_engine_allows():
    expression = _expression()
    assert set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(", expression)) <= ALLOWED
    assert "FROM A" in expression and "FROM B" in expression


@pytest.mark.parametrize("day,expected", sorted(EXPECTED.items()))
def test_hand_off_to_pr_rate_per_day(day, expected):
    assert _rate()[day] == expected


def test_a_day_with_only_ended_hand_offs_has_no_row():
    assert "2026-10-26" not in _rate()
