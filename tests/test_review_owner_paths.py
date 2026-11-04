"""The approver bot never approves a pull request that touches a path CODEOWNERS lists.

fleet-ops#11741 changed rootfs/ and merged on the bot's approval alone, because the bot's own
owner list did not match CODEOWNERS. The verdict job now reads CODEOWNERS from the base branch and
holds any matching pull request for the owner. This runs the job's real step against a fake `gh`.
https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners#codeowners-syntax
"""
import json
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
STEP = yaml.safe_load((ROOT / ".github/workflows/review.yml").read_text())["jobs"]["verdict"]["steps"][0]

FAKE_GH = r'''
import json, os, subprocess, sys
d = os.environ["FAKE_GH_DIR"]
args = sys.argv[1:]
open(os.path.join(d, "calls.log"), "a").write(json.dumps(args) + "\n")
jq = args[args.index("--jq") + 1] if "--jq" in args else None
def out(data):
    if jq is None:
        sys.stdout.write(data)
    else:
        sys.stdout.write(subprocess.run(["jq", "-r", jq], input=data, capture_output=True, text=True, check=True).stdout)
if args[:2] == ["pr", "view"]:
    out(json.dumps({"headRefOid": "abc", "baseRefName": "main", "body": "run-proof: x"}))
elif any(a.endswith("/files") for a in args):
    out(open(os.path.join(d, "files.json")).read())
elif any("/contents/" in a for a in args):
    path = next(a for a in args if "/contents/" in a).split("/contents/")[1].split("?")[0]
    f = os.path.join(d, "repo", path)
    if os.path.exists(os.path.join(d, "down")):
        sys.stderr.write("gh: Server Error (HTTP 502)\n"); sys.exit(1)
    if not os.path.exists(f):
        sys.stderr.write("gh: Not Found (HTTP 404)\n"); sys.exit(1)
    out(open(f).read())
'''


def verdict(tmp_path, codeowners, *names, where=".github/CODEOWNERS"):
    if codeowners is not None:
        (tmp_path / "repo" / where).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / "repo" / where).write_text(codeowners)
    (tmp_path / "files.json").write_text(json.dumps(
        [{"filename": n, "status": "modified", "additions": 1, "deletions": 0} for n in names]))
    gh = tmp_path / "bin" / "gh"
    gh.parent.mkdir()
    gh.write_text(f"#!{sys.executable}\n{FAKE_GH}")
    gh.chmod(0o755)
    env = {"PATH": f"{gh.parent}:/usr/bin:/bin", "FAKE_GH_DIR": str(tmp_path), "RUNNER_TEMP": str(tmp_path),
           "REPO": "o/r", "PR": "7", "SHA": "abc", "REVIEWER": "r", "REVIEW": "fine\nVERDICT: APPROVE",
           "TEST_EDITS": STEP["env"]["TEST_EDITS"]}
    subprocess.run(["bash", "-c", STEP["run"]], env=env, check=True, capture_output=True, text=True)
    post = [json.loads(c) for c in (tmp_path / "calls.log").read_text().splitlines() if "/reviews" in c][-1]
    return next(a for a in post if a.startswith("event=")).split("=", 1)[1]


THIS_REPO = (ROOT / ".github/CODEOWNERS").read_text()


def test_a_rootfs_change_is_held_for_the_owner(tmp_path):
    assert verdict(tmp_path, THIS_REPO, "rootfs/etc/sudoers.d/deploy-box", "tests/test_deploy_start_grant.py") == "COMMENT"


def test_a_tests_only_change_is_approved(tmp_path):
    assert verdict(tmp_path, THIS_REPO, "tests/test_new.py") == "APPROVE"


@pytest.mark.parametrize("pattern", ["/apps/ @o", "apps/ @o"])
def test_a_pattern_with_or_without_a_leading_slash_matches(tmp_path, pattern):
    assert verdict(tmp_path, pattern + "\n", "apps/web/index.ts") == "COMMENT"


def test_a_pattern_without_a_leading_slash_matches_at_any_depth(tmp_path):
    assert verdict(tmp_path, "apps/ @o\n", "pkg/apps/a.ts") == "COMMENT"
    (tmp_path / "bin" / "gh").unlink()
    (tmp_path / "bin").rmdir()
    assert verdict(tmp_path, "/docs/ @o\n", "pkg/docs/a.md") == "APPROVE"


def test_codeowners_at_the_repo_root_counts_too(tmp_path):
    assert verdict(tmp_path, "*.yml @o\n", "deploy/app.yml", where="CODEOWNERS") == "COMMENT"


def test_no_codeowners_file_approves(tmp_path):
    assert verdict(tmp_path, None, "rootfs/x") == "APPROVE"


def test_codeowners_is_read_from_the_base_branch(tmp_path):
    verdict(tmp_path, THIS_REPO, "tests/test_new.py")
    calls = (tmp_path / "calls.log").read_text()
    assert "ref=main" in calls


def test_a_github_error_reading_codeowners_stops_the_job_instead_of_approving(tmp_path):
    (tmp_path / "down").touch()
    with pytest.raises(subprocess.CalledProcessError):
        verdict(tmp_path, THIS_REPO, "rootfs/x")
    assert "/reviews" not in (tmp_path / "calls.log").read_text()
