"""The blocked-stale rule (fleet-ops#11135): dependency-blocked agent-ready work the idle
rule drops (-is:blocked, or a mirror label) counted again, one frame per spelling, and an
issue enters the count only when its own updated_at is at least 48h old, the queue-stuck
way. The rule's real SQL, read out with yq and run in sqlite, counts every frame hit old
enough and nothing else."""

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


def _github_frames(rule):
    return [d for d in rule["data"] if d.get("datasourceUid") == "fleet-github"]


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


def test_one_frame_reads_the_builtin_blocked_filter_the_idle_rule_drops():
    (frame,) = [d for d in _github_frames(_rule(UID)) if d["refId"] == "A"]
    query = frame["model"]["options"]["query"]
    assert frame["model"]["queryType"] == "Issues"
    assert frame["model"]["options"]["timeField"] == 2
    tokens = query.split()
    assert "is:blocked" in tokens
    assert "-is:blocked" not in tokens
    assert "label:agent-ready" in tokens
    assert "archived:false" in tokens
    assert 'NOT "grafana alert:" in:title' in query


def test_the_other_frame_reads_both_mirror_labels_in_one_comma_token():
    (frame,) = [d for d in _github_frames(_rule(UID)) if d["refId"] == "B"]
    query = frame["model"]["options"]["query"]
    assert frame["model"]["queryType"] == "Issues"
    assert frame["model"]["options"]["timeField"] == 2
    tokens = query.split()
    assert "label:agent-blocked-dep,dependency-blocked" in tokens
    assert "label:agent-ready" in tokens
    assert "archived:false" in tokens


def test_the_blocked_frames_mirror_the_idle_rules_exclusion():
    idle = _rule("scorecard-idle-runners")
    (idle_query,) = [
        d["model"]["options"]["query"]
        for d in _github_frames(idle)
        if d["model"].get("queryType") == "Issues"
    ]
    assert "-is:blocked" in idle_query.split()
    stale = {d["refId"]: d["model"]["options"]["query"] for d in _github_frames(_rule(UID))}
    assert "is:blocked" in stale["A"].split() and "-is:blocked" not in stale["A"].split()
    assert "label:agent-blocked-dep,dependency-blocked" in stale["B"].split()


def test_the_annotation_lists_carry_the_same_two_frames():
    links = re.findall(r"https://github\.com/search\?type=issues&q=[^\s]+", _rule(UID)["annotations"]["description"])
    assert len(links) == 2
    (builtin,) = [link for link in links if "is%3Ablocked" in link]
    (labels,) = [link for link in links if "label%3Aagent-blocked-dep%2Cdependency-blocked" in link]
    for link in (builtin, labels):
        assert "label%3Aagent-ready" in link
        assert "archived%3Afalse" in link


@pytest.mark.parametrize(
    "hours_old_by_table, want",
    [
        ({"A": [49], "B": [1]}, 1),
        ({"A": [1], "B": [49]}, 1),
        ({"A": [1], "B": [1]}, 0),
        ({"A": [], "B": []}, 0),
        ({"A": [49], "B": [49]}, 2),
    ],
)
def test_a_hit_counts_only_from_its_own_age_and_an_empty_frame_counts_zero(hours_old_by_table, want):
    assert _count(hours_old_by_table) == want


def test_the_expression_reads_only_the_query_frames():
    sql = next(d for d in _rule(UID)["data"] if d["refId"] == "C")["model"]["expression"]
    assert "GROUP BY" not in sql
    assert set(re.findall(r"\bFROM ([A-Z]+)\b", sql)) == {"A", "B"}
