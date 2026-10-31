"""The blocked-stale rule (fleet-ops#11135): dependency-blocked agent-ready work the idle
rule drops (a mirror label, written by the sweep from the same blocked_by gate the queue
admission reads) counted again, both mirror spellings in one comma token, and an issue
enters the count only when its own updated_at is at least 48h old, the queue-stuck way.
The rule's real SQL, read out with yq and run in sqlite, counts every hit old enough and
nothing else."""

import json
import pathlib
import re
import sqlite3
import subprocess
from datetime import datetime, timedelta, timezone

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RULES = ROOT / "config/grafana/provisioning/alerting/fleet-scorecard.yaml"
UID = "scorecard-blocked-stale"
NOW = datetime(2026, 11, 1, 12, 0, tzinfo=timezone.utc)


def _rule(uid):
    out = subprocess.run(
        ["yq", "-o=json", f'[.groups[].rules[] | select(.uid == "{uid}")]', str(RULES)],
        capture_output=True,
        text=True,
        check=True,
    )
    (rule,) = json.loads(out.stdout)
    return rule


def _query(rule):
    (frame,) = [d for d in rule["data"] if d.get("datasourceUid") == "fleet-github"]
    return frame["model"]["options"]["query"]


def _count(hours_old_by_table):
    rule = _rule(UID)
    sql = next(d for d in rule["data"] if d["refId"] == rule["condition"])["model"]["expression"]

    def unix_timestamp(value=None):
        if value is None:
            return int(NOW.timestamp())
        return int(datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())

    db = sqlite3.connect(":memory:")
    db.create_function("UNIX_TIMESTAMP", -1, unix_timestamp)
    for table, hours in hours_old_by_table.items():
        db.execute(f"CREATE TABLE {table} (updated_at TEXT)")
        rows = [((NOW - timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ"),) for h in hours]
        db.executemany(f"INSERT INTO {table} VALUES (?)", rows)
    (row,) = db.execute(sql).fetchall()
    return row[0]


def test_the_rule_counts_with_no_pending_gate_like_the_queue_stuck_rules():
    rule = _rule(UID)
    assert rule["title"] == "Dependency-blocked ready work with no update for 48h"
    assert rule["condition"] == "C"
    assert rule["for"] == "0s"
    assert rule["noDataState"] == "OK"
    assert rule["execErrState"] == "Error"
    assert rule["labels"] == {"severity": "warning", "signal": "fleet-scorecard"}


def test_the_query_counts_both_mirror_spellings_over_the_ready_set():
    rule = _rule(UID)
    (frame,) = [d for d in rule["data"] if d.get("datasourceUid") == "fleet-github"]
    assert frame["model"]["queryType"] == "Issues"
    assert frame["model"]["options"]["timeField"] == 2
    tokens = _query(rule).split()
    assert "label:agent-ready" in tokens
    assert "label:agent-blocked-dep,dependency-blocked" in tokens
    assert "archived:false" in tokens
    assert 'NOT "grafana alert:" in:title' in _query(rule)


def test_the_rule_does_not_build_on_the_unrecognized_is_blocked_token():
    query = _query(_rule(UID))
    for token in query.split():
        assert "is:blocked" not in token
    assert query.count("blocked") >= 1


def test_the_idle_rules_blocked_exclusions_and_this_rule_hold_the_two_sides():
    idle = _rule("scorecard-idle-runners")
    (idle_query,) = [
        d["model"]["options"]["query"]
        for d in idle["data"]
        if d.get("datasourceUid") == "fleet-github" and d["model"].get("queryType") == "Issues"
    ]
    idle_tokens = idle_query.split()
    assert "-is:blocked" in idle_tokens
    assert "-label:agent-blocked" in idle_tokens
    stale_tokens = _query(_rule(UID)).split()
    assert "label:agent-blocked-dep,dependency-blocked" in stale_tokens
    assert "is:blocked" not in " ".join(stale_tokens)


def test_the_annotation_list_carries_the_same_counted_set():
    links = re.findall(r"https://github\.com/search\?type=issues&q=[^\s]+", _rule(UID)["annotations"]["description"])
    assert len(links) == 1
    (link,) = links
    assert "label%3Aagent-ready" in link
    assert "label%3Aagent-blocked-dep%2Cdependency-blocked" in link
    assert "archived%3Afalse" in link


def test_the_read_window_holds_the_documented_30_day_gap():
    rule = _rule(UID)
    (frame,) = [d for d in rule["data"] if d.get("datasourceUid") == "fleet-github"]
    assert frame["relativeTimeRange"]["from"] == 2592000


@pytest.mark.parametrize(
    "hours, want",
    [
        (0.5, 0),
        (48, 1),
        (49, 1),
    ],
)
def test_a_hit_counts_only_from_its_own_age_and_an_empty_frame_counts_zero(hours, want):
    assert _count({"A": [hours]}) == want
    assert _count({"A": []}) == 0


def test_the_expression_reads_only_the_query_frame():
    rule = _rule(UID)
    sql = next(d for d in rule["data"] if d["refId"] == "C")["model"]["expression"]
    assert "GROUP BY" not in sql
    assert set(re.findall(r"\bFROM ([A-Z]+)\b", sql)) == {"A"}
    assert "172800" in sql
