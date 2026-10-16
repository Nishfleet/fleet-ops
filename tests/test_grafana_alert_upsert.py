import json
import os
import pathlib
import subprocess
import time

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = str(ROOT / ".github/workflows/grafana-alert.yml")
CONTACTS = ROOT / "config/grafana/provisioning/alerting/cloudflare-spend-contact.yaml"
STEP = ".jobs.upsert.steps[0]"
NOW = int(time.time())
DAY = 86400
UID = "ppi-cline"


def _y(expr, path=WORKFLOW):
    out = subprocess.run(["yq", expr, path], check=True, capture_output=True, text=True).stdout
    assert out.strip() and out.strip() != "null", expr
    return out


def _iso(ts):
    return subprocess.run(["date", "-u", "-d", f"@{ts}", "+%Y-%m-%dT%H:%M:%SZ"], check=True, capture_output=True, text=True).stdout.strip()


def payload(status="firing", uid=UID, kind="generic", **extra):
    p = {"kind": kind, "status": status, "title": "grafana alert: Cline idle", "summary": "Cline served zero fleet calls", "description": "Idle or missing.",
         "value": "", "threshold": "", "url": f"http://grafana/alerting/grafana/{uid}/view?orgId=1", "starts": "2026-10-16 03:00:00", "labels": {"plan": "cline"}}
    p.update(extra)
    return p


def decide(p, issues, uid=UID):
    out = subprocess.run(
        ["jq", "-c", _y(f"{STEP}.env.UPSERT")],
        input=json.dumps({"p": p, "uid": uid, "now": NOW, "issues": issues}), check=True, capture_output=True, text=True,
    ).stdout
    return json.loads(out)


def issue(number, uid=UID, state="OPEN", age=2 * DAY, comments=(), labels=("agent-ready",), author="app/github-actions"):
    return {
        "number": number, "state": state, "body": f"alert: {uid}\nalert-fired: {_iso(NOW - age)}\n\nbody",
        "author": {"login": author}, "labels": [{"name": n} for n in labels], "createdAt": _iso(NOW - age),
        "closedAt": None if state == "OPEN" else _iso(NOW - 60), "comments": list(comments),
    }


def refire(age):
    return {"body": f"alert-fired: {_iso(NOW - age)}\n\nStill firing", "createdAt": _iso(NOW - age)}


def test_firing_with_no_issue_creates_one_carrying_the_marker_first():
    v = decide(payload(), [])
    assert v["action"] == "create"
    assert v["body"].splitlines()[0] == f"alert: {UID}"
    assert v["body"].splitlines()[1].startswith("alert-fired: ")
    assert v["title"] == "grafana alert: Cline idle"
    assert v["labels"] == ["agent-ready"]


@pytest.mark.parametrize("kind,labels", [("generic", ["agent-ready"]), ("cost", ["agent-ready", "priority-now"]), ("deadrow", ["agent-ready", "priority-now"])])
def test_labels_follow_the_kind(kind, labels):
    assert decide(payload(kind=kind), [])["labels"] == labels


def test_the_dead_row_issue_keeps_the_ask_nish_instruction():
    assert "needs-nish-decision" in decide(payload(kind="deadrow"), [])["body"]


def test_another_rules_issue_or_a_uid_prefix_does_not_count():
    assert decide(payload(), [issue(5, uid="ppi-other"), issue(6, uid=UID + "x")])["action"] == "create"


def test_firing_with_an_open_issue_within_a_day_does_nothing():
    v = decide(payload(), [issue(7, age=3600)])
    assert (v["action"], v["issues"]) == ("none", [7])


def test_firing_with_an_open_issue_older_than_a_day_comments_once():
    v = decide(payload(), [issue(7, age=2 * DAY)])
    assert (v["action"], v["issues"]) == ("comment", [7])
    assert v["comment"].splitlines()[0].startswith("alert-fired: ")


def test_a_refire_comment_resets_the_daily_clock():
    assert decide(payload(), [issue(7, age=5 * DAY, comments=[refire(3600)])])["action"] == "none"
    assert decide(payload(), [issue(7, age=5 * DAY, comments=[refire(2 * DAY)])])["action"] == "comment"


def test_two_open_issues_for_one_rule_use_the_oldest_and_never_a_third():
    v = decide(payload(), [issue(9, age=3600), issue(4, age=3 * DAY)])
    assert (v["action"], v["issues"]) == ("comment", [4])


def test_a_closed_issue_does_not_block_a_new_one():
    assert decide(payload(), [issue(3, state="CLOSED")])["action"] == "create"


def test_resolved_closes_the_open_issue():
    v = decide(payload(status="resolved"), [issue(7)])
    assert (v["action"], v["issues"]) == ("close", [7])


