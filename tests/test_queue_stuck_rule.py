"""queue-stuck rules (fleet-ops#10306): each rule's real SQL, read out with yq and run in
sqlite, counts only the hits whose updated_at is old enough, and the real query shapes
(Pull_Requests timeField 3, Issues timeField 2) are what the pinned plugin accepts."""
import json
import pathlib
import shutil
import sqlite3
import subprocess
from datetime import datetime, timedelta, timezone

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RULES = ROOT / "config/grafana/provisioning/alerting/queue-stuck.yaml"
YQ = shutil.which("yq")
NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
AGE = {"queue-stuck-pr-unmerged": 2, "queue-stuck-pr-blocked": 2, "queue-stuck-pr-needs-split": 2, "queue-stuck-issue-no-pr": 3}


def _rules():
    assert YQ, "yq must be on PATH to read the alert rules"
    out = subprocess.run([YQ, "-o=json", ".groups[].rules", str(RULES)], capture_output=True, text=True, check=True)
    return {r["uid"]: r for r in json.loads(out.stdout)}


def _unix_timestamp(*value):
    when = datetime.strptime(value[0], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) if value else NOW
    return int(when.timestamp())


def _count(rule, hours_old_by_table):
    db = sqlite3.connect(":memory:")
    db.create_function("UNIX_TIMESTAMP", -1, _unix_timestamp)
    for table, hours in hours_old_by_table.items():
        db.execute(f"CREATE TABLE {table} (updated_at TEXT)")
        db.executemany(f"INSERT INTO {table} VALUES (?)", [((NOW - timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ"),) for h in hours])
    sql = next(d for d in rule["data"] if d["refId"] == "C")["model"]["expression"]
    (row,) = db.execute(sql).fetchall()
    return row[0]


@pytest.mark.parametrize("uid", sorted(AGE))
def test_a_hit_counts_only_from_its_age_and_every_query_table_is_read(uid):
    rule = _rules()[uid]
    tables = [d["refId"] for d in rule["data"] if d["refId"] != "C"]
    hours = AGE[uid]
    fresh = {t: [hours - 0.5] for t in tables}
    assert _count(rule, fresh) == 0
    for table in tables:
        old = {t: ([hours + 0.5, hours - 0.5] if t == table else []) for t in tables}
        assert _count(rule, old) == 1, f"{uid}: a stuck hit in {table} must fire"
    assert _count(rule, {t: [] for t in tables}) == 0


def test_queries_use_the_org_wide_search_and_the_timefield_of_their_own_type():
    for uid, rule in _rules().items():
        for d in (d for d in rule["data"] if d["refId"] != "C"):
            model = d["model"]
            kind, field = {"Pull_Requests": ("is:pr", 3), "Issues": ("is:issue", 2)}[model["queryType"]]
            assert d["datasourceUid"] == model["datasource"]["uid"] == "fleet-github"
            assert model["options"]["query"].startswith(f"org:Nishfleet {kind} is:open")
            assert model["options"]["timeField"] == field


def test_rules_are_warnings_on_their_own_signal_with_a_read_error_text():
    rules = _rules()
    assert len({r["uid"] for r in rules.values()}) == len(rules) == 4
    for r in rules.values():
        assert r["labels"] == {"severity": "warning", "signal": "queue-stuck"}
        assert (r["for"], r["execErrState"], r["noDataState"]) == ("0s", "Error", "OK")
        assert "cannot read GitHub" in r["annotations"]["summary"]
        assert "notification_settings" not in r
