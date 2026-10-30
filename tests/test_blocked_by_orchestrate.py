"""GitHub "blocked by" in the coordinator path (fleet-ops#10489): the real `run:` blocks of
agent-dispatch.yml against a fake gh.

The orchestrate issue step skips a blocked issue. When an issue closes, the list job
re-labels each unblocked needs-orchestrator dependent (remove, then add, on the runner login).
The list job also carries the blocked_by gate on an agent-blocked-dep label the idle-runners
scorecard alert excludes (fleet-ops#11094): no search qualifier reaches the dependency summary.
A missing summary counts as unblocked (the Gate's `// 0`), so the alert keeps counting an
unread issue; the sync writes run on the job token, so they fire no event.
"""
import json
import os
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent-dispatch.yml")
ISSUE_STEP = '.jobs.orchestrate.steps[] | select(.id == "issue")'
LIST_STEP = '.jobs.list.steps[] | select(.id == "list")'

FAKE_GH = r"""#!/usr/bin/env bash
q=.; for ((i = 1; i <= $#; i++)); do [ "${!i}" = --jq ] && { j=$((i + 1)); q=${!j}; }; done
case "$*" in
  "issue edit"*) if [ -n "$FAIL_EDIT" ] && [[ "$*" == *"$FAIL_EDIT"* ]]; then exit 1; else echo "$*|token=${GH_TOKEN:-none}" >> "$FAKE_DIR/writes.log"; fi ;;
  "label create"*) echo "label create $3|token=${GH_TOKEN:-none}" >> "$FAKE_DIR/writes.log" ;;
  "issue view"*) jq -r "$q" "$FAKE_DIR/issue.json" ;;
  *"/dependencies/blocking"*) jq -r "$q" "$FAKE_DIR/blocking.json" ;;
  *"/parent"*) exit 1 ;;
  *git/ref/heads/*) exit 1 ;;
  "issue comment"*) ;;
  *issues/comments*) echo '[]' | jq -c "$q" ;;
  *" -S no:label"* | *" -l agent-in-progress"*) echo '[]' ;;
  "pr list"*) echo '[]' ;;
  "issue list"*) [ -f "$FAKE_DIR/list.json" ] && jq -r "$q" "$FAKE_DIR/list.json" ;;
  "api repos/o/r/issues/"*) n=${2##*/}; jq -r "$q" "$FAKE_DIR/issue-$n.json" 2>/dev/null || jq -r "$q" "$FAKE_DIR/issue.json" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 99 ;;
esac
"""


def _y(expr):
    return subprocess.run(["yq", expr, WF], check=True, capture_output=True, text=True).stdout


def _fake(tmp_path):
    gh = tmp_path / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    return {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path)}


def orchestrate(tmp_path, blocked_by):
    (tmp_path / "issue.json").write_text(json.dumps({
        "state": "OPEN", "labels": [{"name": "needs-orchestrator"}],
        "issue_dependencies_summary": {"blocked_by": blocked_by}}))
    (tmp_path / "out").write_text("")
    env = {**_fake(tmp_path), "REPO": "o/r", "ISSUE": "5", "GH_TOKEN": "x", "GITHUB_SERVER_URL": "https://github.com",
           "GITHUB_RUN_ID": "1", "GITHUB_OUTPUT": str(tmp_path / "out"), "DAILY_MAX": "5"}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{ISSUE_STEP} | .run")],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout, (tmp_path / "out").read_text()


def test_blocked_issue_is_skipped_and_says_so(tmp_path):
    log, out = orchestrate(tmp_path, blocked_by=1)
    assert "blocked" in log and "go=true" not in out


def test_unblocked_issue_still_goes(tmp_path):
    _, out = orchestrate(tmp_path, blocked_by=0)
    assert "go=true" in out


def _issues(tmp_path, dependents):
    for n, (labels, blocked_by) in dependents.items():
        issue = {"number": n, "state": "open", "created_at": "2026-10-27T00:00:00Z",
                 "labels": [{"name": l} for l in labels]}
        if blocked_by is not None:
            issue["issue_dependencies_summary"] = {"blocked_by": blocked_by}
        (tmp_path / f"issue-{n}.json").write_text(json.dumps(issue))


def _run_list(tmp_path, env):
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{LIST_STEP} | .run")],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    log = tmp_path / "writes.log"
    return log.read_text().splitlines() if log.exists() else []


def close(tmp_path, dependents):
    """Run the list step for a closed issue 1 that blocks `dependents` ({n: (labels, blocked_by)})."""
    (tmp_path / "blocking.json").write_text(json.dumps([{"number": n, "state": "open"} for n in dependents]))
    _issues(tmp_path, dependents)
    (tmp_path / "out").write_text("")
    env = {**_fake(tmp_path), "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "x", "CLOSED": "1", "ISSUE": "",
           "GITHUB_OUTPUT": str(tmp_path / "out"), "CHECK_DEFS": "", "RUN_LIVE_JQ": ""}
    return _run_list(tmp_path, env)


