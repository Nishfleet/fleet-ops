"""agent.yml's "Start the next ready issue" step (fleet-ops#10685): its real `run:` block
(read out with yq) against a fake gh and pgrep.

One worker exit starts one ready item per free lane, not one. A Gate skip other than
lanes-full refills too but pokes no sweep, so skips cannot chain sweeps.
"""
import json
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent.yml")
STEP = '.jobs.work.steps[] | select(.name == "Start the next ready issue")'

FAKE_GH = r"""#!/usr/bin/env bash
case "$1 $2" in
  "issue list") jq -r '.[].number' "$FAKE_DIR/ready.json" ;;  # already in the step's priority order
  "api repos/o/r/actions/workflows/"*) ;;
  "api repos/o/r/issues/"*) jq --arg n "${2#repos/o/r/issues/}" '.[] | select((.number | tostring) == $n)' "$FAKE_DIR/ready.json" ;;
  "issue edit"|"workflow run") echo "$*" >> "$FAKE_DIR/writes.log" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""

# One bwrap line per live worker of each engine, from LIVE_<engine>.
FAKE_PGREP = r"""#!/usr/bin/env bash
e=$(sed -E 's/.* -- ([a-z-]+) .*/\1/' <<<"$3")
var=LIVE_${e//-/_}
for ((k = 0; k < ${!var:-0}; k++)); do echo "1 bwrap x -- $e agent-worktrees/issue-$e-$k"; done
"""


def run(tmp_path, ready, slots, live=None, exited="true"):
    (tmp_path / "ready.json").write_text(json.dumps([
        {"number": n, "title": f"t{n}", "labels": [{"name": l} for l in labels],
         "issue_dependencies_summary": {"blocked_by": 0}} for n, labels in ready]))
    cfg = tmp_path / ".config/fleet-ops"
    cfg.mkdir(parents=True, exist_ok=True)
    (cfg / "litellm-proxy.yaml").write_text(json.dumps({"model_list": [
        {"model_name": "worker-capable", "litellm_params": {"max_parallel_requests": slots}}]}))
    clone = tmp_path / "workspaces/tooling/fleet-ops-deploy-clone/config"
    clone.mkdir(parents=True, exist_ok=True)
    (clone / "intake-repos.json").write_text(json.dumps({"repos": [{"name": "r"}, {"name": "other"}]}))
    for name, body in (("gh", FAKE_GH), ("pgrep", FAKE_PGREP)):
        f = tmp_path / name
        f.write_text(body)
        f.chmod(0o755)
    script = subprocess.run(["yq", f"{STEP} | .run", WF], check=True, capture_output=True, text=True).stdout
    env = {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path),
           "HOME": str(tmp_path), "REPO": "o/r", "REF": "claim/issue-1", "GH_TOKEN": "x", "EXITED": exited,
           **{f"LIVE_{k}": str(v) for k, v in (live or {}).items()}}
    out = subprocess.run(["bash", "-e", "-c", script], env=env, capture_output=True, text=True, timeout=60)
    assert out.returncode == 0, out.stderr
    log = tmp_path / "writes.log"
    writes = log.read_text().splitlines() if log.exists() else []
    return [w.split()[2] for w in writes if "--add-label agent-ready" in w], [w for w in writes if w.startswith("workflow run")]


def test_ten_free_lanes_start_ten_of_twelve(tmp_path):
    # 4 + 2 + 4 = 10 free regular lanes; #1 is the exiting issue and never re-labelled.
    started, sweeps = run(tmp_path, [(n, ()) for n in range(1, 14)], slots=4)
    assert started == [str(n) for n in range(2, 12)]
    assert sweeps == []  # every lane taken here: no other repo's sweep


def test_full_lanes_start_nothing_regular(tmp_path):
    started, sweeps = run(tmp_path, [(n, ()) for n in range(2, 6)], slots=4,
                          live={"devin": 4, "opencode": 2, "pi": 4})
    assert started == []
    assert sweeps == ["workflow run agent-dispatch.yml -R o/r", "workflow run agent-dispatch.yml -R o/other"]


def test_strong_only_takes_one_while_regular_full(tmp_path):
    started, _ = run(tmp_path, [(2, ("strong-only",)), (3, ("strong-only",)), (4, ())], slots=4,
                     live={"devin": 4, "opencode": 2, "pi": 4})
    assert started == ["2"]


def test_lanes_left_sweep_other_repos_only(tmp_path):
    started, sweeps = run(tmp_path, [(2, ()), (3, ("needs-orchestrator",))], slots=4)
    assert started == ["2"]
    assert sweeps == ["workflow run agent-dispatch.yml -R o/other"]


def test_skip_refills_but_pokes_no_sweep(tmp_path):
    started, sweeps = run(tmp_path, [(n, ()) for n in range(2, 5)], slots=4, exited="false")
    assert started == ["2", "3", "4"]
    assert sweeps == []


def test_step_runs_on_a_non_lanes_full_skip():
    cond = subprocess.run(["yq", f"{STEP} | .if", WF], check=True, capture_output=True, text=True).stdout
    assert "steps.gate.outputs.skip != 'lanes-full'" in cond
    assert "-miss-review" in cond
