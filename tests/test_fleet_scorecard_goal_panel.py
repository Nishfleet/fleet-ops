"""Fleet scorecard goal-box panel (fleet-ops#11168): one row per #10935 goal box, each row naming the
stock source it reads and the goal's target, with the seven-day rows bounded in SQL, the board rows
read from one org-wide open-issues frame, the streak row reading the two nightly units' failed state,
and the workflow-YAML row waiting for the nightly gauge instead of inventing a zero."""
import json
import pathlib
import re
import sqlite3
from datetime import datetime, timedelta, timezone

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DASHBOARD = ROOT / "config/grafana/dashboards/fleet-scorecard.json"
TITLE = "Goal boxes of #10935"
ALLOWED = {
    "UNIX_TIMESTAMP",
    "FLOOR",
    "ROUND",
    "COALESCE",
    "IF",
    "COUNT",
    "SUM",
    "MAX",
    "FROM",
    "IN",
}
NOW = datetime(2026, 10, 29, 6, 0, tzinfo=timezone.utc)


def _at(days_ago, hours_ago=0):
    return int((NOW - timedelta(days=days_ago, hours=hours_ago)).timestamp()) * 1000


def _panel():
    return next(p for p in json.loads(DASHBOARD.read_text())["panels"] if p["title"].startswith(TITLE))


def _targets():
    return {t["refId"]: t for t in _panel()["targets"]}


def _expression():
    return _targets()["L"]["expression"]


