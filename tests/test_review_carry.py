"""The review job carries an approval across a rebase when the PR's own change is unchanged (fleet-ops#10681).

Runs the review step's own scope block, read out of agent.yml, against a real git fixture: an approved head,
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
CFG = {"guard": ["^\\.github/", "(^|/)migrations/"]}


def block():
    run = next(s["run"] for j in yaml.safe_load(WF.read_text())["jobs"].values() for s in j.get("steps", []) if s.get("id") == "review")
    return run[run.index("# Review scope (#10681)"):run.index('[ "$(wc -c < "$RUNNER_TEMP/diff.txt")" -gt 250000 ]')]


def git(repo, *args):
    return subprocess.run([*GIT, "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


def commit(repo, files, msg):
    for name, text in files.items():
        p = repo / name
        p.parent.mkdir(parents=True, exist_ok=True)
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
    c["wf"] = commit(r, {".github/workflows/x.yml": "on: push\n"}, "the approved head also added a workflow")
    # main adds a line right next to the PR's own line, so a rebase conflicts in the shared list
    git(r, "checkout", "-qb", "m1", c["b0"])
    c["b1"] = commit(r, {"list.txt": "a\na2\nc\n"}, "main adds a2")
    git(r, "checkout", "-qb", "keep", c["b1"])
    c["keep"] = commit(r, {"list.txt": "a\na2\nb\nc\n", "app.txt": "y\n", "blob.bin": b"\x00\x03"}, "rebase, conflict kept the PR line")
    git(r, "checkout", "-qb", "changed", c["b1"])
    c["changed"] = commit(r, {"list.txt": "a\na2\nb2\nc\n", "app.txt": "y\n", "blob.bin": b"\x00\x03"}, "rebase, conflict changed the PR line")
    git(r, "checkout", "-qb", "bin", c["b1"])
    c["bin"] = commit(r, {"list.txt": "a\na2\nb\nc\n", "app.txt": "y\n", "blob.bin": b"\x00\x04"}, "rebase, the binary file changed to other bytes")
    git(r, "checkout", "-qb", "wfkeep", c["b1"])
    c["wfkeep"] = commit(r, {"list.txt": "a\na2\nb\nc\n", "app.txt": "y\n", "blob.bin": b"\x00\x03", ".github/workflows/x.yml": "on: push\n"}, "rebase, and the workflow came along")
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
    # the same conflict, resolved twice inside a merge of main: one kept the PR's own line, one changed it
    for name, text, msg in (("mkeep", "a\na2\nb\nc\n", "merge main, kept the PR line"), ("mchanged", "a\na2\nb2\nc\n", "merge main, changed the PR line")):
        git(r, "checkout", "-qb", name, c["old"])
        subprocess.run([*GIT, "-C", str(r), "merge", "-q", "--no-edit", "--no-commit", c["b1"]], capture_output=True)
        c[name] = commit(r, {"list.txt": text}, msg)
    # a PR that changes one line of list.txt only, and a head that puts that line at another place in the file
    git(r, "checkout", "-qb", "old2", c["b0"])
    c["old2"] = commit(r, {"list.txt": "a\nb\nc\n"}, "pr, list only")
    git(r, "checkout", "-qb", "mv2", c["b2"])
    c["mv2"] = commit(r, {"list.txt": "b\na\nc\n"}, "rebase, the PR line moved, nothing else")
    git(r, "checkout", "-qb", "mv3", c["b2"])
    c["mv3"] = commit(r, {"list.txt": "b\na\nc\n", "note.txt": "n\n"}, "rebase, the PR line moved and a note was added")
    git(r, "checkout", "-qb", "added", c["old"])
    c["added"] = commit(r, {"new.txt": "n\n"}, "a new commit on top")
    return r, c


REVIEWER_LOGIN = "nishfleet-reviewer[bot]"  # the App whose key only the review runners load (fleet-ops#9521)


def approval(sha, login=REVIEWER_LOGIN, edited=False):
    return {"user": {"login": login}, "created_at": "t", "updated_at": "t2" if edited else "t",
            "body": f"coordinator-approval: {sha}\n\nreviewer: {sha} approved."}


def bot_review(sha, state="APPROVED", login="github-actions[bot]"):
    return {"user": {"login": login}, "commit_id": sha, "state": state, "body": f"reviewer: {sha} approved."}


def review(tmp_path, repo, base, head, comments, cfg=CFG, reviews=None, reviewer_login=REVIEWER_LOGIN):
    origin, _ = repo
    bt, temp = tmp_path / "bt", tmp_path / "temp"
    temp.mkdir()
    if reviews is None:
        # the review approve() writes for each approval comment; a test that wants the comment alone passes []
        reviews = [bot_review(c["body"].split("\n")[0].split(": ")[1]) for c in comments
                   if c.get("user", {}).get("login") == reviewer_login and c["body"].startswith("coordinator-approval: ")]
    git(tmp_path, "init", "-q", str(bt))
    git(bt, "fetch", "-q", str(origin), f"{base}:refs/base", f"{head}:refs/head")
    (temp / "diff.txt").write_text(git(bt, "diff", "--no-color", "refs/base...refs/head") + "\n")
    (temp / "files.txt").write_text(git(bt, "diff", "--name-only", f"{base}...{head}") + "\n")
    stubs = (
        'set -euo pipefail\n'
        'git() { local a=() x; for x in "$@"; do case $x in https://github.com/*) a+=("$ORIGIN") ;; *) a+=("$x") ;; esac; done; command git "${a[@]}"; }\n'
        'gh() { case "$*" in *"/comments"*) printf "%s" "$COMMENTS" ;; *"/reviews"*) printf "%s" "$REVIEWS" ;; *"--jq .head.sha"*) echo "$SHA" ;; *) echo "unexpected gh $*" >&2; return 1 ;; esac; }\n'
        'say() { printf "%s\\n" "$1" >> "$RUNNER_TEMP/said"; }\napprove() { echo "APPROVE $SHA" >> "$RUNNER_TEMP/said"; }\n'
        'approve_say() { approve; say "$1"; }\n'
    )
    env = {"PATH": "/usr/bin:/bin", "HOME": str(tmp_path), "ORIGIN": str(origin), "COMMENTS": json.dumps(comments), "SHA": head,
           "REVIEWS": json.dumps(reviews),
           "REPO": "Nishfleet/fleet-ops", "PR": "7", "RUNNER_TEMP": str(temp), "GITHUB_OUTPUT": str(temp / "out"), "bt": str(bt),
           "REVIEWER_LOGIN": reviewer_login,
           "cfg": json.dumps(cfg)}
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


@pytest.mark.parametrize("head,base", [("ws", "b2"), ("both", "b3")])
def test_whitespace_or_own_line_change_reviews_only_the_interdiff(tmp_path, repo, head, base):
    c = repo[1]
    r, said, out, diff = review(tmp_path, repo, c[base], c[head], [approval(c["old"])])
    assert interdiff(r, said, out, diff, c["old"]), r.stdout + r.stderr + diff


def test_range_diff_cannot_see_a_merge_resolution(tmp_path, repo):
    # why carry() compares the PR's own diff and replays it, and does not use `git range-diff` to decide scope:
    # for a branch that merged main, range-diff lists the merge as an added commit and marks the PR's own commit
    # unchanged in both cases, so it reads the same whether the resolution kept the PR's line or changed it
    origin, c = repo
    for head in (c["mkeep"], c["mchanged"]):
        out = git(origin, "range-diff", f"{c['b0']}..{c['old']}", f"{c['b1']}..{head}")
        assert " = " in out.splitlines()[0] and " ! " not in out and "<" not in out, out
    kept, changed = tmp_path / "kept", tmp_path / "changed"
    kept.mkdir()
    changed.mkdir()
    r, said, out, _ = review(kept, repo, c["b1"], c["mkeep"], [approval(c["old"])])
    assert carried(r, said, out, c["old"], c["mkeep"]), r.stdout + r.stderr
    r, said, out, diff = review(changed, repo, c["b1"], c["mchanged"], [approval(c["old"])])
    assert interdiff(r, said, out, diff, c["old"]), r.stdout + r.stderr + diff


@pytest.mark.parametrize("head,prior", [("moved", "old"), ("mv2", "old2"), ("mv3", "old2")], ids=["move-only", "move-only-one-file", "move-and-add"])
def test_a_line_moved_to_another_place_shows_as_the_interdiff(tmp_path, repo, head, prior):
    # the two own diffs read the same once the hunk position is dropped and the replay onto the new base does not give
    # this head, so the difference is the hunk position, and the interdiff keeps it: the reviewer reads the move
    c = repo[1]
    r, said, out, diff = review(tmp_path, repo, c["b2"], c[head], [approval(c[prior])])
    assert interdiff(r, said, out, diff, c[prior]), r.stdout + r.stderr + diff
    lines = diff.splitlines()
    assert " +b" in lines and any(x.startswith("-@@ ") for x in lines) and any(x.startswith("+@@ ") for x in lines), diff


def verdict(line):
    return {"user": {"login": "github-actions[bot]"}, "created_at": "t", "updated_at": "t", "body": line}


@pytest.mark.parametrize("login,carries", [(REVIEWER_LOGIN, True), ("github-actions[bot]", False)], ids=["reviewer-app", "actions-bot"])
def test_only_the_reviewer_apps_approval_carries(tmp_path, repo, login, carries):
    # fleet-ops#9521: the approval line now comes from the App whose key only the review runners load, and
    # the same line as github-actions[bot] (which any workflow on any branch posts as) carries nothing.
    c = repo[1]
    comments = [approval(c["old"], login=login)]
    r, said, out, _ = review(tmp_path, repo, c["b1"], c["keep"], comments, reviews=[bot_review(c["old"])])
    if carries:
        assert carried(r, said, out, c["old"], c["keep"]), r.stdout + r.stderr
    else:
        assert r.returncode == 0 and not said and not out and "scope=full note=" in r.stdout, r.stdout + r.stderr


@pytest.mark.parametrize("comments", [
    [approval(MISSING)],  # the approved head cannot be fetched: carry() fails closed
    [],  # nothing approved before
    [approval("OLD", login="someone")],  # an approval line from another login
    [approval("OLD", edited=True)],  # an edited bot comment
    [verdict("reviewer: 1111111111111111111111111111111111111111 blocked. Fix these.\n\ncoordinator-approval: OLD")],  # an approval line quoted below the first line
    [approval("OLD"), verdict("reviewer: 1111111111111111111111111111111111111111 blocked. Fix these.")],  # a later head was blocked
], ids=["prior-head-unreachable", "no-prior-approval", "other-login", "edited-comment", "quoted-approval-line", "blocked-after-approval"])
def test_anything_else_gets_a_full_review(tmp_path, repo, comments):
    c = repo[1]
    comments = json.loads(json.dumps(comments).replace("OLD", c["old"]))
    r, said, out, diff = review(tmp_path, repo, c["b1"], c["keep"], comments)
    assert r.returncode == 0 and not said and not out and "scope=full note=" in r.stdout, r.stdout + r.stderr
    assert diff.startswith("diff --git") and "+y" in diff.splitlines() and "+b" in diff.splitlines()


@pytest.mark.parametrize("head,base,cfg", [("wfkeep", "b1", CFG), ("clean", "b2", {"guard": ["^app\\.txt$"]})], ids=["workflow-head", "other-guard-path"])
def test_a_guard_head_gets_a_full_review(tmp_path, repo, head, base, cfg):
    # the head itself touches a guard path: no carry and no interdiff
    c = repo[1]
    r, said, out, diff = review(tmp_path, repo, c[base], c[head], [approval(c["old"])], cfg=cfg)
    assert r.returncode == 0 and not said and not out and "scope=full note=" in r.stdout and diff.startswith("diff --git"), r.stdout + r.stderr


def test_an_approved_guard_head_does_not_hand_its_approval_on(tmp_path, repo):
    # the approved head added a workflow, so that approval could have been posted by the workflow itself;
    # this head dropped the workflow and would otherwise get only an interdiff review of the rest
    c = repo[1]
    r, said, out, diff = review(tmp_path, repo, c["b1"], c["keep"], [approval(c["wf"])])
    assert r.returncode == 0 and not said and not out and "scope=full note=" in r.stdout and diff.startswith("diff --git"), r.stdout + r.stderr


@pytest.mark.parametrize("reviews", [
    [],  # an approval comment with no review behind it
    [bot_review("OLD", login="someone")],  # a review of that head from another login
    [bot_review("OTHER")],  # a review of another commit
    [dict(bot_review("OLD"), state="COMMENTED")],  # a review that is not an approval
], ids=["comment-alone", "other-login", "other-commit", "not-an-approval"])
def test_a_comment_is_not_proof_of_an_approval(tmp_path, repo, reviews):
    # any workflow on a branch of this repo posts as the same bot, so the carry also needs the review approve()
    # wrote on that head: the head a review names is the head it approved, which a comment cannot claim
    c = repo[1]
    reviews = json.loads(json.dumps(reviews).replace("OLD", c["old"]).replace("OTHER", c["added"]))
    r, said, out, diff = review(tmp_path, repo, c["b2"], c["clean"], [approval(c["old"])], reviews=reviews)
    assert r.returncode == 0 and not said and not out and "scope=full note=" in r.stdout and diff.startswith("diff --git"), r.stdout + r.stderr


def test_a_dismissed_review_still_carries(tmp_path, repo):
    # a push dismisses a stale approval, and the carry is the one case where the old head is read on purpose
    c = repo[1]
    r, said, out, _ = review(tmp_path, repo, c["b2"], c["clean"], [approval(c["old"])], reviews=[bot_review(c["old"], "DISMISSED")])
    assert carried(r, said, out, c["old"], c["clean"]), r.stdout + r.stderr