def sweep(tmp_path, dependents):
    """Run the list step as the scheduled sweep over `dependents` ({n: (labels, blocked_by)})."""
    (tmp_path / "list.json").write_text(json.dumps([{"number": n} for n in dependents]))
    _issues(tmp_path, dependents)
    (tmp_path / "out").write_text("")
    env = {**_fake(tmp_path), "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "x", "CLOSED": "", "ISSUE": "",
           "GITHUB_OUTPUT": str(tmp_path / "out"), "CHECK_DEFS": "", "RUN_LIVE_JQ": ""}
    return _run_list(tmp_path, env)


def test_closing_a_blocker_refires_the_unblocked_dependent(tmp_path):
    w = close(tmp_path, {2: (["needs-orchestrator"], 0)})
    assert [l.split("|")[0] for l in w] == [
        "issue edit 2 -R o/r --remove-label needs-orchestrator",
        "issue edit 2 -R o/r --add-label needs-orchestrator"]
    assert all(l.endswith("token=none") for l in w), "the re-fire must run on the runner login, not the job token"


def test_still_blocked_or_unparked_dependents_are_left_alone(tmp_path):
    w = close(tmp_path, {2: (["needs-orchestrator"], 1), 3: (["agent-ready"], 0)})
    assert w == []


def test_dependency_blocked_ready_issues_carry_the_dep_label_the_alert_excludes(tmp_path):
    w = close(tmp_path, {2: (["agent-ready"], 1),
                         3: (["agent-ready", "agent-blocked-dep"], 1),
                         4: (["agent-ready", "agent-blocked-dep"], 0),
                         5: (["agent-ready"], None)})
    raw = [l for l in w if "agent-blocked-dep" in l and (l.startswith("issue edit") or l.startswith("label create"))]
    sync = [l.split("|")[0] for l in raw if l.startswith("issue edit")]
    assert sync == [
        "issue edit 2 -R o/r --add-label agent-blocked-dep",
        "issue edit 4 -R o/r --remove-label agent-blocked-dep"]
    assert all(l.endswith("token=x") for l in raw), "the sync write is the job token: it fires no run"


def test_the_alert_excludes_the_label_the_sweep_carries():
    yml = (ROOT / "config/grafana/provisioning/alerting/fleet-scorecard.yaml").read_text()
    query = re.search(r'query: "(org:Nishfleet is:issue label:agent-ready[^"]*)"', yml).group(1)
    wanted = {"-label:agent-blocked-dep", "-label:needs-split", "-label:epic"}
    assert wanted <= set(query.split()), "the query must carry the whole exclusion set, not just one qualifier"
    assert "agent-blocked-dep" in pathlib.Path(WF).read_text()


def test_the_syncs_no_event_claim_is_a_property_of_the_workflow():
    assert _y(f"{LIST_STEP} | .env.GH_TOKEN").strip() == "${{ github.token }}"


def test_scheduled_sweep_syncs_the_dep_label_without_gating_the_queue(tmp_path):
    w = sweep(tmp_path, {2: (["agent-ready"], 1), 3: (["agent-ready", "agent-blocked-dep"], 0)})
    raw = [l for l in w if "agent-blocked-dep" in l and (l.startswith("issue edit") or l.startswith("label create"))]
    sync = [l.split("|")[0] for l in raw if l.startswith("issue edit")]
    assert sync == [
        "issue edit 2 -R o/r --add-label agent-blocked-dep",
        "issue edit 3 -R o/r --remove-label agent-blocked-dep"]
    assert all(l.endswith("token=x") for l in raw), "the sync write is the job token: it fires no run"
    assert "claim/issue-3" in (tmp_path / "out").read_text(), "the label never gates the queue; blocked_by does"


def test_the_dep_label_create_runs_at_most_once_a_sweep(tmp_path):
    w = sweep(tmp_path, {2: (["agent-ready"], 1), 3: (["agent-ready"], 2), 4: (["agent-ready"], 3)})
    creates = [l.split("|")[0] for l in w if l.startswith("label create")]
    assert creates == ["label create agent-blocked-dep"], \
        "one create a sweep, not one per changed issue"


def test_a_refused_dep_edit_surfaces_the_warning(tmp_path):
    (tmp_path / "list.json").write_text(json.dumps([{"number": 2}]))
    (tmp_path / "issue-2.json").write_text(json.dumps({
        "number": 2, "state": "open", "created_at": "2026-10-27T00:00:00Z",
        "labels": [{"name": "agent-ready"}, {"name": "agent-blocked-dep"}],
        "issue_dependencies_summary": {"blocked_by": 0}}))
    (tmp_path / "out").write_text("")
    env = {**_fake(tmp_path), "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "x", "CLOSED": "", "ISSUE": "",
           "GITHUB_OUTPUT": str(tmp_path / "out"), "CHECK_DEFS": "", "RUN_LIVE_JQ": "", "FAIL_EDIT": "agent-blocked-dep"}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{LIST_STEP} | .run")],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "::warning::#2: agent-blocked-dep remove refused" in r.stdout, \
        "a refused sync write must surface on the ::warning, not vanish into a swallowed exit"
