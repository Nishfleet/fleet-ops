"""Agent runs red for 6h (fleet-ops#10886): the rule's real SQL, read out with yq and run in
sqlite, fires only when runs failed for 6 hours with no success among them, and only over the
agent workflow of fleet-ops."""
import json
import pathlib
import shutil
import sqlite3
import subprocess
from datetime import datetime, timedelta, timezone

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RULES = ROOT / "config/grafana/provisioning/alerting/runner-jail-probe.yaml"
NOW = datetime(2026, 10, 28, 12, 0, tzinfo=timezone.utc)
FMT = "%Y-%m-%dT%H:%M:%SZ"
UID = "agent-runs-red-6h"
COLUMNS = "created_at TEXT, conclusion TEXT"
WINDOW = 43200  # the A query's relativeTimeRange: the GitHub plugin returns no run older than this


def _rule():
    out = subprocess.run(
        [shutil.which("yq"), "-o=json", f'[.groups[].rules[] | select(.uid == "{UID}")]', str(RULES)], capture_output=True, text=True, check=True
    )
    rules = json.loads(out.stdout)
    assert len(rules) == 1, f"{RULES.name} has {len(rules)} rules with uid {UID}, want 1"
    return rules[0]


def _query_options():
    options = next(d for d in _rule()["data"] if d["refId"] == "A")["model"]["options"]
    assert (options["owner"], options["repository"], options["workflow"]) == ("Nishfleet", "fleet-ops", "agent.yml")
    return options


def _unix_timestamp(*value):
    when = datetime.strptime(value[0], FMT).replace(tzinfo=timezone.utc) if value else NOW
    return int(when.timestamp())


def _stale(rows):
    """The rule's C expression over these runs, the way Grafana evaluates it: the query
    returns only the runs inside its 12h window, so a row older than that is dropped here."""
    rows = [(h, c) for h, c in rows if h * 3600 < WINDOW]
    db = sqlite3.connect(":memory:")
    db.create_function("UNIX_TIMESTAMP", -1, _unix_timestamp)
    db.execute(f"CREATE TABLE A ({COLUMNS})")
    db.executemany("INSERT INTO A VALUES (?, ?)", [((NOW - timedelta(hours=h)).strftime(FMT), c) for h, c in rows])
    return db.execute(next(d for d in _rule()["data"] if d["refId"] == "C")["model"]["expression"]).fetchone()[0]


def _red(oldest, count):
    """`count` failed runs, the oldest of them `oldest` hours old."""
    return [(oldest - i, "failure") for i in range(count)]


@pytest.mark.parametrize("oldest", [6, 8, 11])
def test_a_streak_that_started_six_hours_ago_pages(oldest):
    assert _stale(_red(oldest, 5)) == 1


@pytest.mark.parametrize("oldest", [0, 1, 5])
def test_a_young_streak_does_not_page(oldest):
    assert _stale(_red(oldest, 5)) == 0


def test_one_success_inside_the_window_stops_the_page():
    assert _stale(_red(9, 5) + [(2, "success")]) == 0
    # A success older than the window is not in the query's answer, so it does not stop it.
    assert _stale(_red(9, 5) + [(20, "success")]) == 1


def test_two_failures_do_not_page():
    assert _stale(_red(9, 2)) == 0
    assert _stale(_red(9, 1)) == 0


def test_a_quiet_day_and_a_green_day_do_not_page():
    assert _stale([]) == 0
    assert _stale([(h, "success") for h in range(11)]) == 0
    assert _stale(_red(9, 4) + [(11, "success")]) == 0


def test_cancelled_and_skipped_runs_are_not_counted():
    assert _stale(_red(9, 4) + [(3, "cancelled")] * 20 + [(4, "skipped")] * 20) == 1
    assert _stale([(3, "cancelled")] * 20 + [(4, "skipped")] * 20) == 0


def test_a_failure_older_than_the_window_is_not_a_streak():
    assert _stale([(20, "failure")] + [(h, "success") for h in range(11)]) == 0


def test_the_rule_reads_the_agent_workflow_of_fleet_ops():
    assert _query_options() == {"owner": "Nishfleet", "repository": "fleet-ops", "workflow": "agent.yml"}


def test_the_rule_pages_and_names_what_to_read_first():
    rule = _rule()
    assert rule["labels"] == {"severity": "critical", "signal": "runner-jail-probe"}
    assert not rule.get("notification_settings")
    description = rule["annotations"]["description"]
    assert "runner-probe" in description
    assert "stale jail" in description
    assert "{{ if $values }}" in description and "{{ else }}" in description
