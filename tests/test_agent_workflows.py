"""The shapes three control-flow steps must keep (fleet-ops#9278).

The arm step carried its own path allowlist, which drifted from
config/risky-paths.json, the list hold-risky already reads; it now classifies the
claim PR with the one list and the one CLASSIFY program, both read from
fleet-ops main by URL the way hold-risky reads them, holds a claim PR the
classifier calls risky (labeled needs-coordinator, not armed), and holds when a
read of the rules, the list or the diff fails. The fake gh serves a changed-files
read and the fake curl serves the checkout's rules and list, so the step runs
against the real program and list. The start-next step toggled agent-ready, and
the run the second label event started displaced the run the first one started,
so it dispatches the issue by number. A close stripped the closed issue's labels
and left an agent-blocked dependent parked with no event left to free it, so it
requeues a dependent that has no open blocker and no other recorded reason. The
review job's session pin is here too: without it a held PR gets no review to
clear it (fleet-ops#9428).
"""
import json
import os
import pathlib
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
AGENT = ROOT / ".github/workflows/agent.yml"
DISPATCH = ROOT / ".github/workflows/agent-dispatch.yml"

ARM = '.jobs.work.steps[] | select(.name == "Arm auto-merge as the App") | .run'

FAKE_CURL = """#!/usr/bin/env bash
case "$*" in
  *"agent-dispatch.yml"*) [ -n "$CURL_RULES_BROKEN" ] && { echo "fake curl: rules broken"; exit 1; }; cat "$ROOT/.github/workflows/agent-dispatch.yml" ;;
  *"risky-paths.json"*) [ -n "$CURL_LIST_BROKEN" ] && { echo "fake curl: list broken"; exit 1; }; cat "$ROOT/config/risky-paths.json" ;;
  *) echo "fake curl: unexpected call: $*" >&2; exit 1 ;;
esac
"""

FAKE_GH = """#!/usr/bin/env bash
case "$*" in
  *"--json state --jq .state"*) echo OPEN ;;
  *"--json body --jq .body"*) echo 'Closes #1' ;;
  *"--json number --jq .number"*) echo 7 ;;
  *"--json labels,changedFiles"*) echo '{"labels":[],"changedFiles":1}' ;;
  *"pulls/"*"/files"*) [ -n "$GH_DIFF_BROKEN" ] && { echo "fake gh: diff broken"; exit 1; }; cat "$STATE/files.json" ;;
  "label create "*) ;;
  *"--add-label needs-coordinator"*) touch "$STATE/labeled" ;;
  *"pr checks "*"--required"*) [ -z "$RED" ] || { echo "$RED"; exit 1; } ; exit 8 ;;
  *"pr checks "*) exit 8 ;;
  *"--auto --squash"*) touch "$STATE/armed" ;;
  *"--disable-auto"*) touch "$STATE/disarmed" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""


def step(path, expr):
    done = subprocess.run(["yq", expr, str(path)], capture_output=True, text=True, timeout=120)
    assert done.returncode == 0 and done.stdout.strip() not in ("", "null"), f"{path.name}: {expr} found no step"
    return done.stdout


@pytest.fixture(scope="module")
def arm(tmp_path_factory):
    script = tmp_path_factory.mktemp("arm") / "arm.sh"
    script.write_text(step(AGENT, ARM))
    bindir = tmp_path_factory.mktemp("bin")
    (bindir / "gh").write_text(FAKE_GH)
    (bindir / "gh").chmod(0o755)
    (bindir / "curl").write_text(FAKE_CURL)
    (bindir / "curl").chmod(0o755)

    def run(tmp_path, red="", files=None, broken=None):
        state = tmp_path / "state"
        state.mkdir(parents=True, exist_ok=True)
        temp = tmp_path / "temp"
        temp.mkdir(parents=True, exist_ok=True)
        (state / "files.json").write_text("\n".join(json.dumps(f) for f in
            (files if files is not None else
             [{"f": "app/routes/a.tsx", "p": None, "patch": "@@ -1 +1 @@\n+x"}])) + "\n")
        env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}", STATE=str(state), ROOT=str(ROOT),
                   RUNNER_TEMP=str(temp), REPO="Nishfleet/drive", REF="claim/issue-1", GH_TOKEN="fake",
                   RED=red, CURL_RULES_BROKEN="yes" if broken == "rules" else "",
                   CURL_LIST_BROKEN="yes" if broken == "list" else "",
                   GH_DIFF_BROKEN="yes" if broken == "diff" else "",
                   RISKY_RULES_URL="https://raw.ci/agent-dispatch.yml",
                   RISKY_PATHS_URL="https://raw.ci/risky-paths.json")
        done = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", str(script)],
                              env=env, capture_output=True, text=True, timeout=120)
        return done, state

    return run


def test_the_arm_step_arms_with_pending_or_green_checks_only(arm, tmp_path):
    done, state = arm(tmp_path)
    assert done.returncode == 0, done.stdout + done.stderr
    assert (state / "armed").exists(), done.stdout
    assert not (state / "disarmed").exists(), done.stdout


def test_a_red_required_check_disarms_and_fails_the_step(arm, tmp_path):
    done, state = arm(tmp_path, red="ci")
    assert done.returncode == 1, done.stdout + done.stderr
    assert (state / "disarmed").exists(), done.stdout
    assert not (state / "armed").exists(), done.stdout
    assert "not armed" in done.stdout + done.stderr


def test_a_risky_claim_pr_is_labeled_and_not_armed(arm, tmp_path):
    done, state = arm(tmp_path, files=[{"f": "app/credentials.ts", "p": None, "patch": "@@ -1 +1 @@\n+TOKEN"}])
    assert done.returncode == 0, done.stdout + done.stderr
    assert "not armed here" in done.stdout + done.stderr, done.stdout
    assert (state / "labeled").exists(), done.stdout
    assert not (state / "armed").exists(), done.stdout
    assert "not armed here" in done.stdout + done.stderr


def test_a_failed_read_holds_the_claim_pr(arm, tmp_path):
    for kind in ("rules", "list", "diff"):
        done, state = arm(tmp_path / kind, broken=kind)
        assert done.returncode == 0, f"{kind}: {done.stdout + done.stderr}"
        assert (tmp_path / kind / "state" / "labeled").exists(), f"{kind}: {done.stdout + done.stderr}"
        assert not (tmp_path / kind / "state" / "armed").exists(), f"{kind}: {done.stdout + done.stderr}"


def test_the_arm_step_keeps_no_path_list_of_its_own():
    run = step(AGENT, ARM)
    assert "$RISKY_PATHS_URL" in run and "$RISKY_RULES_URL" in run and "env.CLASSIFY" in run, (
        "the arm step does not classify with the one list and program before it arms")
    for gone in ("safe='^", "policy='^"):
        assert gone not in run, (
            f"the arm step carries a path list again ({gone}): config/risky-paths.json is the one source")


def test_the_start_next_step_dispatches_the_issue_it_picked():
    run = step(AGENT, '.jobs.work.steps[] | select(.name == "Start the next ready issue") | .run')
    assert "--remove-label agent-ready" not in run, (
        "the start-next step toggles agent-ready again: the second label event cancels the dispatch "
        "the first one started, so dispatch the issue by number")
    assert 'gh workflow run agent-dispatch.yml -R "$REPO" -f "issue=$n"' in run


CLOSE = ".jobs.close-claim.steps[0].run"

CLOSE_GH = r"""#!/usr/bin/env bash
set -u
slurp=0; expr=
for ((i=1;i<=$#;i++)); do
  a="${!i}"
  [ "$a" = --slurp ] && slurp=1
  if [ "$a" = --jq ]; then j=$((i+1)); expr="${!j}"; fi
done
case "$*" in
  *"/comments"*)
    if [ "$slurp" = 1 ]; then jq -r "$expr" "$STATE/comments-slurped.json"
    else for p in 1 2; do jq -r "$expr" "$STATE/comments-page.json"; done; fi ;;
  *"issue view"*"--json state"*) echo CLOSED ;;
  *"issue view"*) echo "" ;;
  *"/dependencies/blocking"*) cat "$STATE/deps" ;;
  *"/issues/"*) cat "$STATE/dependent-row" ;;
  *"issue edit"*) echo "$*" >> "$STATE/edits" ;;
  *"pr list"*) ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""


