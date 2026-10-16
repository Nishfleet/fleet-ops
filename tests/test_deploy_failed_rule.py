import json
import pathlib
import shutil
import sqlite3
import subprocess
from datetime import datetime, timezone

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RULES = ROOT / "config/grafana/provisioning/alerting/deploy-failed.yaml"
POLICY = ROOT / "config/grafana/provisioning/alerting/cloudflare-spend-contact.yaml"
YQ = shutil.which("yq")
NOW = datetime(2026, 10, 10, 12, 0, tzinfo=timezone.utc)
DATASOURCE = {"Nishfleet": "fleet-github"}


def _yq(expr, path):
    assert YQ, "yq must be on PATH to read the alert rules"
    return json.loads(subprocess.run([YQ, "-o=json", expr, str(path)], capture_output=True, text=True, check=True).stdout)


def _groups():
    return {g["name"]: g["rules"] for g in _yq(".groups", RULES)}


def _all_rules():
    return [r for rules in _groups().values() for r in rules]


def _sql(group):
    expressions = {next(d for d in r["data"] if d["refId"] == r["condition"])["model"]["expression"] for r in _groups()[group]}
    assert len(expressions) == 1, f"every rule in {group} must run the same SQL"
    return expressions.pop()


def _unix_timestamp(*value):
    if value and value[0] is None:
        return None
    when = datetime.strptime(value[0], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) if value else NOW
    return int(when.timestamp())


def _run_in_sqlite(group, column, runs):
    db = sqlite3.connect(":memory:")
    db.create_function("UNIX_TIMESTAMP", -1, _unix_timestamp)
    db.execute("CREATE TABLE A (id INTEGER, created_at TEXT, status TEXT, conclusion TEXT)")
    db.executemany("INSERT INTO A VALUES (?, ?, ?, ?)", runs)
    cur = db.execute(_sql(group))
    rows = cur.fetchall()
    assert [c[0] for c in cur.description] == [column]
    return [r[0] for r in rows]


def _latest(runs):
    return _run_in_sqlite("deploy-failed", "failed", runs)


def _red_for_a_day(runs):
    return _run_in_sqlite("deploy-failed-24h", "red_for_a_day", runs)


def _query(rule):
    return next(d for d in rule["data"] if d["refId"] == "A")


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


def test_the_issue_group_covers_every_repo_and_the_24h_group_holds_the_same_query_for_a_day():
    groups = _groups()
    issue = {r["labels"]["repo"]: r for r in groups["deploy-failed"]}
    page = {r["labels"]["repo"]: r for r in groups["deploy-failed-24h"]}
    assert set(page) == set(issue) - {"Nishfleet/inish-site"}
    for repo, r in issue.items():
        assert (r["labels"]["signal"], r["for"], r["execErrState"], r["noDataState"]) == ("deploy-failed", "30m", "Error", "OK")
        assert "cannot read GitHub runs" in r["annotations"]["summary"]
    for repo, r in page.items():
        assert (r["labels"]["signal"], r["for"], r["execErrState"], r["noDataState"]) == ("deploy-failed-24h", "10m", "Error", "OK")
        assert "cannot read GitHub runs" in r["annotations"]["summary"]
        assert _query(r) == _query(issue[repo])


def test_the_condition_is_the_sql_over_query_a():
    for r in _all_rules():
        cond = next(d for d in r["data"] if d["refId"] == r["condition"])
        assert cond["datasourceUid"] == "__expr__"
        assert (cond["model"]["type"], cond["model"]["format"]) == ("sql", "alerting")
        assert [d["refId"] for d in r["data"]] == ["A", r["condition"]]


