"""The arm-time hold in agent.yml (fleet-ops#10621): the work job's real "Arm auto-merge as the App" `run:` block
(read out with yq) against a fake gh and curl, with hold-risky never run.

coordinator-approval is a required check on fleet-ops only, so on a product repo this step is the guard: a risky PR
(hold-risky's own CLASSIFY on config/risky-paths.json) is labelled needs-coordinator and never armed. A green PR arms.
A failed read of the list or the program holds.
"""
import os
import pathlib
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
STEP = '.jobs.work.steps[] | select(.name == "Arm auto-merge as the App") | .run'

FAKE_GH = r"""#!/usr/bin/env bash
echo "$*" >> "$FAKE_DIR/gh.log"
case "$*" in
  "pr view "*"--json state "*) echo OPEN ;;
  "pr view "*"--json body "*) echo "Closes #7" ;;
  "pr view "*"--json number "*) echo 7 ;;
  "api --paginate repos/$REPO/pulls/7/files?per_page=100 "*) echo "{\"f\":\"$FAKE_FILE\",\"p\":null,\"patch\":\"@@ -1 +1 @@\\n+x\"}" ;;
  "api repos/$REPO/pulls/7") echo "{\"labels\":$FAKE_LABELS,\"changed_files\":1}" ;;
  "pr checks "*) ;;
  "pr merge "*|"label create "*|"pr edit "*) ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""

FAKE_CURL = r"""#!/usr/bin/env bash
[ -z "$FAIL_CURL" ] || exit 22
case "${@: -1}" in
  */main/config/risky-paths.json) cat "$ROOT/config/risky-paths.json" ;;
  */main/.github/workflows/agent-dispatch.yml) cat "$ROOT/.github/workflows/agent-dispatch.yml" ;;
  *) exit 22 ;;
esac
"""


def arm(tmp_path, repo, file, labels="[]", fail_curl=""):
    script = subprocess.run(["yq", STEP, str(ROOT / ".github/workflows/agent.yml")],
                            check=True, capture_output=True, text=True).stdout
    assert "CLASSIFY" in script
    for name, body in (("gh", FAKE_GH), ("curl", FAKE_CURL)):
        (tmp_path / name).write_text(body)
        (tmp_path / name).chmod(0o755)
    env = {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path), "ROOT": str(ROOT),
           "REPO": repo, "REF": "claim/issue-7", "FAKE_FILE": file, "FAKE_LABELS": labels, "FAIL_CURL": fail_curl,
           "GH_TOKEN": "x"}
    r = subprocess.run(["bash", "-e", "-c", script], env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    log = (tmp_path / "gh.log").read_text()
    held = "--add-label needs-coordinator" in log
    armed = "--auto --squash" in log
    assert held != armed, log
    return "held" if held else "armed"


@pytest.mark.parametrize("repo,file,labels,fail_curl,want", [
    # The case the round-2 review asked for: a worker-armed risky product PR, hold-risky not run.
    ("Nishfleet/0509", "app/lib/auth.server.ts", "[]", "", "held"),
    ("Nishfleet/0509", "package.json", "[]", "", "held"),
    ("Nishfleet/drive", "migrations/0042_add.sql", "[]", "", "held"),
    ("Nishfleet/0509", "app/routes/home.tsx", "[]", "", "armed"),
    ("Nishfleet/fleet-ops", "docs/RUNBOOK.md", "[]", "", "armed"),
    ("Nishfleet/fleet-ops", "ansible/update.yml", "[]", "", "held"),
    ("Nishfleet/0509", "app/routes/home.tsx", '[{"name":"needs-coordinator"}]', "", "held"),
    ("Nishfleet/0509", "app/routes/home.tsx", "[]", "1", "held"),
])
def test_arm_holds_risky(tmp_path, repo, file, labels, fail_curl, want):
    assert arm(tmp_path, repo, file, labels, fail_curl) == want
