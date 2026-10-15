"""fleet-ops#9528: the review job scans its own comment for private detail before posting it.

Runs the real scan() function of agent.yml's review step with the real gitleaks and the shared
rules file. Only the host name and account id samples are invented, and they are built at run time
so this file carries no match itself.
"""
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/agent.yml"
RULES = ROOT / ".github/gitleaks-private-detail.toml"
HOST = "db1.fake-tailnet." + "ts.net"
ACCOUNT = "account_id " + "0123456789abcdef" * 2


def _run_block():
    return subprocess.run(
        ["yq", '.jobs.review.steps[] | select(.id == "review") | .run', str(WORKFLOW)],
        check=True, capture_output=True, text=True,
    ).stdout


def _scan(tmp_path, text, rules_url=None):
    block = _run_block()
    fn = re.search(r"^scan\(\) \{\n.*?^\}\n", block, re.S | re.M).group(0)
    script = f'{fn}\nscan "$TEXT"\n'
    env = {
        "PATH": subprocess.run(["bash", "-c", "echo $PATH"], capture_output=True, text=True).stdout.strip(),
        "RUNNER_TEMP": str(tmp_path),
        "PRIVATE_DETAIL_URL": rules_url or RULES.as_uri(),
        "TEXT": text,
    }
    return subprocess.run(["bash", "--noprofile", "--norc", "-c", script], env=env, capture_output=True, text=True)


def test_clean_review_is_unchanged(tmp_path):
    text = "No blockers.\nchecked: a, b, c\nAPPROVE"
    r = _scan(tmp_path, text)
    assert r.returncode == 0, r.stderr
    assert r.stdout == text + "\n"
    assert sorted(f.name for f in tmp_path.iterdir()) == ["rules.toml"]


def test_private_host_line_is_withheld(tmp_path):
    r = _scan(tmp_path, f"No blockers.\nchecked: {HOST} answers\nAPPROVE")
    assert r.returncode == 0, r.stderr
    assert HOST not in r.stdout
    assert "[a line was withheld" in r.stdout and "No blockers." in r.stdout and "APPROVE" in r.stdout


def test_blocker_line_with_private_detail_is_withheld(tmp_path):
    r = _scan(tmp_path, f"blocker x.yml: quotes {HOST}\nrisk y")
    assert r.returncode == 0, r.stderr
    assert HOST not in r.stdout and "risk y" in r.stdout


def test_account_id_is_withheld(tmp_path):
    r = _scan(tmp_path, f"No blockers.\nchecked: {ACCOUNT} unchanged")
    assert r.returncode == 0, r.stderr
    assert "0123456789abcdef" not in r.stdout


def test_quoted_allow_marker_does_not_bypass_the_scan(tmp_path):
    r = _scan(tmp_path, f"checked: {HOST} # gitleaks:allow")
    assert r.returncode == 0, r.stderr
    assert HOST not in r.stdout


def test_unreadable_rules_post_nothing(tmp_path):
    r = _scan(tmp_path, f"checked: {HOST}", rules_url=(tmp_path / "missing.toml").as_uri())
    assert r.returncode != 0
    assert r.stdout == ""


def test_both_posting_paths_scan_and_approval_follows_the_scan():
    block = _run_block()
    assert re.search(r"^say\(\) \{ local out; out=\$\(scan \"\$1\"\) \|\| scan_failed;", block, re.M)
    assert re.search(r"approve_say\(\) \{ local out; out=\$\(scan \"\$1\"\) \|\| scan_failed; approve;", block)
    assert "approve; say" not in block
