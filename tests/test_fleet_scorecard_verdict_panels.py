"""Fleet scorecard verdict panels (fleet-ops#10887): each panel reads the merged fleet-ops pull requests
and their reviews, and its expression turns them into one row per merged day: the minutes from the
newest head the export can date to the APPROVED verdict that merged the PR, and the minutes from that
verdict to the merge. A PR with no approving review is absent, a verdict after the merge does not
count, the median and the p90 are the day's own numbers, and no wait is negative."""
import json
import pathlib
import re
import sqlite3
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[1]
DASHBOARD = ROOT / "config/grafana/dashboards/fleet-scorecard.json"
PR_QUERY = "is:merged repo:Nishfleet/fleet-ops"
REVIEW_QUERY = "is:merged repo:Nishfleet/fleet-ops"
HEAD_TITLE = "Head to review verdict"
MERGE_TITLE = "Approval to merge"
ALLOWED = {
    "UNIX_TIMESTAMP",
    "FROM_UNIXTIME",
    "DATE_FORMAT",
    "MIN",
    "MAX",
    "AVG",
    "COUNT",
    "ROUND",
    "CEIL",
    "ROW_NUMBER",
}
CLAUSE_KEYWORDS = {"AS", "OVER"}


def _at(day, hour, minute=0):
    return int(datetime(2026, 10, day, hour, minute, tzinfo=timezone.utc).timestamp()) * 1000


def _panel(title):
    return next(p for p in json.loads(DASHBOARD.read_text())["panels"] if p["title"].startswith(title))


def _expression(title):
    return next(t for t in _panel(title)["targets"] if t["refId"] == "C")["expression"]


PRS = [
    (1, _at(29, 9), _at(29, 9, 20)),
    (2, _at(29, 9), _at(29, 9, 50)),
    (3, _at(29, 9), _at(29, 10, 0)),
    (4, _at(29, 9), _at(29, 11, 0)),
    (5, _at(29, 9), _at(29, 11, 30)),
    (6, _at(29, 8), _at(29, 12, 0)),
    (7, _at(28, 10), _at(28, 10, 10)),
    (8, _at(28, 10), _at(28, 10, 30)),
]
REVIEWS = [
    (1, "APPROVED", _at(29, 9, 12), _at(29, 9, 12)),
    (2, "APPROVED", _at(29, 9, 5), _at(29, 9, 5)),
    (2, "DISMISSED", _at(29, 9, 5), _at(29, 9, 30)),
    (2, "APPROVED", _at(29, 9, 42), _at(29, 9, 42)),
    (3, "APPROVED", _at(29, 9, 50), _at(29, 9, 50)),
    (3, "APPROVED", _at(29, 10, 40), _at(29, 10, 40)),
    (5, "DISMISSED", _at(29, 9, 4), _at(29, 10, 45)),
    (6, "APPROVED", _at(29, 11, 58), _at(29, 11, 58)),
    (6, "DISMISSED", _at(29, 11, 58), _at(29, 11, 59)),
    (7, "APPROVED", _at(28, 10, 5), _at(28, 10, 5)),
    (8, "APPROVED", _at(28, 10, 20), _at(28, 10, 20)),
]
HEAD_EXPECTED = {
    "2026-10-29": (4, 31.0, 238.0),
    "2026-10-28": (2, 12.5, 20.0),
}
MERGE_EXPECTED = {
    "2026-10-29": (4, 8.0, 10.0),
    "2026-10-28": (2, 7.5, 10.0),
}


def _rows(title):
    db = sqlite3.connect(":memory:")
    db.create_function("UNIX_TIMESTAMP", 1, lambda ms: None if ms is None else ms // 1000)
    db.create_function("FROM_UNIXTIME", 1, lambda s: datetime.fromtimestamp(s, timezone.utc).strftime("%Y-%m-%d"))
    db.create_function("DATE_FORMAT", 2, lambda value, _: value)
    db.execute("CREATE TABLE A (number INTEGER, created_at INTEGER, merged_at INTEGER)")
    db.execute(
        "CREATE TABLE B (pull_request_number INTEGER, review_state TEXT, review_created_at INTEGER, review_updated_at INTEGER)"
    )
    db.executemany("INSERT INTO A VALUES (?, ?, ?)", PRS)
    db.executemany("INSERT INTO B VALUES (?, ?, ?, ?)", REVIEWS)
    return {row[0]: (row[1], row[2], row[3]) for row in db.execute(_expression(title))}


def test_scorecard_panels_read_the_merged_pull_requests_and_their_reviews():
    for title in (HEAD_TITLE, MERGE_TITLE):
        panel = _panel(title)
        targets = {t["refId"]: t for t in panel["targets"]}
        assert panel["type"] == "table"
        assert panel["timeFrom"] == "14d"
        assert panel["hideTimeOverride"] is True
        assert targets["A"]["datasource"]["uid"] == "fleet-github"
        assert targets["A"]["queryType"] == "Pull_Requests"
        assert targets["A"]["options"] == {"query": PR_QUERY, "timeField": 2}
        assert targets["A"]["repository"] == "fleet-ops"
        assert targets["B"]["queryType"] == "Pull_Request_Reviews"
        assert targets["B"]["options"] == {"query": REVIEW_QUERY}
        assert targets["A"]["hide"] is True and targets["B"]["hide"] is True
        assert targets["C"]["type"] == "sql"


def test_expressions_call_only_functions_the_engine_allows():
    for title in (HEAD_TITLE, MERGE_TITLE):
        expression = _expression(title)
        calls = set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(", expression)) - CLAUSE_KEYWORDS
        assert calls <= ALLOWED, f"{title} calls {calls - ALLOWED}"
        assert "FROM A AS a JOIN B AS b ON b.pull_request_number = a.number" in expression
        assert "b.review_state = 'APPROVED' AND UNIX_TIMESTAMP(b.review_created_at) <= UNIX_TIMESTAMP(a.merged_at)" in expression
        assert "DATE_FORMAT(FROM_UNIXTIME(merged_at), '%Y-%m-%d')" in expression


def test_head_to_verdict_counts_the_push_that_dismissed_the_previous_approval():
    assert _rows(HEAD_TITLE) == HEAD_EXPECTED


def test_approval_to_merge_counts_the_verdict_that_armed_the_merge():
    assert _rows(MERGE_TITLE) == MERGE_EXPECTED


def test_a_pull_request_without_an_approving_review_is_absent():
    for title, expected in ((HEAD_TITLE, HEAD_EXPECTED), (MERGE_TITLE, MERGE_EXPECTED)):
        rows = _rows(title)
        assert set(rows) == set(expected)
        assert rows["2026-10-29"][0] == 4


def test_a_dismissal_after_the_verdict_cannot_make_the_wait_negative():
    assert _rows(HEAD_TITLE)["2026-10-29"][2] == 238.0
