"""The blocked-stale rule (fleet-ops#11135): dependency-blocked agent-ready work the idle
rule drops (-is:blocked, or a mirror label) counted again, one frame per spelling, and an
issue enters the count only when its own updated_at is at least 48h old, the queue-stuck
way. The rule's real SQL, read out with yq and run in sqlite, counts every frame hit old
enough and nothing else. The abandoned-blocker minder (fleet-ops#11358) reads the same
mirror-label search through a one-year window and takes the class over at 30 days of
silence, the age the 48h rule's read window ends at."""

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
MINDER = "scorecard-blocked-abandoned"
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


def _count(uid, hours_old_by_table):
    rule = _rule(uid)
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
    assert _count(UID, hours_old_by_table) == want


def test_the_expression_reads_only_the_query_frames():
    sql = next(d for d in _rule(UID)["data"] if d["refId"] == "C")["model"]["expression"]
    assert "GROUP BY" not in sql
    assert set(re.findall(r"\bFROM ([A-Z]+)\b", sql)) == {"A", "B"}


def test_the_minder_files_one_issue_with_the_same_shape_as_its_48h_sibling():
    rule = _rule(MINDER)
    assert rule["title"] == "Dependency-blocked ready work with no update for over 30 days"
    assert rule["condition"] == "B"
    assert rule["for"] == "0s"
    assert rule["noDataState"] == "OK"
    assert rule["execErrState"] == "Error"
    assert rule["labels"] == {"severity": "warning", "signal": "fleet-scorecard"}


def test_the_minder_reads_a_window_wider_than_the_48h_rules_30_day_read():
    (frame,) = _github_frames(_rule(MINDER))
    assert frame["relativeTimeRange"]["to"] == 0
    assert frame["relativeTimeRange"]["from"] > max(
        d["relativeTimeRange"]["from"] for d in _github_frames(_rule(UID))
    )


def test_the_minder_counts_the_same_label_search_the_48h_rule_reads():
    (frame,) = _github_frames(_rule(MINDER))
    (labels_frame,) = [d for d in _github_frames(_rule(UID)) if d["refId"] == "B"]
    assert frame["model"]["queryType"] == "Issues"
    assert frame["model"]["options"]["timeField"] == 2
    assert frame["model"]["options"]["query"] == labels_frame["model"]["options"]["query"]


def test_the_minder_does_not_lean_on_the_builtin_blocked_qualifier():
    (frame,) = _github_frames(_rule(MINDER))
    tokens = frame["model"]["options"]["query"].split()
    assert "is:blocked" not in tokens
    assert "-is:blocked" not in tokens


@pytest.mark.parametrize(
    "hours_old_by_table, want",
    [
        ({"A": [24 * 45]}, 1),
        ({"A": [24 * 31]}, 1),
        ({"A": [24 * 30]}, 1),
        ({"A": [24 * 29]}, 0),
        ({"A": [24 * 20]}, 0),
        ({"A": []}, 0),
    ],
)
def test_the_minder_takes_the_class_over_at_30_days_of_silence(hours_old_by_table, want):
    assert _count(MINDER, hours_old_by_table) == want


def test_the_minder_expression_reads_only_its_own_frame():
    sql = next(d for d in _rule(MINDER)["data"] if d["refId"] == "B")["model"]["expression"]
    assert "GROUP BY" not in sql
    assert set(re.findall(r"\bFROM ([A-Z]+)\b", sql)) == {"A"}


def test_the_minder_annotation_links_the_label_search():
    links = re.findall(r"https://github\.com/search\?type=issues&q=[^\s]+", _rule(MINDER)["annotations"]["description"])
    assert len(links) == 1
    (link,) = links
    assert "label%3Aagent-blocked-dep%2Cdependency-blocked" in link
    assert "label%3Aagent-ready" in link
    assert "archived%3Afalse" in link