def _close(tmp_path, deps, row, page):
    tmp_path.mkdir(parents=True, exist_ok=True)
    script = tmp_path / "close.sh"
    script.write_text(step(DISPATCH, CLOSE))
    bindir = tmp_path / "bin"
    bindir.mkdir()
    (bindir / "gh").write_text(CLOSE_GH)
    (bindir / "gh").chmod(0o755)
    state = tmp_path / "state"
    state.mkdir()
    (state / "deps").write_text(deps)
    (state / "dependent-row").write_text(row)
    (state / "comments-page.json").write_text(json.dumps(page))
    (state / "comments-slurped.json").write_text(json.dumps([page, page]))
    env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}", STATE=str(state),
               GITHUB_REPOSITORY="Nishfleet/fleet-ops", ISSUE="1", GH_TOKEN="fake")
    done = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", str(script)],
                          env=env, capture_output=True, text=True, timeout=120)
    edits = (state / "edits").read_text() if (state / "edits").exists() else ""
    return done, edits


QUIET = [{"body": "worker: started"}, {"body": "worker: ran the tests"}]
PARKED = [{"body": "worker: started"}, {"body": "park: waiting on Nish"}]


def test_a_close_requeues_a_dependent_whose_only_block_was_the_closed_issue(tmp_path):
    done, edits = _close(tmp_path, "2\n", "0 true false", QUIET)
    assert done.returncode == 0, done.stdout + done.stderr
    assert "--remove-label agent-blocked --add-label agent-ready" in edits, (
        done.stdout + done.stderr + edits)


def test_a_close_keeps_a_dependent_that_records_its_own_park(tmp_path):
    done, edits = _close(tmp_path, "2\n", "0 true false", PARKED)
    assert done.returncode == 0, done.stdout + done.stderr
    assert "agent-ready" not in edits, edits


def test_a_close_keeps_a_dependent_with_an_open_blocker_or_a_decision_label(tmp_path):
    for row in ("1 true false", "0 true true", "0 false false"):
        done, edits = _close(tmp_path / row.replace(" ", "-"), "2\n", row, QUIET)
        assert done.returncode == 0, done.stdout + done.stderr
        assert "agent-ready" not in edits, (row, edits)


def test_the_review_job_names_its_router_session():
    done = subprocess.run(
        ["yq", '-e', '.jobs.review.env.FLEET_TASK_ID | test("^run-")', str(AGENT)],
        capture_output=True, text=True, timeout=120)
    assert done.returncode == 0, (
        "the review job sets no FLEET_TASK_ID, so its litellm call has no session id "
        "and a held PR never gets the review that clears it (fleet-ops#9428)")
