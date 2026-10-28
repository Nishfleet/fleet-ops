"""fleet-ops#10218: the full sweep (list job) puts needs-triage on unlabelled, human-filed issues in
fleet-ops, 5 a run. Runs the real `run:` block against a fake gh. Product repos are left to admit."""
import json
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent-dispatch.yml")
LIST_STEP = '.jobs.list.steps[] | select(.id == "list")'

FAKE_GH = r"""#!/usr/bin/env bash
q=.; for ((i = 1; i <= $#; i++)); do [ "${!i}" = --jq ] && { j=$((i + 1)); q=${!j}; }; done
case "$*" in
  "label create"*|"issue edit"*) echo "$*" >> "$FAKE_DIR/writes.log" ;;
  "issue list"*" -S "*) echo "$*" >> "$FAKE_DIR/searches.log"; jq -r "$q" "$FAKE_DIR/search.json" ;;
  "issue list"*) echo '[]' | jq -r "$q" ;;
  "pr list"*) echo '[]' | jq -r "$q" ;;
  "api graphql"*) echo '{"data":{"repository":{"mergeQueue":{"entries":{"nodes":[]}}}}}' | jq -r "$q" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 99 ;;
esac
"""


def _y(expr):
    return subprocess.run(["yq", f"{LIST_STEP} | {expr}", WF], check=True, capture_output=True, text=True).stdout


def sweep(tmp_path, repo, found):
    gh = tmp_path / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    (tmp_path / "search.json").write_text(json.dumps([{"number": n} for n in found]))
    (tmp_path / "out").write_text("")
    env = {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path),
           "GITHUB_REPOSITORY": repo, "GH_TOKEN": "x", "CLOSED": "", "ISSUE": "",
           "GITHUB_OUTPUT": str(tmp_path / "out"), "CHECK_DEFS": _y(".env.CHECK_DEFS"), "RUN_LIVE_JQ": _y(".env.RUN_LIVE_JQ"), "RED_REWORK": _y(".env.RED_REWORK")}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(".run")], env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    log = tmp_path / "writes.log"
    searches = tmp_path / "searches.log"
    return (log.read_text().splitlines() if log.exists() else []), (searches.read_text() if searches.exists() else "")


def test_fleet_ops_unlabelled_issues_get_needs_triage(tmp_path):
    writes, searches = sweep(tmp_path, "Nishfleet/fleet-ops", [11, 12])
    assert "-S no:label -author:app/nishfleet-worker -L 5" in searches
    assert "issue edit 11 -R Nishfleet/fleet-ops --add-label needs-triage" in writes
    assert "issue edit 12 -R Nishfleet/fleet-ops --add-label needs-triage" in writes
    assert writes[0].startswith("label create needs-triage")


def test_nothing_unlabelled_makes_no_edit(tmp_path):
    writes, _ = sweep(tmp_path, "Nishfleet/fleet-ops", [])
    assert not [w for w in writes if w.startswith("issue edit")]


def test_a_product_repo_is_left_to_admit(tmp_path):
    writes, searches = sweep(tmp_path, "Nishfleet/0509", [11])
    assert writes == [] and searches == ""