def _rows(
    issues=(),
    ended=(),
    orch_prs=(),
    tried=(),
    merged=(),
    reviews=(),
    commits=(),
    units=(),
    nightly=(),
    yaml_lines=(),
):
    db = sqlite3.connect(":memory:")
    db.create_function("UNIX_TIMESTAMP", 0, lambda: int(NOW.timestamp()))
    db.create_function("UNIX_TIMESTAMP", 1, lambda ms: None if ms is None else ms // 1000)
    db.create_function("IF", 3, lambda cond, a, b: a if cond else b)
    db.execute("CREATE TABLE A (labels TEXT, assignees TEXT, updated_at INTEGER)")
    db.execute("CREATE TABLE B (updated_at INTEGER)")
    db.execute("CREATE TABLE C (created_at INTEGER)")
    db.execute("CREATE TABLE D (updated_at INTEGER)")
    db.execute("CREATE TABLE E (number INTEGER, merged_at INTEGER)")
    db.execute("CREATE TABLE F (pull_request_number INTEGER, review_state TEXT, review_author_login TEXT)")
    db.execute("CREATE TABLE G (committed_at INTEGER)")
    db.execute("CREATE TABLE I (time INTEGER, __value__ REAL)")
    db.execute("CREATE TABLE J (__value__ REAL)")
    db.execute("CREATE TABLE K (__value__ REAL)")
    db.executemany("INSERT INTO A VALUES (?, ?, ?)", issues)
    for table, rows in (("B", ended), ("C", orch_prs), ("D", tried), ("G", commits), ("J", nightly), ("K", yaml_lines)):
        db.executemany(f"INSERT INTO {table} VALUES (?)", [(v,) if not isinstance(v, tuple) else v for v in rows])
    db.executemany("INSERT INTO E VALUES (?, ?)", merged)
    db.executemany("INSERT INTO F VALUES (?, ?, ?)", reviews)
    db.executemany("INSERT INTO I VALUES (?, ?)", units)
    return {(r[1], r[2]): r[3] for r in db.execute(_expression())}


READY = ('["agent-ready"]', "[]", _at(2))
ORCHESTRATOR = ('["needs-orchestrator","agent-blocked"]', '["nish3451"]', _at(20))
NISH = ('["needs-nish-decision"]', "[]", _at(20))
ENDED_OK = ('["handoff-ended"]', "[]", _at(2))
BUG_OWNED = ('["bug"]', '["someone"]', _at(30))


def test_panel_reads_each_source_and_hides_it():
    panel, targets = _panel(), _targets()
    assert panel["type"] == "table"
    assert panel["timeFrom"] == "60d"
    assert panel["hideTimeOverride"] is True
    for ref in "ABCDEFGIJK":
        assert targets[ref]["hide"] is True
    assert targets["A"]["datasource"]["uid"] == "fleet-github"
    assert targets["A"]["queryType"] == "Issues"
    assert targets["A"]["repository"] == ""
    assert targets["A"]["options"] == {
        "query": "org:Nishfleet is:issue is:open archived:false",
        "timeField": 2,
    }
    assert targets["G"]["queryType"] == "Commits"
    assert targets["G"]["options"] == {"gitRef": "main", "includeFiles": False}
    assert targets["I"]["datasource"] == {"type": "prometheus", "uid": "fleet-prometheus"}
    assert targets["L"]["type"] == "sql"
    hidden = [
        o["matcher"]["options"]
        for o in panel["fieldConfig"]["overrides"]
        if any(p["id"] == "custom.hidden" and p["value"] for p in o["properties"])
    ]
    assert hidden == ["ord"]


def test_the_rate_row_reads_the_same_frames_as_the_handoff_panel():
    rate_panel = next(
        p for p in json.loads(DASHBOARD.read_text())["panels"] if p["id"] == 7
    )
    rate_targets = {t["refId"]: t for t in rate_panel["targets"]}
    targets = _targets()
    for mine, theirs in (("B", "A"), ("C", "B")):
        assert targets[mine]["queryType"] == rate_targets[theirs]["queryType"]
        assert targets[mine]["options"] == rate_targets[theirs]["options"]
    assert targets["F"]["options"]["query"] == "is:merged repo:Nishfleet/fleet-ops"


def test_expression_calls_only_functions_the_engine_allows():
    expression = _expression()
    assert set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(", expression)) <= ALLOWED
    assert "FROM A" in expression and "FROM J" in expression and "FROM K" in expression
    assert "JOIN E" in expression and "ORDER BY ord" in expression
    assert "UNIX_TIMESTAMP() - 604800" in expression
    assert "IF(c.n + e.n = 0, NULL, ROUND(" in expression


def test_rows_come_in_goal_box_order():
    rows = _rows(
        issues=[READY, ORCHESTRATOR, NISH, ENDED_OK, BUG_OWNED],
        ended=[_at(2), _at(2), _at(9)],
        orch_prs=[_at(1), _at(3), _at(12)],
        tried=[_at(1), _at(10)],
        merged=[(1, _at(2)), (2, _at(9)), (3, _at(2))],
        reviews=[(1, "APPROVED", "untrusted-dev"), (1, "APPROVED", "github-actions[bot]"), (2, "APPROVED", "untrusted-dev"), (3, "APPROVED", "nish3451"), (3, "CHANGES_REQUESTED", "untrusted-dev")],
        commits=[_at(2), _at(10)],
        units=[(_at(1, 6), 1.0), (_at(0, 20), 0.0), (_at(0, 1), 0.0)],
        nightly=[(2.0,)],
        yaml_lines=[(4490.0,)],
    )
    assert [key[0] for key in rows] == [
        "1. Preview before apply",
        "2. No home-made plumbing",
        "3. Approvals cannot be forged",
        "5. Only the owner decides",
        "6. Small work, high success",
        "6. Small work, high success",
        "9. Clean board",
        "9. Clean board",
        "9. Clean board",
        "10. Green nights",
        "10. Green nights",
    ]
    assert rows[("1. Preview before apply", "merges undone by a revert, 7d")] == 1
    assert rows[("2. No home-made plumbing", "workflow YAML lines")] == 4490
    assert rows[("3. Approvals cannot be forged", "approving reviews from outside the reviewer App or the owner, 7d")] == 1
    assert rows[("5. Only the owner decides", "open needs-nish-decision issues")] == 1
    assert rows[("6. Small work, high success", "hand-off to PR rate, 7d")] == 50.0
    assert rows[("6. Small work, high success", "hand-offs that hit the wall, 7d")] == 1
    assert rows[("9. Clean board", "work-state labels in use on open issues")] == 5
    assert rows[("9. Clean board", "open issues in the org")] == 5
    assert rows[("9. Clean board", "open issues stale over 14 days with no assignee")] == 1
    assert rows[("10. Green nights", "green nights in a row, update + host config")] == 1
    assert rows[("10. Green nights", "failed units on the box")] == 2


def test_a_revert_older_than_a_week_does_not_count():
    assert _rows(commits=[_at(10)])[
        ("1. Preview before apply", "merges undone by a revert, 7d")
    ] == 0


def test_only_an_approval_outside_the_two_trusted_logins_on_a_week_old_merge_counts():
    assert _rows(merged=[(1, _at(2))], reviews=[(1, "APPROVED", "github-actions[bot]"), (1, "APPROVED", "nish3451")])[
        ("3. Approvals cannot be forged", "approving reviews from outside the reviewer App or the owner, 7d")
    ] == 0
    assert _rows(merged=[(1, _at(8))], reviews=[(1, "APPROVED", "untrusted-dev")])[
        ("3. Approvals cannot be forged", "approving reviews from outside the reviewer App or the owner, 7d")
    ] == 0


def test_the_rate_row_stays_blank_when_nothing_handed_off():
    assert _rows(ended=[], orch_prs=[])["6. Small work, high success", "hand-off to PR rate, 7d"] is None


def test_the_rate_row_counts_a_side_with_no_handoffs_at_all():
    assert _rows(ended=[_at(2)], orch_prs=[])["6. Small work, high success", "hand-off to PR rate, 7d"] == 0.0


def test_a_fully_green_window_shows_the_window_cap_not_a_lie():
    assert _rows(units=[(_at(0, 1), 0.0)])[
        ("10. Green nights", "green nights in a row, update + host config")
    ] == 60


def test_a_unit_failing_right_now_shows_zero_nights():
    assert _rows(units=[(_at(0, 0), 1.0), (_at(0, 1), 1.0)])[
        ("10. Green nights", "green nights in a row, update + host config")
    ] == 0


def test_the_yaml_row_is_blank_until_the_first_nightly_write():
    assert _rows()[("2. No home-made plumbing", "workflow YAML lines")] is None


def test_the_board_rows_split_open_stale_and_owned():
    rows = _rows(issues=[READY, ORCHESTRATOR, NISH, ENDED_OK, BUG_OWNED])
    assert rows[("9. Clean board", "open issues in the org")] == 5
    assert rows[("9. Clean board", "open issues stale over 14 days with no assignee")] == 1
    assert rows[("9. Clean board", "work-state labels in use on open issues")] == 5


@pytest.mark.parametrize("label", ["agent-ready", "agent-blocked", "agent-in-progress", "agent-failed",
                                   "handoff-ended", "orchestrator-tried", "needs-orchestrator",
                                   "needs-coordinator", "needs-nish-decision", "needs-split", "on-hold",
                                   "review-retry", "provider-watch"])
def test_every_work_state_label_counts_toward_the_label_row(label):
    rows = _rows(issues=[(f'["{label}"]', "[]", _at(2))])
    assert rows[("9. Clean board", "work-state labels in use on open issues")] == 1
