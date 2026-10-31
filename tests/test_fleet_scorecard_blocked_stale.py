"""The blocked-stale rule (fleet-ops#11135): a dependency-blocked agent-ready issue whose
blocker is stuck leaves the idle rule's waiting count once a mirror label lands, so this
rule keeps counting it and its pending duration carries the block age. The rule's real SQL,
read out with yq and run in sqlite, counts every mirror-labelled issue and nothing else."""

import json
import pathlib
import re
import shutil
import sqlite3
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RULES = ROOT / "config/grafana/provisioning/alerting/fleet-scorecard.yaml"
UID = "scorecard-blocked-stale"


def _rules():
    out = subprocess.run(
        ["yq", "-o=json", "[.groups[].rules[] | select(.uid == \"scorecard-blocked-stale\")]", str(RULES)],
        capture_output=True,
        text=True,
        check=True,
    )
    (rule,) = json.loads(out.stdout)
    return rule


def test_the_rule_count_for_48h_through_the_catch_all():
    rule = _rules()
    assert rule["title"] == "Dependency-blocked ready work stuck behind its blocker for 48h"
    assert rule["condition"] == "C"
    assert rule["for"] == "48h"
    assert rule["noDataState"] == "OK"
    assert rule["execErrState"] == "Error"
    assert rule["labels"] == {"severity": "warning", "signal": "fleet-scorecard"}


def test_the_search_finds_blocked_ready_work_under_either_mirror_label():
    rule = _rules()
    (target,) = [d for d in rule["data"] if d.get("refId") == "A"]
    assert target["model"]["queryType"] == "Issues"
    assert target["model"]["options"]["timeField"] == 2
    query = target["model"]["options"]["query"].split()
    assert "label:agent-ready" in query
    assert "label:agent-blocked-dep,dependency-blocked" in query
    assert "archived:false" in query
    assert 'NOT "grafana alert:' in target["model"]["options"]["query"]


def test_the_annotation_search_names_the_same_blocked_set():
    rule = _rules()
    assert "label%3Aagent-ready" in rule["annotations"]["description"]
    assert "label%3Aagent-blocked-dep%2Cdependency-blocked" in rule["annotations"]["description"]
    assert "archived%3Afalse" in rule["annotations"]["description"]


def test_the_count_reads_every_mirror_hit_and_stays_empty_when_none_match():
    sql = next(d for d in _rules()["data"] if d["refId"] == "C")["model"]["expression"]
    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE A (updated_at TEXT)")
    db.executemany("INSERT INTO A VALUES (?)", [("2026-10-30T00:00:00Z",)])
    assert db.execute(sql).fetchone()[0] == 1
    db.execute("DELETE FROM A")
    assert db.execute(sql).fetchone()[0] == 0


def test_the_sql_engine_fits_the_shape_of_the_sibling_rules():
    sql = next(d for d in _rules()["data"] if d["refId"] == "C")["model"]["expression"]
    assert "GROUP BY" not in sql
    assert "FROM (SELECT updated_at FROM A) AS found" in sql
