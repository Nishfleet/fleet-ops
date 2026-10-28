import re
import subprocess
import textwrap
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/d1-drill.yml"
SAMPLE = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);\nINSERT INTO users VALUES (1, 'ada'), (2, 'bob'), (3, 'cy');\nCREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);\nINSERT INTO notes VALUES (1, 'first');\n"
BANNED = ("api.cloudflare.com", "d1/database", "wrangler", "deploy-ci", "CLOUDFLARE", "d1 create", "d1 import", "d1 export", "d1 execute", "d1 delete", "-X DELETE")


def restore_prelude():
    lines = WORKFLOW.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == "set -uo pipefail")
    end = next(i for i, line in enumerate(lines) if line.strip().startswith("read -r key mod"))
    return textwrap.dedent("\n".join(lines[start:end]))


def run_restore(tmp_path, dump):
    (tmp_path / "dump.sql").write_text(dump)
    script = restore_prelude() + '\nrestore sample ' + str(tmp_path / "dump.sql") + '\ncat "$w/report.txt"\n'
    env = {"RUNNER_TEMP": str(tmp_path / "run"), "GITHUB_STEP_SUMMARY": str(tmp_path / "summary"), "PATH": "/usr/bin:/bin"}
    (tmp_path / "run").mkdir()
    return subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True, check=True).stdout


def test_restore_counts_rows_per_table_and_removes_the_sqlite_file(tmp_path):
    out = run_restore(tmp_path, SAMPLE)
    assert "- sample: ok, restored once, rows: users=3 notes=1" in out
    assert "live count not run" in out
    assert [p.name for p in (tmp_path / "run" / "drill").iterdir()] == ["report.txt"]


def test_broken_dump_is_reported_after_one_retry(tmp_path):
    out = run_restore(tmp_path, SAMPLE + "INSERT INTO missing VALUES (1);\n")
    assert "- sample: restore failed twice" in out


def test_workflow_calls_no_cloudflare_write_and_obeys_the_drill_rules():
    text = WORKFLOW.read_text()
    for needle in BANNED:
        assert needle not in text, needle
    assert not re.search(r"\b[0-9a-f]{32}\b", text)
    assert "/home/" not in text
    assert "timeout-minutes: 20" in text
    assert "push:" not in text
    assert "trap " in text
    assert "EXIT" in text
    assert "key.txt" not in text
