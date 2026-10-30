"""GitHub "blocked by" in the coordinator path (fleet-ops#10489) and the idle-runners
alert's dependency gate (fleet-ops#11094): the real `run:` blocks of agent-dispatch.yml
against a fake gh.

The orchestrate issue step skips a blocked issue. When an issue closes, the list job
re-labels each unblocked needs-orchestrator dependent (remove, then add, on the runner
login). The scheduled sweep reads its ready set off the advanced search endpoint with
`-is:blocked`, the only GitHub search that filters issue dependencies, so a
dependency-blocked agent-ready issue never enters the sweep. The idle-runners alert's
data source (uid fleet-github) cannot run an advanced search, so the requeue step
(scheduled sweeps only) keeps the agent-blocked-dep label in step for that query alone:
add needs agent-ready with an open blocked-by and no label, remove needs the label
without a blocked-by. The sync writes run on the job token, so they fire no event.
"""
import json
import os
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent-dispatch.yml")
ALERT = ROOT / "config/grafana/provisioning/alerting/fleet-scorecard.yaml"
ISSUE_STEP = '.jobs.orchestrate.steps[] | select(.id == "issue")'
LIST_STEP = '.jobs.list.steps[] | select(.id == "list")'
MIRROR_STEP = '.jobs.list.steps[] | select(.env.REQUEUE) | .run'

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
  *'search/issues?advanced_search'*)
    case "$*" in
      *'label%3Aagent-blocked-dep'*) jq -c "$q" "$FAKE_DIR/rem.json" ;;
      *'+is%3Ablocked'*) jq -c "$q" "$FAKE_DIR/add.json" ;;
      *'-is%3Ablocked'*) jq -c "$q" "$FAKE_DIR/nums.json" ;;
      *) echo "fake gh: search without a blocked qualifier: $*" >&2; exit 99 ;;
    esac ;;
  *actions/workflows/*) echo '{"workflow_runs":[]}' | jq -c "$q" ;;
  *actions/runs/*) echo '{"jobs":[]}' | jq -c "$q" ;;
  "api repos/o/r/issues/"*) n=${2##*/}; jq -r "$q" "$FAKE_DIR/issue-$n.json" 2>/dev/null || jq -r "$q" "$FAKE_DIR/issue.json" ;;
  "pr list"*) echo '[]' ;;
  "issue list"*) echo '[]' ;;
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


def _run(run, env, tmp_path):
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", run],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    log = tmp_path / "writes.log"
    return (log.read_text().splitlines() if log.exists() else []), r.stdout


def orchestrate(tmp_path, blocked_by):
    (tmp_path / "issue.json").write_text(json.dumps({
        "state": "OPEN", "labels": [{"name": "needs-orchestrator"}],
        "issue_dependencies_summary": {"blocked_by": blocked_by}}))
    (tmp_path / "out").write_text("")
    env = {**_fake(tmp_path), "REPO": "o/r", "ISSUE": "5", "GH_TOKEN": "x", "GITHUB_SERVER_URL": "https://github.com",
           "GITHUB_RUN_ID": "1", "GITHUB_OUTPUT": str(tmp_path / "out"), "DAILY_MAX": "5"}
    return _run(_y(f"{ISSUE_STEP} | .run"), env, tmp_path)


def test_blocked_issue_is_skipped_and_says_so(tmp_path):
    _, out = orchestrate(tmp_path, blocked_by=1)
    assert "blocked" in out and "go=true" not in (tmp_path / "out").read_text()


def test_unblocked_issue_still_goes(tmp_path):
    orchestrate(tmp_path, blocked_by=0)
    assert "go=true" in (tmp_path / "out").read_text()


def _step_env(tmp_path, extra):
    return {**_fake(tmp_path), "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "x", "GITHUB_OUTPUT": str(tmp_path / "out"),
            "WORKFLOW_REF": "o/r/.github/workflows/agent-dispatch.yml@refs/heads/main", "CHECK_DEFS": "",
            "RUN_LIVE_JQ": "", **extra}


def close(tmp_path, dependents):
    """Run the list step for a closed issue 1 that blocks `dependents` ({n: (labels, blocked_by)})."""
    env = _step_env(tmp_path, {"GH_TOKEN": "x", "CLOSED": "1", "ISSUE": ""})
    (tmp_path / "blocking.json").write_text(json.dumps([{"number": n, "state": "open"} for n in dependents]))
    for n, (labels, blocked_by) in dependents.items():
        (tmp_path / f"issue-{n}.json").write_text(json.dumps({
            "number": n, "state": "open", "created_at": "2026-10-27T00:00:00Z",
            "labels": [{"name": l} for l in labels],
            "issue_dependencies_summary": {"blocked_by": blocked_by}}))
    return _run(_y(f"{LIST_STEP} | .run"), env, tmp_path)


def sweep(tmp_path, ready):
    """Run the list step as the scheduled sweep: `ready` is {n: (labels, blocked_by)}. The list step
    carries no label sync any more (the requeue step owns the agent-blocked-dep mirror)."""
    for n, (labels, blocked_by) in ready.items():
        issue = {"number": n, "state": "open", "created_at": "2026-10-27T00:00:00Z",
                 "labels": [{"name": l} for l in labels]}
        if blocked_by is not None:
            issue["issue_dependencies_summary"] = {"blocked_by": blocked_by}
        (tmp_path / f"issue-{n}.json").write_text(json.dumps(issue))
    (tmp_path / "nums.json").write_text(json.dumps({"items": [{"number": n} for n in ready]}))
    return _run(_y(f"{LIST_STEP} | .run"), _step_env(tmp_path, {"GH_TOKEN": "x", "CLOSED": "", "ISSUE": ""}), tmp_path)


