"""Fleet scorecard alerts (fleet-ops#10711): each rule's real SQL, read out with yq and run in
sqlite, fires only when both windows miss."""
import json
import pathlib
import re
import shutil
import sqlite3
import subprocess
from datetime import datetime, timedelta, timezone

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RULES = ROOT / "config/grafana/provisioning/alerting/fleet-scorecard.yaml"
ALERTING = ROOT / "config/grafana/provisioning/alerting"
CONTAINER = ROOT / "containers/quadlet/fleet-grafana.container"
NOW = datetime(2026, 10, 28, 12, 0, tzinfo=timezone.utc)
FMT = "%Y-%m-%dT%H:%M:%SZ"


def _rules():
    out = subprocess.run([shutil.which("yq"), "-o=json", ".groups[].rules", str(RULES)], capture_output=True, text=True, check=True)
    return {r["uid"]: r for r in json.loads(out.stdout)}


def _unix_timestamp(*value):
    when = datetime.strptime(value[0], FMT).replace(tzinfo=timezone.utc) if value else NOW
    return int(when.timestamp())


def _missed(uid, tables, columns):
    db = sqlite3.connect(":memory:")
    db.create_function("UNIX_TIMESTAMP", -1, _unix_timestamp)
    for name, rows in tables.items():
        db.execute(f"CREATE TABLE {name} ({columns})")
        db.executemany(f"INSERT INTO {name} VALUES (?, ?)", [((NOW - timedelta(hours=h)).strftime(FMT), c) for h, c in rows])
    rule = _rules()[uid]
    sql = next(d for d in rule["data"] if d["refId"] == rule["condition"])["model"]["expression"]
    return db.execute(sql).fetchone()[0]


def _runs(good_new, bad_new, good_prev, bad_prev):
    return [(1, "success")] * good_new + [(2, "failure")] * bad_new, [(25, "success")] * good_prev + [(26, "failure")] * bad_prev


@pytest.mark.parametrize("new,prev,missed", [((90, 5), (90, 5), 1), ((100, 0), (90, 5), 0), ((90, 5), (100, 0), 0), ((0, 0), (0, 0), 0), ((90, 5), (0, 0), 0)])
def test_failure_share_fires_only_when_both_windows_miss(new, prev, missed):
    now_rows, day_ago_rows = _runs(*new, *prev)
    assert _missed("scorecard-run-failure-share", {"A": now_rows, "B": day_ago_rows, "C": [], "D": []}, "created_at TEXT, conclusion TEXT") == missed


def test_failure_share_ignores_cancelled_and_skipped():
    now_rows, day_ago_rows = _runs(98, 2, 98, 2)
    rows = now_rows + [(1, "cancelled")] * 50 + day_ago_rows + [(25, "skipped")] * 50
    assert _missed("scorecard-run-failure-share", {"A": rows, "B": [], "C": [], "D": []}, "created_at TEXT, conclusion TEXT") == 0


def _merged(own_today, prod_today, own_yday, prod_yday):
    own = [(1, None)] * own_today + [(30, None)] * own_yday
    prod = [(1, None)] * prod_today + [(30, None)] * prod_yday
    spread = {name: prod[i::8] for i, name in enumerate("BCDEFGHI")}
    return _missed("scorecard-products-behind", {"A": own, **spread}, "closed_at TEXT, unused TEXT")


@pytest.mark.parametrize("args,missed", [((5, 3, 5, 3), 1), ((5, 5, 5, 5), 1), ((5, 6, 5, 3), 0), ((5, 3, 5, 6), 0), ((0, 0, 0, 0), 0)])
def test_products_behind_fires_only_when_both_days_miss(args, missed):
    assert _merged(*args) == missed


DASHBOARD = ROOT / "config/grafana/dashboards/fleet-scorecard.json"
INTAKE = ROOT / "config/intake-repos.json"
GRAFANA_SQL_FUNCTIONS = {"sum", "count", "round", "substring", "unix_timestamp", "coalesce", "if", "ifnull", "floor", "ceil", "date_format", "from_unixtime", "min", "max", "avg", "abs", "row_number"}


def _dashboard_targets():
    return [t for p in json.loads(DASHBOARD.read_text())["panels"] for t in p.get("targets", [])]


