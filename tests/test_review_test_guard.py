"""The approver bot never approves a pull request that deletes or changes existing test lines.

Test folders are not owner-only in CODEOWNERS, so the verdict job holds such a pull request for the
owner itself. This runs the job's own filter over pull request files API records.
https://docs.github.com/en/rest/pulls/pulls#list-pull-requests-files
"""
import json
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
STEP = yaml.safe_load((ROOT / ".github/workflows/review.yml").read_text())["jobs"]["verdict"]["steps"][0]


def held(*files):
    out = subprocess.run(["jq", "-r", STEP["env"]["TEST_EDITS"]], input=json.dumps(list(files)),
                         capture_output=True, text=True, check=True).stdout
    return out.split()


def f(filename, status="modified", additions=1, deletions=0, **extra):
    return {"filename": filename, "status": status, "additions": additions, "deletions": deletions, **extra}


@pytest.mark.parametrize("name", ["tests/test_a.py", "app/test/x.ts", "e2e/login.ts", "src/__tests__/a.js",
                                  "pkg/a_test.go", "src/a.test.tsx", "src/a.spec.ts", "lib/test_b.py"])
def test_a_deleted_line_in_any_test_path_is_held(name):
    assert held(f(name, deletions=1)) == [name]


def test_new_test_files_and_pure_additions_pass():
    assert held(f("tests/test_new.py", "added", 40), f("tests/test_old.py", additions=5), f("src/app.py", deletions=9)) == []


def test_a_removed_test_file_is_held():
    assert held(f("tests/test_old.py", "removed", 0, 47)) == ["tests/test_old.py"]


def test_a_renamed_test_file_is_held_even_with_no_line_changes():
    assert held(f("src/a.py", "renamed", 0, 0, previous_filename="tests/test_a.py")) == ["src/a.py"]


def test_the_filter_reads_the_pull_request_files_before_an_approval():
    assert '"repos/$REPO/pulls/$PR/files" --jq "$TEST_EDITS"' in STEP["run"]
