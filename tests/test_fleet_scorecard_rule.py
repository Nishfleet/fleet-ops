"""Fleet scorecard alerts (fleet-ops#10711): each rule's real SQL, read out with yq and run in
sqlite, fires only when both consecutive 24h windows miss."""
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


def _runs(good_today, bad_today, good_yday, bad_yday):
    return [(1, "success")] * good_today + [(2, "failure")] * bad_today + [(30, "success")] * good_yday + [(31, "failure")] * bad_yday


@pytest.mark.parametrize("today,yday,missed", [((90, 5, 0, 0), (0, 0, 90, 5), 1), ((100, 0, 90, 5), None, 0), ((90, 5, 100, 0), None, 0), ((0, 0, 0, 0), None, 0)])
def test_failure_share_fires_only_when_both_days_miss(today, yday, missed):
    rows = _runs(*today) if yday is None else _runs(today[0], today[1], yday[2], yday[3])
    assert _missed("scorecard-run-failure-share", {"A": rows, "B": []}, "created_at TEXT, conclusion TEXT") == missed


def test_failure_share_ignores_cancelled_and_skipped():
    rows = _runs(98, 2, 98, 2) + [(3, "cancelled")] * 50 + [(30, "skipped")] * 50
    assert _missed("scorecard-run-failure-share", {"A": rows, "B": []}, "created_at TEXT, conclusion TEXT") == 0


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


@pytest.mark.parametrize("targets,expression", [(_dashboard_targets, _dashboard_products_expression), (_rule_targets, _rule_products_expression)])
def test_the_expression_counts_every_repository_it_queries(targets, expression):
    assert {t["refId"] for t in _searches(targets)} == set(re.findall(r"\bFROM ([A-Z])\b", expression()))
