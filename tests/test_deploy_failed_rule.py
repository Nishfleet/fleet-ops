import json
import pathlib
import shutil
import sqlite3
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RULES = ROOT / "config/grafana/provisioning/alerting/deploy-failed.yaml"
YQ = shutil.which("yq")
DATASOURCE = {"Nishfleet": "fleet-github", "nish3451": "fleet-github-personal"}


def _rules():
    assert YQ, "yq must be on PATH to read the alert rules"
    out = subprocess.run([YQ, "-o=json", ".groups[0].rules", str(RULES)], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def _sql():
    expressions = {next(d for d in r["data"] if d["refId"] == r["condition"])["model"]["expression"] for r in _rules()}
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


def test_each_rule_reads_one_main_workflow_through_its_owners_app_installation():
    rules = _rules()
    assert len({r["uid"] for r in rules}) == len(rules)
    for r in rules:
        query = next(d for d in r["data"] if d["refId"] == "A")
        model = query["model"]
        owner, repo, opts = model["owner"], model["repository"], model["options"]
        assert model["queryType"] == "Workflow_Runs"
        assert (opts["owner"], opts["repository"], opts["branch"]) == (owner, repo, "main")
        assert query["datasourceUid"] == model["datasource"]["uid"] == DATASOURCE[owner]
        full = f"{owner}/{repo}"
        assert r["title"] == f"Production deploy failed {full}"
        assert r["labels"] == {"signal": "deploy-failed", "repo": full, "workflow": opts["workflow"]}
        for text in r["annotations"].values():
            assert full in text and opts["workflow"] in text, f"{r['title']}: annotation names another repo or workflow"
        assert "not an outage" in r["annotations"]["summary"]


def test_the_condition_is_the_sql_over_query_a_and_it_pages():
    for r in _rules():
        cond = next(d for d in r["data"] if d["refId"] == r["condition"])
        assert cond["datasourceUid"] == "__expr__"
        assert (cond["model"]["type"], cond["model"]["format"]) == ("sql", "alerting")
        assert [d["refId"] for d in r["data"]] == ["A", r["condition"]]
        assert r["notification_settings"]["receiver"] == "hermes-urgent"
        assert (r["execErrState"], r["noDataState"]) == ("Error", "OK")


@pytest.mark.parametrize("runs,want", [
    ([(1, "2026-10-01T10:00:00Z", "completed", "failure"), (2, "2026-10-02T10:00:00Z", "completed", "success")], [0]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "completed", "failure")], [1]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "completed", "timed_out")], [1]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "completed", "startup_failure")], [1]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "failure"), (2, "2026-10-02T10:00:00Z", "completed", "cancelled"), (3, "2026-10-03T10:00:00Z", "completed", "skipped")], [1]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "in_progress", None), (3, "2026-10-03T10:00:00Z", "queued", None)], [0]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "failure"), (2, "2026-10-01T10:00:00Z", "completed", "success")], [0]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "completed", "cancelled")], [1]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "skipped"), (2, "2026-10-02T10:00:00Z", "completed", "cancelled")], [1]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "failure"), (2, "2026-10-02T10:00:00Z", "completed", "cancelled"), (3, "2026-10-03T10:00:00Z", "completed", "success")], [0]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "completed", "cancelled"), (3, "2026-10-03T10:00:00Z", "in_progress", None)], [0]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "failure"), (2, "2026-10-02T10:00:00Z", "completed", "neutral")], [0]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "completed", "stale")], [1]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "success"), (2, "2026-10-02T10:00:00Z", "completed", "action_required")], [1]),
    ([(1, "2026-10-01T10:00:00Z", "completed", "skipped")], []),
    ([], []),
])
def test_the_sql_reads_the_newest_finished_run(runs, want):
    assert _latest(runs) == want