def _rule_targets():
    return [d["model"] for r in _rules().values() for d in r["data"]]


def _searches(targets):
    return [t for t in targets() if t.get("queryType") == "Pull_Requests"]


def _declared_products():
    return {r["name"] for r in json.loads(INTAKE.read_text())["repos"] if r.get("product") is True}


def _rule_products_expression():
    rule = _rules()["scorecard-products-behind"]
    return next(d for d in rule["data"] if d["refId"] == rule["condition"])["model"]["expression"]


def _dashboard_products_expression():
    panel = next(p for p in json.loads(DASHBOARD.read_text())["panels"] if p["id"] == 2)
    return next(t["expression"] for t in panel["targets"] if t.get("type") == "sql")


@pytest.mark.parametrize("targets", [_dashboard_targets, _rule_targets])
def test_sql_calls_only_functions_grafana_allows(targets):
    for t in targets():
        for name in re.findall(r"\b(?!(?:from|in|as|on|and|or|when|then|else|union|all|select|where|join|over|partition)\b)([A-Za-z_]+)\s*\(", t.get("expression", ""), re.I):
            assert name.lower() in GRAFANA_SQL_FUNCTIONS, name


@pytest.mark.parametrize("targets", [_dashboard_targets, _rule_targets])
def test_pull_request_search_scopes_to_the_repository_it_names(targets):
    for t in _searches(targets):
        assert re.findall(r"repo:Nishfleet/(\S+)", t["options"]["query"]) == [t["repository"]]


@pytest.mark.parametrize("targets", [_dashboard_targets, _rule_targets])
def test_the_searched_repositories_are_the_registry_products_and_the_control_plane(targets):
    assert {t["repository"] for t in _searches(targets)} == _declared_products() | {"fleet-ops"}


@pytest.mark.parametrize("targets", [_dashboard_targets, _rule_targets])
def test_every_pull_request_search_reads_the_closed_timestamp(targets):
    assert {t["options"]["timeField"] for t in _searches(targets)} == {2}


def test_the_rule_searches_the_three_days_its_two_windows_divide():
    targets = [d for d in _rules()["scorecard-products-behind"]["data"] if d["model"].get("queryType") == "Pull_Requests"]
    assert {json.dumps(d["relativeTimeRange"], sort_keys=True) for d in targets} == {json.dumps({"from": 259200, "to": 0})}


def _failure_share_reads():
    rule = _rules()["scorecard-run-failure-share"]
    return rule, [d for d in rule["data"] if d["model"].get("queryType") == "Workflow_Runs"]


def test_the_failure_share_reads_each_window_with_its_own_target():
    _, reads = _failure_share_reads()
    now, day_ago = json.dumps({"from": 10800, "to": 0}), json.dumps({"from": 97200, "to": 86400})
    assert sorted(json.dumps(d["relativeTimeRange"], sort_keys=True) for d in reads) == sorted([now, now, day_ago, day_ago])


def test_the_failure_share_expression_windows_match_the_ranges_its_targets_read():
    rule, reads = _failure_share_reads()
    sql = next(d for d in rule["data"] if d["refId"] == rule["condition"])["model"]["expression"]
    assert {int(n) for n in re.findall(r"age [<>]=? (\d+)", sql)} | {0} == {d["relativeTimeRange"][edge] for d in reads for edge in ("from", "to")}


def test_the_container_gives_alert_reads_more_than_grafana_default_and_less_than_the_shortest_group_interval():
    line = next(l for l in CONTAINER.read_text().splitlines() if l.startswith("Environment=GF_UNIFIED_ALERTING_EVALUATION_TIMEOUT="))
    scale = {"s": 1, "m": 60, "h": 3600}
    intervals = [int(n) * scale[u] for p in ALERTING.glob("*.yaml") for n, u in re.findall(r"^\s+interval: (\d+)([smh])$", p.read_text(), re.M)]
    assert 30 < int(line.split("=")[2].removesuffix("s")) < min(intervals)


@pytest.mark.parametrize("targets,expression", [(_dashboard_targets, _dashboard_products_expression), (_rule_targets, _rule_products_expression)])
def test_the_expression_counts_every_repository_it_queries(targets, expression):
    assert {t["refId"] for t in _searches(targets)} == set(re.findall(r"\bFROM ([A-Z])\b", expression()))
