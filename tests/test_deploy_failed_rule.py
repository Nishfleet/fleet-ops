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
DATASOURCE = {"Nishfleet": "fleet-github"}


def _yq(expr, path):
    assert YQ, "yq must be on PATH to read the alert rules"
    return json.loads(subprocess.run([YQ, "-o=json", expr, str(path)], capture_output=True, text=True, check=True).stdout)


def _groups():
    return {g["name"]: g["rules"] for g in _yq(".groups", RULES)}


def _deleted_uids():
    return {r["uid"] for r in _yq(".deleteRules", RULES) or []}


def _all_rules():
    return [r for rules in _groups().values() for r in rules]


def _sql(group):
    expressions = {next(d for d in r["data"] if d["refId"] == r["condition"])["model"]["expression"] for r in _groups()[group]}
    assert len(expressions) == 1, f"every rule in {group} must run the same SQL"
    return expressions.pop()


def _run_in_sqlite(group, column, runs):
    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE A (id INTEGER, created_at TEXT, status TEXT, conclusion TEXT)")
    db.executemany("INSERT INTO A VALUES (?, ?, ?, ?)", runs)
    cur = db.execute(_sql(group))
    rows = cur.fetchall()
    assert [c[0] for c in cur.description] == [column]
    return [r[0] for r in rows]


def _latest(runs):
    return _run_in_sqlite("deploy-failed", "failed", runs)


def _query(rule):
    return next(d for d in rule["data"] if d["refId"] == "A")


def test_a_uid_in_delete_rules_is_not_also_a_live_rule():
    # A rule that comes back to the file must take its uid out of deleteRules, or
    # the next provisioning load deletes the rule that just returned. The reverse
    # pairing, the uid gone from the file and from deleteRules, is what lets a
    # removed rule stay live (fleet-ops#10198, #10206).
    deleted = _deleted_uids()
    live = {r["uid"] for r in _all_rules()}
    assert not (deleted & live), f"uids in both the file and deleteRules: {sorted(deleted & live)}"


def test_each_rule_reads_one_main_workflow_through_the_org_app_installation():
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


def test_one_issue_rule_per_product_repo_and_no_paging_group():
    groups = _groups()
    assert set(groups) == {"deploy-failed"}
    for r in groups["deploy-failed"]:
        assert (r["labels"]["signal"], r["for"], r["execErrState"], r["noDataState"]) == ("deploy-failed", "30m", "Error", "OK")
        assert "cannot read GitHub runs" in r["annotations"]["summary"]


def test_the_condition_is_the_sql_over_query_a():
    for r in _all_rules():
        cond = next(d for d in r["data"] if d["refId"] == r["condition"])
        assert cond["datasourceUid"] == "__expr__"
        assert (cond["model"]["type"], cond["model"]["format"]) == ("sql", "alerting")
        assert [d["refId"] for d in r["data"]] == ["A", r["condition"]]


def test_every_rule_is_a_warning_and_the_tree_files_it_as_a_fleet_issue():
    for r in _all_rules():
        assert r["labels"]["severity"] == "warning"
    policy = _yq(".policies[0]", POLICY)
    assert policy["receiver"] == "fleet-alert-dispatch"
    assert not [r for r in policy["routes"] if any(m[0] == "signal" and m[2].startswith("deploy-failed") for m in r["object_matchers"])]


def test_each_window_covers_a_day_red_with_room_and_0509_reads_three_days():
    windows = {r["labels"]["repo"]: _query(r)["relativeTimeRange"] for r in _all_rules()}
    assert windows.pop("Nishfleet/0509") == {"from": 259200, "to": 0}
    assert set(map(json.dumps, windows.values())) == {json.dumps({"from": 604800, "to": 0})}


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
def test_the_sql_branch_logic_in_sqlite_reads_the_newest_finished_run(runs, want):
    assert _latest(runs) == want