def test_resolved_leaves_an_issue_a_worker_is_on():
    v = decide(payload(status="resolved"), [issue(7, labels=("agent-ready", "agent-in-progress"))])
    assert v["action"] == "none"


def test_resolved_with_nothing_open_does_nothing():
    assert decide(payload(status="resolved"), [issue(3, state="CLOSED")])["action"] == "none"


def test_an_unknown_status_does_nothing():
    assert decide(payload(status="pending"), [])["action"] == "none"


def test_the_title_is_one_clean_line():
    v = decide(payload(title="  line one\nline two  "), [])
    assert v["title"] == "line one line two"


def test_workflow_is_triggered_only_by_the_dispatch_and_holds_only_issue_write():
    assert _y(".on.repository_dispatch.types[0]").strip() == "grafana-alert"
    assert _y(".on | keys | length").strip() == "1"
    assert dict(l.split(": ") for l in _y(".jobs.upsert.permissions").strip().splitlines()) == {"issues": "write"}
    assert _y(".permissions | length").strip() == "0"
    assert _y(f"{STEP}.env.GH_TOKEN").strip() == "${{ github.token }}"
    assert "${{" not in _y(f"{STEP}.run")


def test_every_dispatch_contact_point_posts_the_ten_keys_the_dispatch_api_allows():
    import re
    import yaml
    doc = yaml.safe_load(CONTACTS.read_text())
    points = {c["name"]: c["receivers"][0] for c in doc["contactPoints"] if c["name"].endswith("-dispatch")}
    assert set(points) == {"cloudflare-spend-dispatch", "router-dead-row-dispatch", "fleet-alert-dispatch"}
    for name, r in points.items():
        assert r["disableResolveMessage"] is False, name
        assert r["settings"]["url"] == "https://api.github.com/repos/Nishfleet/fleet-ops/dispatches"
        tpl = r["settings"]["payload"]["template"]
        assert '"event_type" "grafana-alert"' in tpl
        keys = re.findall(r'"([a-z_]+)" ', tpl.split("(coll.Dict ", 1)[1])
        top = [k for k in keys if k in {"kind", "status", "title", "summary", "description", "value", "threshold", "url", "starts", "labels"}]
        assert sorted(top) == sorted({"kind", "status", "title", "summary", "description", "value", "threshold", "url", "starts", "labels"}), name
        assert "$" not in tpl


FAKE_GH = """#!/bin/sh
d=$FAKE_DIR
case "$1 $2" in
  "issue list") cat "$d/issues.json" ;;
  *) printf '%s\\n' "$*" >> "$d/writes.log" ;;
esac
"""


def run_block(tmp_path, p, issues):
    fake = tmp_path / "fake"
    fake.mkdir()
    (fake / "issues.json").write_text(json.dumps(issues))
    gh = fake / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    env = {
        "PATH": f"{fake}:{os.environ['PATH']}", "FAKE_DIR": str(fake), "GITHUB_REPOSITORY": "o/r", "RUNNER_TEMP": str(tmp_path),
        "PAYLOAD": json.dumps(p), "UPSERT": _y(f"{STEP}.env.UPSERT"), "GH_TOKEN": "x",
    }
    r = subprocess.run(["bash", "-c", _y(f"{STEP}.run")], env=env, capture_output=True, text=True)
    log = (fake / "writes.log").read_text().splitlines() if (fake / "writes.log").exists() else []
    return r, log


def test_run_block_creates_comments_and_closes_through_gh(tmp_path):
    (tmp_path / "a").mkdir()
    r, log = run_block(tmp_path / "a", payload(), [])
    assert r.returncode == 0, r.stderr
    assert len(log) == 1 and log[0].startswith("issue create -R o/r --label agent-ready --title grafana alert: Cline idle --body-file ")
    assert (tmp_path / "a" / "body.md").read_text().splitlines()[0] == f"alert: {UID}"
    (tmp_path / "b").mkdir()
    r, log = run_block(tmp_path / "b", payload(), [issue(7)])
    assert r.returncode == 0, r.stderr
    assert len(log) == 1 and log[0].startswith("issue comment 7 -R o/r --body-file ")
    (tmp_path / "c").mkdir()
    r, log = run_block(tmp_path / "c", payload(status="resolved"), [issue(7)])
    assert r.returncode == 0, r.stderr
    assert len(log) == 1 and log[0].startswith("issue close 7 -R o/r -r completed -c ")


def test_run_block_refuses_a_dispatch_without_a_rule_uid(tmp_path):
    r, log = run_block(tmp_path, payload(url="http://grafana/elsewhere"), [])
    assert r.returncode != 0 and log == []
    assert "no rule uid" in r.stdout
