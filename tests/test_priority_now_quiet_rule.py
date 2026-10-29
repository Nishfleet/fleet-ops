"""A quiet priority-now issue (fleet-ops#10716): the rule's real SQL, read out with yq and run in
sqlite, counts only issues whose last touch is 30 minutes old or older, and fires on a non-zero
count."""
import json
import pathlib
import shutil
import sqlite3
import subprocess
from datetime import datetime, timedelta, timezone

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RULES = ROOT / "config/grafana/provisioning/alerting/priority-now-quiet.yaml"
NOW = datetime(2026, 10, 28, 12, 0, tzinfo=timezone.utc)
FMT = "%Y-%m-%dT%H:%M:%SZ"


def _rule():
    out = subprocess.run([shutil.which("yq"), "-o=json", ".groups[].rules", str(RULES)], capture_output=True, text=True, check=True)
    rules = {r["uid"]: r for r in json.loads(out.stdout)}
    assert set(rules) == {"priority-now-quiet-30m"}
    return rules["priority-now-quiet-30m"]


def _unix_timestamp(*value):
    when = datetime.strptime(value[0], FMT).replace(tzinfo=timezone.utc) if value else NOW
    return int(when.timestamp())


def _quiet(touches):
    db = sqlite3.connect(":memory:")
    db.create_function("UNIX_TIMESTAMP", -1, _unix_timestamp)
    db.execute("CREATE TABLE A (updated_at TEXT, unused TEXT)")
    db.executemany("INSERT INTO A VALUES (?, ?)", [((NOW - timedelta(minutes=m)).strftime(FMT), None) for m in touches])
    sql = next(d for d in _rule()["data"] if d["refId"] == "C")["model"]["expression"]
    return db.execute(sql).fetchone()[0]


@pytest.mark.parametrize(
    "touches,quiet",
    [
        ((31,), 1),
        ((30,), 1),
        ((29,), 0),
        ((1, 45, 200), 2),
        ((), 0),
    ],
)
def test_counts_only_issues_older_than_30_minutes(touches, quiet):
    assert _quiet(touches) == quiet


def test_the_search_leaves_out_the_issues_another_lane_owns():
    query = next(d for d in _rule()["data"] if d["refId"] == "A")["model"]["options"]["query"]
    for needle in ("label:priority-now", "-label:agent-in-progress", "-label:needs-nish-decision", "-linked:pr", "is:open"):
        assert needle in query


def test_an_unreadable_search_raises_instead_of_going_green():
    rule = _rule()
    assert rule["noDataState"] == "OK"
    assert rule["execErrState"] == "Error"
    assert rule["labels"]["severity"] == "warning"