def test_only_a_day_red_is_critical_its_read_errors_are_muted_and_the_tree_pages_it_hourly():
    for r in _all_rules():
        assert r["labels"]["severity"] == ("critical" if r["labels"]["signal"] == "deploy-failed-24h" else "warning")
    policy = _yq(".policies[0]", POLICY)
    assert policy["receiver"] == "fleet-alert-dispatch"
    matched = [r for r in policy["routes"] if any(m[0] == "signal" and m[1] == "=" and m[2].startswith("deploy-failed") for m in r["object_matchers"])]
    assert len(matched) == 1
    muted = matched[0]
    assert muted["receiver"] == "fleet-alert-dispatch"
    assert sorted(muted["object_matchers"]) == [["alertname", "=~", "DatasourceError|DatasourceNoData"], ["signal", "=", "deploy-failed-24h"]]
    assert muted["mute_time_intervals"] == ["deploy-failed-24h-errors"]
    assert not muted.get("continue")
    errors = next(r for r in policy["routes"] if r["receiver"] == "hermes-urgent" and ["alertname", "=~", "DatasourceError|DatasourceNoData"] in r["object_matchers"])
    assert ["signal", "!=", "deploy-failed-24h"] in errors["object_matchers"]
    critical = next(r for r in policy["routes"] if ["severity", "=", "critical"] in r["object_matchers"])
    assert (critical["receiver"], critical["repeat_interval"], critical["continue"]) == ("hermes-urgent", "1h", True)
    assert _yq(".muteTimes", POLICY) == [{"orgId": 1, "name": "deploy-failed-24h-errors", "time_intervals": [{"times": [{"start_time": "00:00", "end_time": "24:00"}]}]}]


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
    assert _red_for_a_day([(i, "2026-10-01T00:00:00Z" if c else t, st, c) for i, t, st, c in runs]) == ([1] if want == [1] else [0])


@pytest.mark.parametrize("runs,want", [
    ([(1, "2026-10-09T08:00:00Z", "completed", "failure"), (2, "2026-10-09T09:00:00Z", "completed", "success")], [0]),
    ([(1, "2026-10-09T11:00:00Z", "completed", "failure")], [1]),
    ([(1, "2026-10-09T00:00:00Z", "completed", "success"), (2, "2026-10-09T13:00:00Z", "completed", "failure")], [0]),
    ([(1, "2026-10-08T00:00:00Z", "completed", "success"), (2, "2026-10-09T10:00:00Z", "completed", "failure"), (3, "2026-10-10T11:00:00Z", "completed", "failure")], [1]),
    ([(1, "2026-10-08T00:00:00Z", "completed", "failure"), (2, "2026-10-10T02:00:00Z", "completed", "success"), (3, "2026-10-10T10:00:00Z", "completed", "failure")], [0]),
    ([(1, "2026-10-08T00:00:00Z", "completed", "success"), (2, "2026-10-09T10:00:00Z", "completed", "cancelled"), (3, "2026-10-10T11:00:00Z", "completed", "skipped")], [1]),
    ([(1, "2026-10-08T00:00:00Z", "completed", "failure"), (2, "2026-10-09T10:00:00Z", "completed", "cancelled"), (3, "2026-10-10T11:00:00Z", "completed", "success")], [0]),
    ([(1, "2026-10-08T00:00:00Z", "completed", "failure"), (2, "2026-10-10T11:00:00Z", "in_progress", None)], [1]),
    ([(1, "2026-10-10T11:00:00Z", "in_progress", None)], [0]),
    ([(1, "2026-10-08T10:00:00Z", "completed", "success"), (2, "2026-10-09T06:00:00Z", "completed", "skipped"), (3, "2026-10-10T11:00:00Z", "completed", "skipped")], [0]),
    ([(1, "2026-10-07T10:00:00Z", "completed", "skipped")], [0]),
    ([(1, "2026-10-08T10:00:00Z", "completed", "success"), (2, "2026-10-09T06:00:00Z", "completed", "skipped"), (3, "2026-10-10T11:00:00Z", "completed", "failure")], [0]),
    ([(1, "2026-10-08T10:00:00Z", "completed", "success"), (2, "2026-10-09T06:00:00Z", "completed", "failure"), (3, "2026-10-10T11:00:00Z", "completed", "skipped")], [1]),
    ([], [0]),
])
def test_the_day_sql_branch_logic_in_sqlite_pages_only_on_a_red_streak_a_day_old(runs, want):
    assert _red_for_a_day(runs) == want


@pytest.mark.parametrize("runs,want", [
    ([(1, "2026-10-08T00:00:00Z", "completed", "success"), (2, None, "completed", "failure")], [0, 0]),
    ([(1, None, "completed", "failure")], [0, 0]),
    ([(1, None, "completed", "success")], [0]),
])
def test_the_day_sql_returns_two_rows_so_grafana_errors_when_a_red_streak_has_no_start_date(runs, want):
    assert _red_for_a_day(runs) == want
