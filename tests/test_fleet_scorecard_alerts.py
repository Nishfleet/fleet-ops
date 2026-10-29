"""The three Fleet scorecard alerts that read idle minutes and the two review clocks.

Each rule's SQL expression runs against tables shaped the way the GitHub and
Prometheus data sources shape them, so a rule that fires on one day and not on
two, or that reads a column the data source does not send, fails here instead of
in Grafana.
"""

import json
import sqlite3
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import pytest

RULE_FILE = Path(__file__).resolve().parent.parent / "config/grafana/provisioning/alerting/fleet-scorecard.yaml"
NOW = 1_800_000_000

SHAPES = {
    "A_runs": "CREATE TABLE A (run_started_at INTEGER, status TEXT, updated_at INTEGER)",
    "D_runs": "CREATE TABLE D (run_started_at INTEGER, status TEXT, updated_at INTEGER)",
    "B_issues": "CREATE TABLE B (created_at INTEGER, closed_at INTEGER)",
    "P_slots": "CREATE TABLE P (time INTEGER, __value__ INTEGER)",
    "A_pulls": "CREATE TABLE A (number INTEGER, created_at INTEGER, merged_at INTEGER)",
    "B_reviews": (
        "CREATE TABLE B (pull_request_number INTEGER, review_state TEXT, "
        "review_created_at INTEGER, review_updated_at INTEGER)"
    ),
}