def mirror(tmp_path, add=(), rem=(), extra=None):
    """Run the requeue step: `add` and `rem` are the (number, labels) items the two
    advanced searches return when read for the agent-blocked-dep mirror."""
    for n, labels in list(add) + list(rem):
        (tmp_path / f"issue-{n}.json").write_text(json.dumps({
            "number": n, "state": "open", "created_at": "2026-10-27T00:00:00Z",
            "labels": [{"name": l} for l in labels]}))
    (tmp_path / "add.json").write_text(json.dumps({"items": [{"number": n, "labels": [{"name": l} for l in ls]} for n, ls in add]}))
    (tmp_path / "rem.json").write_text(json.dumps({"items": [{"number": n} for n, _ in rem]}))
    return _run(_y(MIRROR_STEP), _step_env(tmp_path, {"GH_TOKEN": "x", "REQUEUE": "[] | .[]", **(extra or {})}), tmp_path)


def test_closing_a_blocker_refires_the_unblocked_dependent(tmp_path):
    w, _ = close(tmp_path, {2: (["needs-orchestrator"], 0)})
    assert [l.split("|")[0] for l in w] == [
        "issue edit 2 -R o/r --remove-label needs-orchestrator",
        "issue edit 2 -R o/r --add-label needs-orchestrator"]
    assert all(l.endswith("token=none") for l in w), "the re-fire must run on the runner login, not the job token"


def test_still_blocked_or_unparked_dependents_are_left_alone(tmp_path):
    w, _ = close(tmp_path, {2: (["needs-orchestrator"], 1), 3: (["agent-ready"], 0)})
    assert w == []


def test_the_sweep_reads_its_ready_set_off_the_advanced_endpoint(tmp_path):
    sweep(tmp_path, {3: (["agent-ready"], 0)})
    assert "claim/issue-3" in (tmp_path / "out").read_text()
    wf = pathlib.Path(WF).read_text()
    read = re.search(r"nums=\$\(gh api \"search/issues\?advanced_search=true&per_page=100&q=([^\"]*)\"", wf)
    assert read, "the sweep must read its ready set off the advanced search endpoint"
    assert "-is%3Ablocked" in read.group(1) and "label%3Aagent-ready" in read.group(1), \
        "the ready-set read must exclude dependency-blocked issues at the search"
    assert ".issue_dependencies_summary.blocked_by == 0" in wf, \
        "the queue gate stays on the dependency summary, never on the mirror label"


def test_the_mirror_follows_its_two_searches(tmp_path):
    w, _ = mirror(tmp_path, add=[(2, ["agent-ready"]), (4, ["agent-ready", "agent-blocked-dep"])], rem=[(7, []), (8, [])])
    assert [l.split("|")[0] for l in w if l.startswith("issue edit")] == [
        "issue edit 2 -R o/r --add-label agent-blocked-dep",
        "issue edit 7 -R o/r --remove-label agent-blocked-dep",
        "issue edit 8 -R o/r --remove-label agent-blocked-dep"], "an already-labeled issue gets no second write"
    assert all(l.endswith("token=x") for l in w), "the sync write is the job token: it fires no run"
    synced = re.findall(r"q=repo%3A\$\{GITHUB_REPOSITORY//\\//%2F\}\+is%3Aissue\+is%3Aopen\+label%3A[^\"]*", _y(MIRROR_STEP))
    assert "q=repo%3A${GITHUB_REPOSITORY//\\//%2F}+is%3Aissue+is%3Aopen+label%3Aagent-ready+is%3Ablocked" in synced and \
        "q=repo%3A${GITHUB_REPOSITORY//\\//%2F}+is%3Aissue+is%3Aopen+label%3Aagent-blocked-dep+-is%3Ablocked" in synced, \
        "the mirror reads its two sets off the same advanced endpoint"


def test_the_dep_label_create_runs_at_most_once_a_sweep(tmp_path):
    w, _ = mirror(tmp_path, add=[(2, ["agent-ready"]), (9, ["agent-ready"])])
    creates = [l.split("|")[0] for l in w if l.startswith("label create")]
    assert creates == ["label create agent-blocked-dep"], "one create a sweep, not one per changed issue"


def test_a_refused_sync_edit_surfaces_the_warning(tmp_path):
    _, out = mirror(tmp_path, add=[(2, ["agent-ready"])], extra={"FAIL_EDIT": "agent-blocked-dep"})
    assert "::warning::#2: agent-blocked-dep add refused" in out, \
        "a refused sync write must surface on the ::warning, not vanish into a swallowed exit"


def test_the_alert_excludes_the_label_the_sweep_carries():
    query = re.search(r'query: "(org:Nishfleet is:issue label:agent-ready[^"]*)"', ALERT.read_text()).group(1)
    assert "-label:agent-blocked-dep" in query.split()
    assert "-label:needs-split" not in query.split() and "-label:epic" not in query.split(), \
        "the new scope carries the dependency gate alone; the park labels stay out of the alert query"
    assert "agent-blocked-dep" in pathlib.Path(WF).read_text()


def test_the_syncs_no_event_claim_is_a_property_of_the_workflow():
    assert _y('.jobs.list.steps[] | select(.id == "list") | .env.GH_TOKEN').strip() == "${{ github.token }}"
    assert _y('.jobs.list.steps[] | select(.env.REQUEUE) | .env.GH_TOKEN').strip() == "${{ github.token }}"
