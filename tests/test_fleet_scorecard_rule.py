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
    sql = next(d for d in _rules()[uid]["data"] if d["refId"] == "C")["model"]["expression"]
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
    return _missed("scorecard-products-behind", {"A": own, "B": prod}, "closed_at TEXT, unused TEXT")


@pytest.mark.parametrize("args,missed", [((5, 3, 5, 3), 1), ((5, 5, 5, 5), 1), ((5, 6, 5, 3), 0), ((5, 3, 5, 6), 0), ((0, 0, 0, 0), 0)])
def test_products_behind_fires_only_when_both_days_miss(args, missed):
    assert _merged(*args) == missed


DASHBOARD = ROOT / "config/grafana/dashboards/fleet-scorecard.json"
GRAFANA_SQL_FUNCTIONS = {"sum", "count", "round", "substring", "unix_timestamp", "coalesce", "if", "ifnull", "floor", "date_format", "min", "max", "avg", "abs", "from", "in"}


def _targets():
    return [t for p in json.loads(DASHBOARD.read_text())["panels"] for t in p.get("targets", [])]


def test_dashboard_sql_calls_only_functions_grafana_allows():
    for t in _targets():
        for name in re.findall(r"\b([A-Za-z_]+)\s*\(", t.get("expression", "")):
            assert name.lower() in GRAFANA_SQL_FUNCTIONS, name


def test_dashboard_pull_request_searches_name_a_repository():
    searches = [t for t in _targets() if t.get("queryType") == "Pull_Requests"]
    assert len(searches) == 2
    assert all(t["repository"] for t in searches)
