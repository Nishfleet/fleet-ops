"""The review job carries an approval across a rebase when the PR's own change is unchanged (fleet-ops#10681).

Runs the review step's own carry block, read out of agent.yml, against a real git fixture: an approved head,
then main moves and the PR is rebased, merged with main, or extended.
"""
import json
import subprocess
from pathlib import Path

import pytest
import yaml

WF = Path(__file__).parents[1] / ".github/workflows/agent.yml"
GIT = ["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "init.defaultBranch=main"]
MISSING = "0123456789abcdef0123456789abcdef01234567"


def block():
    run = next(s["run"] for j in yaml.safe_load(WF.read_text())["jobs"].values() for s in j.get("steps", []) if s.get("id") == "review")
    return run[run.index("# An approval follows the change"):run.index('[ "$(wc -c < "$RUNNER_TEMP/diff.txt")" -gt 250000 ]')]


def git(repo, *args):
    return subprocess.run([*GIT, "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


def commit(repo, files, msg):
    for name, text in files.items():
        p = repo / name
        if isinstance(text, bytes):
            p.write_bytes(text)
        else:
            p.write_text(text)
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", msg)
    return git(repo, "rev-parse", "HEAD")


@pytest.fixture
def repo(tmp_path):
    r = tmp_path / "origin"
    r.mkdir()
    git(r, "init", "-q")
    git(r, "config", "uploadpack.allowAnySHA1InWant", "true")
    c = {"b0": commit(r, {"list.txt": "a\nc\n", "app.txt": "x\n", "blob.bin": b"\x00\x01"}, "base")}
    git(r, "checkout", "-qb", "pr")
    c["old"] = commit(r, {"list.txt": "a\nb\nc\n", "app.txt": "y\n", "blob.bin": b"\x00\x03"}, "pr")
    # main adds a line right next to the PR's own line, so a rebase conflicts in the shared list
    git(r, "checkout", "-qb", "m1", c["b0"])
    c["b1"] = commit(r, {"list.txt": "a\na2\nc\n"}, "main adds a2")
    git(r, "checkout", "-qb", "keep", c["b1"])
    c["keep"] = commit(r, {"list.txt": "a\na2\nb\nc\n", "app.txt": "y\n", "blob.bin": b"\x00\x03"}, "rebase, conflict kept the PR line")
    git(r, "checkout", "-qb", "changed", c["b1"])
    c["changed"] = commit(r, {"list.txt": "a\na2\nb2\nc\n", "app.txt": "y\n", "blob.bin": b"\x00\x03"}, "rebase, conflict changed the PR line")
    git(r, "checkout", "-qb", "bin", c["b1"])
    c["bin"] = commit(r, {"list.txt": "a\na2\nb\nc\n", "app.txt": "y\n", "blob.bin": b"\x00\x04"}, "rebase, the binary file changed to other bytes")
    # main moves elsewhere: a clean rebase, and a merge of main into the branch
    git(r, "checkout", "-qb", "m2", c["b0"])
    c["b2"] = commit(r, {"other.txt": "z\n"}, "main moves elsewhere")
    git(r, "checkout", "-qb", "clean", c["b2"])
    c["clean"] = commit(r, {"list.txt": "a\nb\nc\n", "app.txt": "y\n", "blob.bin": b"\x00\x03"}, "clean rebase")
    # the same lines with a whitespace change inside one, and the PR's line moved to another place in the file
    git(r, "checkout", "-qb", "ws", c["b2"])
    c["ws"] = commit(r, {"list.txt": "a\n b\nc\n", "app.txt": "y\n", "blob.bin": b"\x00\x03"}, "rebase, whitespace inside the PR line")
    git(r, "checkout", "-qb", "moved", c["b2"])
    c["moved"] = commit(r, {"list.txt": "b\na\nc\n", "app.txt": "y\n", "blob.bin": b"\x00\x03"}, "rebase, the PR line moved")
    # main edits the line the PR replaced; a head that keeps both edits is what union replay gives, but the PR's own -x line is gone
    git(r, "checkout", "-qb", "m3", c["b0"])
    c["b3"] = commit(r, {"app.txt": "x1\n"}, "main edits the PR's line")
    git(r, "checkout", "-qb", "both", c["b3"])
    c["both"] = commit(r, {"list.txt": "a\nb\nc\n", "app.txt": "x1\ny\n", "blob.bin": b"\x00\x03"}, "rebase, conflict kept both edits")
    git(r, "checkout", "-qb", "merged", c["old"])
    git(r, "merge", "-q", "--no-edit", c["b2"])
    c["merged"] = git(r, "rev-parse", "HEAD")
    git(r, "checkout", "-qb", "added", c["old"])
    c["added"] = commit(r, {"new.txt": "n\n"}, "a new commit on top")
    return r, c


def approval(sha, login="github-actions[bot]", edited=False):
    return {"user": {"login": login}, "created_at": "t", "updated_at": "t2" if edited else "t",
            "body": f"coordinator-approval: {sha}\n\nreviewer: {sha} approved."}


def review(tmp_path, repo, base, head, comments, guard="false"):
    origin, _ = repo
    bt, temp = tmp_path / "bt", tmp_path / "temp"
    temp.mkdir()
    git(tmp_path, "init", "-q", str(bt))
    git(bt, "fetch", "-q", str(origin), f"{base}:refs/base", f"{head}:refs/head")
    (temp / "diff.txt").write_text(git(bt, "diff", "--no-color", "refs/base...refs/head") + "\n")
    stubs = (
        'set -euo pipefail\n'
        'git() { local a=() x; for x in "$@"; do case $x in https://github.com/*) a+=("$ORIGIN") ;; *) a+=("$x") ;; esac; done; command git "${a[@]}"; }\n'
        'gh() { case "$*" in *"/comments"*) printf "%s" "$COMMENTS" ;; *"--jq .head.sha"*) echo "$SHA" ;; *) echo "unexpected gh $*" >&2; return 1 ;; esac; }\n'
        'say() { printf "%s\\n" "$1" >> "$RUNNER_TEMP/said"; }\napprove() { echo "APPROVE $SHA" >> "$RUNNER_TEMP/said"; }\n'
    )
    env = {"PATH": "/usr/bin:/bin", "HOME": str(tmp_path), "ORIGIN": str(origin), "COMMENTS": json.dumps(comments), "SHA": head,
           "REPO": "Nishfleet/fleet-ops", "PR": "7", "RUNNER_TEMP": str(temp), "GITHUB_OUTPUT": str(temp / "out"), "bt": str(bt), "guard": guard}
    p = subprocess.run(["bash", "-c", stubs + block() + 'echo "scope=$scope note=$note"\n'], env=env, capture_output=True, text=True)
    read = lambda n: (temp / n).read_text() if (temp / n).exists() else ""
    return p, read("said"), read("out"), read("diff.txt")


def carried(r, said, out, old, new):
    return r.returncode == 0 and f"APPROVE {new}" in said and f"coordinator-approval: {new}" in said \
        and f"Carried over from approved head {old}" in said and out.strip() == f"approved_sha={new}"


def test_clean_rebase_carries(tmp_path, repo):
    c = repo[1]
    r, said, out, _ = review(tmp_path, repo, c["b2"], c["clean"], [approval(c["old"])])
    assert carried(r, said, out, c["old"], c["clean"]), r.stdout + r.stderr


def test_merge_of_main_into_the_branch_carries(tmp_path, repo):
    c = repo[1]
    r, said, out, _ = review(tmp_path, repo, c["b2"], c["merged"], [approval(c["old"])])
    assert carried(r, said, out, c["old"], c["merged"]), r.stdout + r.stderr


def test_conflict_in_shared_list_carries_when_own_hunk_unchanged(tmp_path, repo):
    c = repo[1]
    r, said, out, _ = review(tmp_path, repo, c["b1"], c["keep"], [approval(c["old"])])
    assert carried(r, said, out, c["old"], c["keep"]), r.stdout + r.stderr


def interdiff(r, said, out, diff, old):
    lines = diff.splitlines()
    return r.returncode == 0 and not said and not out and lines[0].startswith(f"=== INTERDIFF: head {old}") \
        and "scope=interdiff" in r.stdout and f"Only the interdiff against approved head {old}" in r.stdout \
        and not any(l in ("++y", "-+y") for l in lines)


def test_conflict_that_changed_own_hunk_reviews_only_the_interdiff(tmp_path, repo):
    c = repo[1]
    r, said, out, diff = review(tmp_path, repo, c["b1"], c["changed"], [approval(c["old"])])
    assert interdiff(r, said, out, diff, c["old"]) and "++b2" in diff.splitlines() and "-+b" in diff.splitlines(), r.stdout + r.stderr + diff


def test_new_commit_reviews_only_the_interdiff(tmp_path, repo):
    c = repo[1]
    r, said, out, diff = review(tmp_path, repo, c["b0"], c["added"], [approval(c["old"])])
    assert interdiff(r, said, out, diff, c["old"]) and "++n" in diff.splitlines(), r.stdout + r.stderr + diff


def test_changed_binary_file_does_not_carry(tmp_path, repo):
    c = repo[1]
    r, said, out, diff = review(tmp_path, repo, c["b1"], c["bin"], [approval(c["old"])])
    assert interdiff(r, said, out, diff, c["old"]) and "blob.bin" in diff, r.stdout + r.stderr + diff


@pytest.mark.parametrize("head,base", [("ws", "b2"), ("moved", "b2"), ("both", "b3")])
def test_whitespace_position_or_own_line_change_does_not_carry(tmp_path, repo, head, base):
    c = repo[1]
    r, said, out, diff = review(tmp_path, repo, c[base], c[head], [approval(c["old"])])
    assert interdiff(r, said, out, diff, c["old"]), r.stdout + r.stderr + diff


def verdict(line):
    return {"user": {"login": "github-actions[bot]"}, "created_at": "t", "updated_at": "t", "body": line}


@pytest.mark.parametrize("comments", [
    [approval(MISSING)],  # the approved head cannot be fetched: the range-diff errors
    [],  # nothing approved before
    [approval("OLD", login="someone")],  # an approval line from another login
    [approval("OLD", edited=True)],  # an edited bot comment
    [verdict("reviewer: 1111111111111111111111111111111111111111 blocked. Fix these.\n\ncoordinator-approval: OLD")],  # an approval line quoted below the first line
    [approval("OLD"), verdict("reviewer: 1111111111111111111111111111111111111111 blocked. Fix these.")],  # a later head was blocked
], ids=["range-diff-error", "no-prior-approval", "other-login", "edited-comment", "quoted-approval-line", "blocked-after-approval"])
def test_anything_else_gets_a_full_review(tmp_path, repo, comments):
    c = repo[1]
    comments = json.loads(json.dumps(comments).replace("OLD", c["old"]))
    r, said, out, diff = review(tmp_path, repo, c["b1"], c["keep"], comments)
    assert r.returncode == 0 and not said and not out and "scope=full note=" in r.stdout, r.stdout + r.stderr
    assert diff.startswith("diff --git") and "+y" in diff.splitlines() and "+b" in diff.splitlines()


@pytest.mark.parametrize("head,base", [("clean", "b2"), ("added", "b0")])
def test_guard_head_with_a_same_login_approval_gets_a_full_review(tmp_path, repo, head, base):
    # a workflow in the PR could post this approval as the same bot, so a guard head neither carries nor narrows to an interdiff
    c = repo[1]
    r, said, out, diff = review(tmp_path, repo, c[base], c[head], [approval(c["old"])], guard="true")
    assert r.returncode == 0 and not said and not out and "scope=full note=" in r.stdout and diff.startswith("diff --git"), r.stdout + r.stderr
