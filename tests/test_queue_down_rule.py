import json
import pathlib
import shutil
import sqlite3
import subprocess
from datetime import datetime, timezone

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RULES = ROOT / "config/grafana/provisioning/alerting/queue-down.yaml"
POLICY = ROOT / "config/grafana/provisioning/alerting/cloudflare-spend-contact.yaml"
YQ = shutil.which("yq")
NOW = datetime(2026, 10, 10, 12, 0, tzinfo=timezone.utc)
REPOS = (
    "Nishfleet/0509", "Nishfleet/TinyStudio.io-public", "Nishfleet/aiconverter-app",
    "Nishfleet/drive", "Nishfleet/fleet-ops", "Nishfleet/rera-report-card",
    "Nishfleet/siterep-public", "Nishfleet/tether",
)
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


def _down(runs):
    return _run_in_sqlite("queue-down", "queue_down", runs)


def _down_for_2h(runs):
    return _run_in_sqlite("queue-down-2h", "queue_down_for_2h", runs)


def _query(rule):
    return next(d for d in rule["data"] if d["refId"] == "A")


def test_each_rule_reads_the_main_dispatch_workflow_through_the_org_app_installation():
    rules = _all_rules()
    assert len({r["uid"] for r in rules}) == len(rules)
    for r in rules:
        query = _query(r)
        model = query["model"]
        owner, repo, opts = model["owner"], model["repository"], model["options"]
        assert model["queryType"] == "Workflow_Runs"
        assert (opts["owner"], opts["repository"], opts["workflow"], opts["branch"]) == (owner, repo, "agent-dispatch.yml", "main")
        assert query["datasourceUid"] == model["datasource"]["uid"] == DATASOURCE[owner]
        full = f"{owner}/{repo}"
        assert r["title"].endswith(f" {full}")
        assert (r["labels"]["repo"], r["labels"]["workflow"]) == (full, opts["workflow"])
        for text in r["annotations"].values():
            assert full in text and opts["workflow"] in text, f"{r['title']}: annotation names another repo or workflow"
        assert "notification_settings" not in r


def test_the_issue_group_covers_every_queued_repo_and_the_2h_group_holds_the_same_query():
    groups = _groups()
    issue = {r["labels"]["repo"]: r for r in groups["queue-down"]}
    page = {r["labels"]["repo"]: r for r in groups["queue-down-2h"]}
    assert set(issue) == set(page) == set(REPOS)
    intake = {f"Nishfleet/{r['name']}" for r in json.loads((ROOT / "config/intake-repos.json").read_text())["repos"]}
    assert set(REPOS) == intake | {"Nishfleet/fleet-ops", "Nishfleet/drive"}
    for repo, r in issue.items():
        assert (r["labels"]["signal"], r["for"], r["execErrState"], r["noDataState"]) == ("queue-down", "0s", "Error", "Alerting")
        assert "No agent-dispatch run on main" in r["annotations"]["summary"] and "the fleet is paused" in r["annotations"]["summary"]
        assert "what NoData means here" in r["annotations"]["description"]
    for repo, r in page.items():
        assert (r["labels"]["signal"], r["for"], r["execErrState"], r["noDataState"]) == ("queue-down-2h", "10m", "Error", "OK")
        assert "No agent-dispatch run on main" in r["annotations"]["summary"] and "noDataState: OK" in r["annotations"]["summary"]
        assert _query(r) == _query(issue[repo])


def test_the_condition_is_the_sql_over_query_a():
    for r in _all_rules():
        cond = next(d for d in r["data"] if d["refId"] == r["condition"])
        assert cond["datasourceUid"] == "__expr__"
        assert (cond["model"]["type"], cond["model"]["format"]) == ("sql", "alerting")
        assert [d["refId"] for d in r["data"]] == ["A", r["condition"]]


def test_only_the_2h_group_is_critical_its_read_errors_are_muted_and_the_tree_pages_it_hourly():
    for r in _all_rules():
        assert r["labels"]["severity"] == ("critical" if r["labels"]["signal"] == "queue-down-2h" else "warning")
    policy = _yq(".policies[0]", POLICY)
    assert policy["receiver"] == "fleet-alert-dispatch"
    matched = [r for r in policy["routes"] if any(m[0] == "signal" and m[1] == "=" and m[2] == "queue-down-2h" for m in r["object_matchers"])]
    assert len(matched) == 1
    muted = matched[0]
    assert muted["receiver"] == "fleet-alert-dispatch"
    assert sorted(muted["object_matchers"]) == [["alertname", "=~", "DatasourceError|DatasourceNoData"], ["signal", "=", "queue-down-2h"]]
    assert muted["mute_time_intervals"] == ["deploy-failed-24h-and-queue-down-2h-errors"]
    assert not muted.get("continue")
    errors = next(r for r in policy["routes"] if r["receiver"] == "hermes-urgent" and ["alertname", "=~", "DatasourceError|DatasourceNoData"] in r["object_matchers"])
    assert ["signal", "!~", "deploy-failed-24h|queue-down-2h"] in errors["object_matchers"]
    critical = next(r for r in policy["routes"] if ["severity", "=", "critical"] in r["object_matchers"])
    assert (critical["receiver"], critical["repeat_interval"], critical["continue"]) == ("hermes-urgent", "1h", True)
    assert _yq(".muteTimes", POLICY) == [{"orgId": 1, "name": "deploy-failed-24h-and-queue-down-2h-errors", "time_intervals": [{"times": [{"start_time": "00:00", "end_time": "24:00"}]}]}]


