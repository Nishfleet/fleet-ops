import json
import pathlib
import shutil
import sqlite3
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RULES = ROOT / "config/grafana/provisioning/alerting/deploy-failed.yaml"
POLICY = ROOT / "config/grafana/provisioning/alerting/cloudflare-spend-contact.yaml"
YQ = shutil.which("yq")
DATASOURCE = {"Nishfleet": "fleet-github", "nish3451": "fleet-github-personal"}


def _yq(expr, path):
    assert YQ, "yq must be on PATH to read the alert rules"
    return json.loads(subprocess.run([YQ, "-o=json", expr, str(path)], capture_output=True, text=True, check=True).stdout)


def _groups():
    return {g["name"]: g["rules"] for g in _yq(".groups", RULES)}


def _all_rules():
    return [r for rules in _groups().values() for r in rules]


def _sql():
    expressions = {next(d for d in r["data"] if d["refId"] == r["condition"])["model"]["expression"] for r in _all_rules()}
    assert len(expressions) == 1, "every deploy rule must run the same SQL"
    return expressions.pop()


def _latest(runs):
    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE A (id INTEGER, created_at TEXT, status TEXT, conclusion TEXT)")
    db.executemany("INSERT INTO A VALUES (?, ?, ?, ?)", runs)
    cur = db.execute(_sql())
    rows = cur.fetchall()
    assert [c[0] for c in cur.description] == ["failed"]
    return [r[0] for r in rows]


def _query(rule):
    return next(d for d in rule["data"] if d["refId"] == "A")


def test_each_rule_reads_one_main_workflow_through_its_owners_app_installation():
    rules = _all_rules()
    assert len({r["uid"] for r in rules}) == len(rules)
    for r in rules:
        query = _query(r)
        model = query["model"]
        owner, repo, opts = model["owner"], model["repository"], model["options"]
        assert model["queryType"] == "Workflow_Runs"
        assert (opts["owner"], opts["repository"], opts["branch"]) == (owner, repo, "main")
        assert query["datasourceUid"] == model["datasource"]["uid"] == DATASOURCE[owner]
        full = f"{owner}/{repo}"
        assert r["title"].endswith(f" {full}")
        assert (r["labels"]["repo"], r["labels"]["workflow"]) == (full, opts["workflow"])
        for text in r["annotations"].values():
            assert full in text and opts["workflow"] in text, f"{r['title']}: annotation names another repo or workflow"
        assert "notification_settings" not in r


def test_the_issue_group_covers_every_repo_and_the_24h_group_holds_the_same_query_for_a_day():
    groups = _groups()
    issue = {r["labels"]["repo"]: r for r in groups["deploy-failed"]}
    page = {r["labels"]["repo"]: r for r in groups["deploy-failed-24h"]}
    assert set(page) == set(issue) - {"Nishfleet/inish-site"}
    for repo, r in issue.items():
        assert (r["labels"]["signal"], r["for"], r["execErrState"], r["noDataState"]) == ("deploy-failed", "30m", "Error", "OK")
        assert "cannot read GitHub runs" in r["annotations"]["summary"]
    for repo, r in page.items():
        assert (r["labels"]["signal"], r["for"], r["execErrState"], r["noDataState"]) == ("deploy-failed-24h", "24h", "KeepLast", "OK")
        assert _query(r) == _query(issue[repo])


def test_the_condition_is_the_sql_over_query_a():
    for r in _all_rules():
        cond = next(d for d in r["data"] if d["refId"] == r["condition"])
        assert cond["datasourceUid"] == "__expr__"
        assert (cond["model"]["type"], cond["model"]["format"]) == ("sql", "alerting")
        assert [d["refId"] for d in r["data"]] == ["A", r["condition"]]


def test_only_a_day_red_pages_and_everything_else_files_a_fleet_issue():
    policy = _yq(".policies[0]", POLICY)
    assert policy["receiver"] == "fleet-alert-dispatch"
    matched = [r for r in policy["routes"] if any(m[0] == "signal" and m[2].startswith("deploy-failed") for m in r["object_matchers"])]
    assert len(matched) == 1
    route = matched[0]
    assert route["receiver"] == "hermes-urgent"
    assert sorted(route["object_matchers"]) == [["alertname", "!~", "DatasourceError|DatasourceNoData"], ["signal", "=", "deploy-failed-24h"]]
    assert not route.get("continue")


@pytest.mark.parametrize("runs,want", [
    ([(1, "2026-10-01T10:00:00Z", "completed", "failure"), (2, "2026-10-02T10:00:00Z", "completed", "success")], [0]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "completed", "failure")], [1]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "completed", "timed_out")], [1]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "completed", "startup_failure")], [1]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "in_progress", None), (3, "2026-10-03T10:00:00Z", "queued", None)], [0]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "failure"), (2, "2026-10-01T10:00:00Z", "completed", "success")], [0]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "completed", "cancelled")], [1]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "failure"), (2, "2026-10-02T10:00:00Z", "completed", "cancelled"), (3, "2026-10-03T10:00:00Z", "completed", "success")], [0]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "completed", "cancelled"), (3, "2026-10-03T10:00:00Z", "completed", "failure")], [1]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "completed", "cancelled"), (3, "2026-10-03T10:00:00Z", "completed", "skipped")], [1]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "completed", "cancelled"), (3, "2026-10-03T10:00:00Z", "in_progress", None)], [1]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "failure"), (2, "2026-10-02T10:00:00Z", "completed", "neutral")], [0]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "completed", "stale")], [1]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "completed", "action_required")], [1]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "skipped")], []),
    ([], []),
])
def test_the_sql_reads_the_newest_finished_run(runs, want):
    assert _latest(runs) == want