def _rules():
    out = subprocess.run(
        ["yq", "-o=json", "[.groups[].rules[]]", str(RULE_FILE)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return {rule["uid"]: rule for rule in json.loads(out)}


def _expression(uid):
    rule = _rules()[uid]
    return next(t for t in rule["data"] if t["refId"] == rule["condition"])["model"]["expression"]


def _stamp(*args):
    if not args or args[0] is None:
        return NOW
    value = args[0]
    if isinstance(value, (int, float)):
        return int(value / 1000) if value > 10**11 else int(value)
    return int(datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp())


def _missed(uid, tables):
    db = sqlite3.connect(":memory:")
    db.create_function("UNIX_TIMESTAMP", -1, _stamp)
    for name, (shape, rows) in tables.items():
        db.execute(SHAPES[shape])
        if rows:
            db.executemany(
                f"INSERT INTO {name} VALUES ({','.join('?' * len(rows[0]))})",
                rows,
            )
    return db.execute(_expression(uid)).fetchone()[0]


def _hours_ago(hours):
    return (NOW - int(hours * 3600)) * 1000


def _pool(slots, hours=(6, 18, 30, 42)):
    return [(_hours_ago(h), slots) for h in hours]


def _runs(covered_hours):
    return [(_hours_ago(h), "completed", _hours_ago(h) + 60 * 60 * 1000) for h in covered_hours]


def _waiting_issue():
    return [(_hours_ago(40), None)]


def _pull(number, opened_hours, merged_hours):
    return (number, _hours_ago(opened_hours), _hours_ago(merged_hours))


def _review(number, approved_hours):
    return (number, "APPROVED", _hours_ago(approved_hours), _hours_ago(approved_hours))


@pytest.mark.parametrize(
    "tables,want",
    [
        pytest.param(
            {
                "P": ("P_slots", _pool(4)),
                "A": ("A_runs", []),
                "D": ("D_runs", []),
                "B": ("B_issues", _waiting_issue()),
            },
            1,
            id="idle-both-days",
        ),
        pytest.param(
            {
                "P": ("P_slots", _pool(1)),
                "A": ("A_runs", _runs(range(1, 25))),
                "D": ("D_runs", []),
                "B": ("B_issues", _waiting_issue()),
            },
            0,
            id="today-busy",
        ),
        pytest.param(
            {
                "P": ("P_slots", _pool(4)),
                "A": ("A_runs", []),
                "D": ("D_runs", []),
                "B": ("B_issues", []),
            },
            0,
            id="nothing-waits",
        ),
        pytest.param(
            {
                "P": ("P_slots", _pool(0)),
                "A": ("A_runs", []),
                "D": ("D_runs", []),
                "B": ("B_issues", _waiting_issue()),
            },
            0,
            id="no-runners",
        ),
    ],
)
def test_idle_rule_fires_only_when_both_days_are_idle_with_work_waiting(tables, want):
    assert _missed("scorecard-idle-runners", tables) == want


def _verdict_day(verdict_minutes, base_hours, first):
    pulls, reviews = [], []
    for offset in (0, 6, 12):
        merged = base_hours + offset
        pulls.append(_pull(first + offset, merged + 2, merged))
        reviews.append(_review(first + offset, merged + 2 - verdict_minutes / 60))
    return pulls, reviews


@pytest.mark.parametrize(
    "verdict_minutes,want",
    [
        pytest.param(30, 1, id="over-p50-target"),
        pytest.param(5, 0, id="under-p50-target"),
    ],
)
def test_verdict_rule_fires_when_both_days_miss_the_target(verdict_minutes, want):
    pulls, reviews = _verdict_day(verdict_minutes, 10, 100)
    older_pulls, older_reviews = _verdict_day(verdict_minutes, 34, 200)
    assert (
        _missed(
            "scorecard-verdict-slow",
            {
                "A": ("A_pulls", pulls + older_pulls),
                "B": ("B_reviews", reviews + older_reviews),
            },
        )
        == want
    )


def test_verdict_rule_stays_quiet_when_only_one_day_misses():
    pulls, reviews = _verdict_day(30, 10, 100)
    older_pulls, older_reviews = _verdict_day(5, 34, 200)
    assert (
        _missed(
            "scorecard-verdict-slow",
            {
                "A": ("A_pulls", pulls + older_pulls),
                "B": ("B_reviews", reviews + older_reviews),
            },
        )
        == 0
    )


def _approval_day(merge_minutes, base_hours, first):
    pulls, reviews = [], []
    for offset in (0, 6, 12):
        merged = base_hours + offset
        pulls.append(_pull(first + offset, merged + 3, merged))
        reviews.append(_review(first + offset, merged + merge_minutes / 60))
    return pulls, reviews


@pytest.mark.parametrize(
    "merge_minutes,want",
    [
        pytest.param(20, 1, id="over-target"),
        pytest.param(5, 0, id="under-target"),
    ],
)
def test_approval_rule_fires_when_both_days_miss_the_target(merge_minutes, want):
    pulls, reviews = _approval_day(merge_minutes, 10, 300)
    older_pulls, older_reviews = _approval_day(merge_minutes, 34, 400)
    assert (
        _missed(
            "scorecard-approval-slow",
            {
                "A": ("A_pulls", pulls + older_pulls),
                "B": ("B_reviews", reviews + older_reviews),
            },
        )
        == want
    )


def test_approval_rule_ignores_a_pull_request_with_no_approving_review():
    pulls, reviews = _approval_day(20, 10, 300)
    older_pulls, older_reviews = _approval_day(20, 34, 400)
    reviews = reviews[:1]
    older_reviews = []
    assert (
        _missed(
            "scorecard-approval-slow",
            {
                "A": ("A_pulls", pulls + older_pulls),
                "B": ("B_reviews", reviews + older_reviews),
            },
        )
        == 0
    )


@pytest.mark.parametrize(
    "uid",
    ["scorecard-idle-runners", "scorecard-verdict-slow", "scorecard-approval-slow"],
)
def test_every_new_rule_files_one_issue_through_the_catch_all(uid):
    rule = _rules()[uid]
    assert rule["labels"] == {"severity": "warning", "signal": "fleet-scorecard"}
    assert rule["noDataState"] == "OK"
    assert rule["execErrState"] == "Error"
    assert rule["for"] == "0s"
