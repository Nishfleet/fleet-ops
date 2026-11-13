"""The approver bot posts the reviewer's verdict, and never approves the code owner's own pull request
or one that deletes or changes existing test lines (CODEOWNERS does not cover tests/).

fleet-ops#11741 was opened under the owner's login; GitHub counted that as code-owner review, and
it merged on the bot's approval alone. This runs the verdict job's real step against a fake `gh`.
https://docs.github.com/en/rest/pulls/reviews#create-a-review-for-a-pull-request
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
data = {"view": {"headRefOid": "abc", "author": {"login": os.environ["AUTHOR"]}, "body": os.environ["BODY"]},
        "files": json.loads(os.environ["FILES"]), "reviews": json.loads(os.environ["REVIEWS"])}
if args[:2] == ["pr", "view"]:
    data = data["view"]
elif any(a.endswith("/files") for a in args):
    data = data["files"]
elif args[1] == "user":
    data = {"login": "nishfleet-approver"}
elif any(a.endswith("/reviews") for a in args) and "--paginate" in args:
    data = data["reviews"]
elif any(a.endswith("/dismissals") for a in args):
    data = {"state": "DISMISSED"}
elif any(a.endswith("/reviews") for a in args):
    data = {"id": 99, "state": "COMMENTED"}
else:
    sys.exit(0)
out = json.dumps(data)
sys.stdout.write(out if jq is None else subprocess.run(["jq", "-r", jq], input=out, capture_output=True, text=True, check=True).stdout)
'''

CR = {"id": 5, "state": "CHANGES_REQUESTED", "user": {"login": "nishfleet-approver"}}


def f(filename, status="modified", deletions=1, **extra):
    return {"filename": filename, "status": status, "deletions": deletions, **extra}


APP_CHANGE = (f("src/app.py"),)


def run_verdict(tmp_path, author, review, files=APP_CHANGE, body="Closes #1\n\nrun-proof: pytest -q -> 3 passed", reviews=()):
    gh = tmp_path / "gh"
    gh.write_text(f"#!{sys.executable}\n{FAKE_GH}")
    gh.chmod(0o755)
    env = {"PATH": f"{tmp_path}:/usr/bin:/bin", "FAKE_GH_DIR": str(tmp_path), "AUTHOR": author,
           "FILES": json.dumps(list(files)), "BODY": body, "REVIEWS": json.dumps(list(reviews)),
           "REPO": "o/r", "PR": "7", "SHA": "abc", "REVIEW": review, "TEST_EDITS": STEP["env"]["TEST_EDITS"]}
    subprocess.run(["bash", "-c", STEP["run"]], env=env, check=True, capture_output=True, text=True)
    return [json.loads(c) for c in (tmp_path / "calls.log").read_text().splitlines()]


def verdict(tmp_path, author, review, files=APP_CHANGE, **kw):
    post = next(c for c in reversed(run_verdict(tmp_path, author, review, files=files, **kw))
                if any(a.startswith("event=") for a in c))
    return next(a for a in post if a.startswith("event=")).split("=", 1)[1]


@pytest.mark.parametrize("review, event", [
    ("fine\nVERDICT: APPROVE", "APPROVE"),
    ("a.py:3 wrong\nVERDICT: CHANGES", "REQUEST_CHANGES"),
    ("money\nVERDICT: HOLD-OWNER", "COMMENT"),
])
def test_the_bot_posts_the_reviewers_verdict(tmp_path, review, event):
    assert verdict(tmp_path, "nishfleet-worker[bot]", review) == event


def test_the_owners_own_pull_request_is_never_approved(tmp_path):
    assert verdict(tmp_path, "nish3451", "fine\nVERDICT: APPROVE") == "COMMENT"


@pytest.mark.parametrize("body", ["Closes #1", "Closes #1\n\nThe worker wrote no run-proof line, so the reviewer bot will not approve."])
def test_a_pull_request_without_a_run_proof_line_is_never_approved(tmp_path, body):
    assert verdict(tmp_path, "nishfleet-worker[bot]", "fine\nVERDICT: APPROVE", body=body) == "COMMENT"


@pytest.mark.parametrize("change", [f(n) for n in ["tests/test_a.py", "app/test/x.ts", "e2e/login.ts", "src/__tests__/a.js",
                                                    "pkg/a_test.go", "src/a.test.tsx", "src/a.spec.ts", "lib/test_b.py"]]
                         + [f("tests/test_old.py", "removed"), f("src/a.py", "renamed", 0, previous_filename="tests/test_a.py")])
def test_a_pull_request_that_changes_existing_test_lines_is_never_approved(tmp_path, change):
    assert verdict(tmp_path, "nishfleet-worker[bot]", "fine\nVERDICT: APPROVE", [change]) == "COMMENT"


def test_new_test_files_and_pure_additions_are_approved(tmp_path):
    files = [f("tests/test_new.py", "added", 0), f("tests/test_old.py", deletions=0), f("src/app.py", deletions=9)]
    assert verdict(tmp_path, "nishfleet-worker[bot]", "fine\nVERDICT: APPROVE", files) == "APPROVE"


def test_no_verdict_line_fails_the_job_instead_of_posting(tmp_path):
    with pytest.raises(subprocess.CalledProcessError):
        verdict(tmp_path, "nishfleet-worker[bot]", "I think it is fine.")


def dismissals(calls):
    return [c for c in calls if any(a.endswith("/dismissals") for a in c)]


def test_a_hold_dismisses_the_change_request_the_reviewer_left_on_an_old_head(tmp_path):
    calls = run_verdict(tmp_path, "nishfleet-worker[bot]", "money\nVERDICT: HOLD-OWNER", reviews=[CR])
    (put,) = dismissals(calls)
    assert "repos/o/r/pulls/7/reviews/5/dismissals" in put
    message = next(a for a in put if a.startswith("message="))[len("message="):]
    assert "review 99" in message and "\n" not in message


def test_a_hold_after_the_reviewer_already_approved_dismisses_nothing(tmp_path):
    calls = run_verdict(tmp_path, "nishfleet-worker[bot]", "money\nVERDICT: HOLD-OWNER",
                        reviews=[CR, {"id": 6, "state": "APPROVED", "user": {"login": "nishfleet-approver"}}])
    assert dismissals(calls) == []


def test_a_hold_dismisses_only_the_reviewers_own_change_request(tmp_path):
    calls = run_verdict(tmp_path, "nishfleet-worker[bot]", "money\nVERDICT: HOLD-OWNER",
                        reviews=[{**CR, "user": {"login": "someone-else"}}])
    assert dismissals(calls) == []


def test_a_hold_without_any_change_request_dismisses_nothing(tmp_path):
    calls = run_verdict(tmp_path, "nishfleet-worker[bot]", "money\nVERDICT: HOLD-OWNER")
    assert dismissals(calls) == []


def test_a_hold_labels_and_requests_the_owner_review_through_the_rest_endpoints(tmp_path):
    calls = run_verdict(tmp_path, "nishfleet-worker[bot]", "money\nVERDICT: HOLD-OWNER")
    assert ["api", "repos/o/r/issues/7/labels", "-f", "labels[]=needs-owner"] in calls
    assert ["api", "repos/o/r/pulls/7/requested_reviewers", "-f", "reviewers[]=nish3451"] in calls
    assert not any(c[:2] == ["pr", "edit"] for c in calls)


def test_a_new_changes_verdict_keeps_the_change_request(tmp_path):
    calls = run_verdict(tmp_path, "nishfleet-worker[bot]", "a.py:3 wrong\nVERDICT: CHANGES", reviews=[CR])
    assert dismissals(calls) == []
    assert not any("/reviews" in " ".join(c) and "-X" in c for c in calls)
