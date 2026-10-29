"""Fleet scorecard idle panel (fleet-ops#10845): the panel reads the three frames it needs, and its
expression turns runner-minutes minus run durations into a per-day idle count that is zero when no
ready issue waits, never negative, and counts today and any run still in flight only up to now."""
import json
import pathlib
import re
import sqlite3
from datetime import datetime, timezone

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DASHBOARD = ROOT / "config/grafana/dashboards/fleet-scorecard.json"
TITLE = "Idle agent-runner minutes"
ISSUES_QUERY = (
    "org:Nishfleet is:issue label:agent-ready -label:agent-blocked -label:needs-orchestrator -label:needs-nish-decision"
)
ALLOWED = {
    "UNIX_TIMESTAMP",
    "FROM_UNIXTIME",
    "DATE_FORMAT",
    "FLOOR",
    "ROUND",
    "COALESCE",
    "SUM",
    "COUNT",
    "AVG",
    "FROM",
    "AS",
    "THEN",
}
NOW = datetime(2026, 10, 29, 6, 0, tzinfo=timezone.utc)


def _at(day, hour, minute=0):
    return int(datetime(2026, 10, day, hour, minute, tzinfo=timezone.utc).timestamp()) * 1000


def _panel():
    return next(p for p in json.loads(DASHBOARD.read_text())["panels"] if p["title"].startswith(TITLE))


def _expression():
    return next(t for t in _panel()["targets"] if t["refId"] == "C")["expression"]


RUNS = [
    (_at(29, 5), _at(29, 5), _at(29, 6), "completed"),
    (_at(29, 5, 30), _at(29, 5, 30), _at(29, 5, 30), "in_progress"),
    (_at(29, 3), None, _at(29, 6), "queued"),
    (_at(28, 4), _at(28, 4), _at(28, 5, 30), "completed"),
    (_at(28, 10), _at(28, 10), _at(28, 10, 30), "completed"),
    (_at(26, 1), _at(26, 1), _at(26, 1) + 3000 * 60 * 1000, "completed"),
]
ISSUES = [(_at(28, 12), None), (_at(26, 12), _at(27, 12))]
POOL = [(_at(29, 0), 28), (_at(28, 12), 28), (_at(26, 12), 2)]
EXPECTED = {
    "2026-10-29": (1, 9990),
    "2026-10-28": (1, 40200),
    "2026-10-27": (1, 27840),
    "2026-10-25": (0, 0),
}


def _idle():
    db = sqlite3.connect(":memory:")
    db.create_function("UNIX_TIMESTAMP", 0, lambda: int(NOW.timestamp()))
    db.create_function("UNIX_TIMESTAMP", 1, lambda ms: None if ms is None else ms // 1000)
    db.create_function("FROM_UNIXTIME", 1, lambda s: datetime.fromtimestamp(s, timezone.utc).strftime("%Y-%m-%d"))
    db.create_function("DATE_FORMAT", 2, lambda value, _: value)
    db.execute("CREATE TABLE A (created_at INTEGER, run_started_at INTEGER, updated_at INTEGER, status TEXT)")
    db.execute("CREATE TABLE B (created_at INTEGER, closed_at INTEGER)")
    db.execute("CREATE TABLE P (time INTEGER, __value__ REAL)")
    db.executemany("INSERT INTO A VALUES (?, ?, ?, ?)", RUNS)
    db.executemany("INSERT INTO B VALUES (?, ?)", ISSUES)
    db.executemany("INSERT INTO P VALUES (?, ?)", POOL)
    return {row[0]: (row[1], row[2]) for row in db.execute(_expression())}


def test_panel_reads_each_source_and_keeps_it_out_of_the_result():
    panel = _panel()
    targets = {t["refId"]: t for t in panel["targets"]}
    assert panel["type"] == "table"
    assert panel["timeFrom"] == "30d"
    assert panel["hideTimeOverride"] is True
    assert targets["A"]["datasource"]["uid"] == "fleet-github"
    assert targets["A"]["queryType"] == "Workflow_Runs"
    assert targets["A"]["options"] == {"owner": "Nishfleet", "repository": "fleet-ops", "workflow": "agent.yml"}
    assert targets["B"]["queryType"] == "Issues"
    assert targets["B"]["options"]["query"] == ISSUES_QUERY
    assert targets["B"]["options"]["timeField"] == 2
    assert targets["P"]["datasource"] == {"type": "prometheus", "uid": "fleet-prometheus"}
    assert all(targets[ref]["hide"] is True for ref in "ABP")
    assert targets["C"]["type"] == "sql"


def test_expression_calls_only_functions_the_engine_allows():
    expression = _expression()
    assert set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(", expression)) <= ALLOWED
    assert "FROM A" in expression and "B.created_at" in expression and "FROM P" in expression
    assert "__value__" in expression
    assert "DATE_FORMAT(FROM_UNIXTIME(d.day_start), '%Y-%m-%d')" in expression
    assert len(_idle()) == 14


def test_a_run_longer_than_its_day_clamps_to_zero_instead_of_going_negative():
    assert _idle()["2026-10-26"] == (1, 0)


@pytest.mark.parametrize("day,expected", sorted(EXPECTED.items()))
def test_idle_minutes_per_day(day, expected):
    assert _idle()[day] == expected