def test_every_window_covers_three_hours_of_runs():
    windows = {r["labels"]["repo"]: _query(r)["relativeTimeRange"] for r in _all_rules()}
    assert set(map(json.dumps, windows.values())) == {json.dumps({"from": 10800, "to": 0})}


@pytest.mark.parametrize("runs,want", [
    ([(1, "2026-10-10T10:55:00Z", "completed", "success"), (2, "2026-10-10T11:55:00Z", "completed", "success")], [0]),
    ([(1, "2026-10-10T10:55:00Z", "completed", "success"), (2, "2026-10-10T11:45:00Z", "completed", "failure")], [0]),
    ([(1, "2026-10-10T10:55:00Z", "completed", "success"), (2, "2026-10-10T11:15:00Z", "completed", "failure")], [1]),
    ([(1, "2026-10-10T10:55:00Z", "completed", "success"), (2, "2026-10-10T11:55:00Z", "completed", "startup_failure")], [1]),
    ([(1, "2026-10-10T10:55:00Z", "completed", "startup_failure"), (2, "2026-10-10T11:55:00Z", "completed", "success")], [0]),
    ([(1, "2026-10-10T10:55:00Z", "completed", "success"), (2, "2026-10-10T11:15:00Z", "completed", "failure"), (3, "2026-10-10T11:55:00Z", "in_progress", None)], [1]),
    ([(1, "2026-10-10T10:55:00Z", "completed", "failure"), (2, "2026-10-10T11:55:00Z", "completed", "neutral")], [0]),
    ([(1, "2026-10-10T10:55:00Z", "completed", "success"), (2, "2026-10-10T11:55:00Z", "completed", "timed_out")], [0]),
    ([(1, "2026-10-10T10:55:00Z", "completed", "success"), (2, "2026-10-10T11:55:00Z", "completed", "stale")], [0]),
    ([(1, "2026-10-10T10:55:00Z", "completed", "success"), (2, "2026-10-10T11:55:00Z", "completed", "action_required")], [0]),
    ([(1, "2026-10-10T11:55:00Z", "completed", "cancelled")], [0]),
    ([(1, "2026-10-10T11:55:00Z", "completed", "skipped")], [0]),
    ([(1, "2026-10-10T11:55:00Z", "queued", None)], [0]),
    ([(1, "2026-10-10T11:55:00Z", "in_progress", None)], [0]),
    ([], []),
])
def test_the_sql_reads_a_startup_failure_at_once_or_a_failing_streak_30_minutes_old(runs, want):
    assert _down(runs) == want


@pytest.mark.parametrize("runs,want", [
    ([(1, "2026-10-10T08:55:00Z", "completed", "success"), (2, "2026-10-10T09:50:00Z", "completed", "failure")], [1]),
    ([(1, "2026-10-10T10:55:00Z", "completed", "success"), (2, "2026-10-10T10:50:00Z", "completed", "failure")], [0]),
    ([(1, "2026-10-10T10:55:00Z", "completed", "success"), (2, "2026-10-10T11:15:00Z", "completed", "failure")], [0]),
    ([(1, "2026-10-10T10:55:00Z", "completed", "success"), (2, "2026-10-10T11:55:00Z", "completed", "startup_failure")], [1]),
    ([(1, "2026-10-10T10:55:00Z", "completed", "startup_failure"), (2, "2026-10-10T11:55:00Z", "completed", "success")], [0]),
    ([(1, "2026-10-10T10:55:00Z", "completed", "success"), (2, "2026-10-10T11:15:00Z", "completed", "failure"), (3, "2026-10-10T11:55:00Z", "completed", "skipped")], [0]),
    ([(1, "2026-10-10T10:55:00Z", "completed", "success"), (2, "2026-10-10T11:25:00Z", "completed", "cancelled"), (3, "2026-10-10T11:55:00Z", "completed", "success")], [0]),
    ([(1, "2026-10-10T10:55:00Z", "completed", "success"), (2, "2026-10-10T11:15:00Z", "completed", "cancelled")], [0]),
    ([(1, "2026-10-10T10:55:00Z", "completed", "success"), (2, "2026-10-10T11:55:00Z", "in_progress", None)], [0]),
    ([(1, "2026-10-10T11:55:00Z", "completed", "skipped")], [0]),
    ([(1, "2026-10-10T11:55:00Z", "queued", None)], [0]),
    ([], []),
])
def test_the_2h_sql_pages_only_on_a_failing_streak_two_hours_old_or_a_startup_failure(runs, want):
    assert _down_for_2h(runs) == want


@pytest.mark.parametrize("runs,want", [
    ([(1, "2026-10-10T10:55:00Z", "completed", "success"), (2, None, "completed", "failure")], [0, 0]),
    ([(1, None, "completed", "failure")], [0, 0]),
    ([(1, None, "completed", "success")], [0]),
])
def test_the_sql_returns_two_rows_so_grafana_errors_when_a_failing_streak_has_no_start_date(runs, want):
    assert _down(runs) == want
    assert _down_for_2h(runs) == want


def test_the_empty_window_returns_zero_rows_so_grafana_treats_it_as_nodata():
    assert _down([]) == []
    assert _down_for_2h([]) == []


def test_a_window_whose_runs_are_all_unfinished_or_skipped_reads_zero_not_nodata():
    backlog = [(1, "2026-10-10T09:55:00Z", "queued", None), (2, "2026-10-10T10:55:00Z", "in_progress", None), (3, "2026-10-10T11:55:00Z", "completed", "skipped")]
    assert _down(backlog) == [0]
    assert _down_for_2h(backlog) == [0]
