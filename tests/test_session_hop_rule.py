"""fleet-ops#10819: the session-hop alarm cannot die silently, and its window
must read the same hops from the same data on every evaluation.

The rate rule filters the session_hop_logs view down to acompletion success
rows with a session and a model, and reads NoData as OK, so a supply that dries
up while traffic continues (LiteLLM renames a call_type or status enum value,
or stops writing session_id — the view already drops the 123k of 618k rows
that have none) leaves it permanently quiet. The session-hop-volume rule added
with this file counts that same supply over a day and fires at zero; the first
test runs the volume rule's real SQL and its real threshold from the yaml, and
fails unless a day with qualifying calls holds it quiet and an empty day fires
it, while one dangling call does not.

The window defect: LiteLLM_SpendLogs can hold more than one row per request
(attempt, retry, fallback) at equal startTime, so a window ordered by
"startTime" alone leaves the lag order to the engine's scan order and the hop
count flaps between evaluations — the same tie case reads 1 hop in one scan
order and 2 in the other. The rate rule orders by ("startTime", model_id);
the second test extracts the window clause from the rule itself, runs a hop
count over a tie case in both scan orders, and fails unless both read the
same; a stripped clause is a loud failure rather than a silent flap.
"""
from __future__ import annotations

import json
import pathlib
import re
import shutil
import sqlite3
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
RULES = ROOT / "config/grafana/provisioning/alerting/session-hop.yaml"
YQ = shutil.which("yq")


def _rules():
    assert YQ, "yq must be on PATH to read the alert rules"
    out = subprocess.run(
        [YQ, "-o=json", ".groups[].rules", str(RULES)],
        capture_output=True, text=True, check=True,
    )
    return {r["uid"]: r for r in json.loads(out.stdout)}


def _sql(rule):
    return next(d for d in rule["data"] if d["refId"] == "A")["model"]["rawSql"]


def _connect():
    db = sqlite3.connect(":memory:")
    db.create_function("split_part", 3, lambda s, d, i: (s.split(d)[i - 1] if 0 < i <= len(s.split(d)) else None) if s is not None else None)
    db.execute('CREATE TABLE session_hop_logs (session_id TEXT, model_id TEXT, "startTime" TEXT, call_type TEXT, status TEXT)')
    return db


def _fires(rule, value):
    step = next(d for d in rule["data"] if d["refId"] == rule["condition"])["model"]
    evaluator = step["conditions"][0]["evaluator"]
    assert evaluator["type"] in ("lt", "gt"), f"unsupported evaluator: {evaluator['type']}"
    bar = evaluator["params"][0]
    return value < bar if evaluator["type"] == "lt" else value > bar


def test_volume_rule_holds_quiet_on_traffic_and_fires_on_a_zero_day():
    rule = _rules()["session-hop-volume"]
    sql, n = re.subn(r"\(NOW\(\) AT TIME ZONE 'UTC'\) - INTERVAL '24 hours'", ":cutoff", _sql(rule))
    assert n == 1, "the volume SQL no longer carries the 24-hour bound the test translates"
    db = _connect()
    db.executemany(
        "INSERT INTO session_hop_logs VALUES (?,?,?,?,?)",
        [("s1", "seat-a-1", f"2026-10-31 09:{m:02d}:00", "acompletion", "success") for m in range(30)]
        + [("s2", "seat-b-1", f"2026-10-31 09:{m:02d}:00", "acompletion", "success") for m in range(30)],
    )
    cutoff = {"cutoff": "2026-10-31 08:00:00"}
    assert db.execute(sql, cutoff).fetchone()[0] == 60
    assert not _fires(rule, 60), "a day with 60 qualifying calls must hold the rule quiet"
    db.execute("DELETE FROM session_hop_logs")
    db.execute("INSERT INTO session_hop_logs VALUES ('s1', 'seat-a-1', '2026-10-31 09:00:00', 'acompletion', 'success')")
    one = db.execute(sql, cutoff).fetchone()[0]
    assert one == 1
    assert not _fires(rule, one), "one dangling call in the day is not the broken-supply signature"
    db.execute("DELETE FROM session_hop_logs")
    zero = db.execute(sql, cutoff).fetchone()[0]
    assert zero == 0
    assert _fires(rule, zero), "a day the supply reads zero must fire the volume rule"


def test_rate_window_reads_the_same_hops_from_both_scan_orders():
    window = re.search(r"WINDOW w AS \(PARTITION BY session_id ORDER BY [^)]+\)", _sql(_rules()["session-hop-rate"]))
    assert window, "the rate SQL carries no window"
    assert re.search(r'ORDER BY "startTime"\s*,\s*\S', window.group(0)), (
        f'the window orders by startTime alone, so the lag order is the engine scan order: {window.group(0)}'
    )
    hop_sql = (
        "SELECT count(*) FILTER (WHERE prev_key IS DISTINCT FROM split_part(model_id, '-', 1)) FROM ("
        "SELECT session_id, model_id, lag(split_part(model_id, '-', 1)) OVER w AS prev_key "
        "FROM session_hop_logs WHERE call_type = 'acompletion' AND status = 'success' "
        + window.group(0) + ") WHERE prev_key IS NOT NULL"
    )
    reads = []
    for first, second in (("seat-a-1", "seat-b-1"), ("seat-b-1", "seat-a-1")):
        db = _connect()
        db.execute("INSERT INTO session_hop_logs VALUES ('s1', 'seat-a-1', '2026-10-31 10:00:00', 'acompletion', 'success')")
        db.execute("INSERT INTO session_hop_logs VALUES ('s1', ?, '2026-10-31 10:05:00', 'acompletion', 'success')", (first,))
        db.execute("INSERT INTO session_hop_logs VALUES ('s1', ?, '2026-10-31 10:05:00', 'acompletion', 'success')", (second,))
        reads.append(db.execute(hop_sql).fetchone()[0])
    assert reads[0] == reads[1], f"the same tie case reads {reads} hops under the two scan orders"


def test_volume_rule_guards_the_rate_rule_and_pages():
    rules = _rules()
    rate, volume = rules["session-hop-rate"], rules["session-hop-volume"]
    assert rate["noDataState"] == "OK", "the rate rule must keep reading NoData as OK: the volume rule is its detector"
    assert volume["noDataState"] == "Alerting", "an empty frame must not read OK on the detector"
    assert volume["execErrState"] == "Error", "a broken count must page, not log"
    assert volume["labels"]["severity"] == "critical"
    assert volume["labels"]["signal"] == "session-hop"
    rate_sql, volume_sql = _sql(rate), _sql(volume)
    for clause in ("session_hop_logs", "call_type = 'acompletion'", "status = 'success'"):
        assert clause in rate_sql and clause in volume_sql, clause
    lookback = next(d for d in volume["data"] if d["refId"] == "A")["relativeTimeRange"]
    assert lookback == {"from": 86400, "to": 0}
    assert "INTERVAL '24 hours'" in volume_sql
