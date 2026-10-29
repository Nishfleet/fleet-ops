"""fleet-ops#9528: the review job scans its own comment for private detail before it posts it.

The review text is model output written from a diff, so it can quote a home
path, a Tailscale name or an account id that a pull request added. Here the
real `scan`, `scan_failed`, `say`, `approve_say`, `approve` and `retry`
functions of the review step in agent.yml run with the real gitleaks and the
real .github/gitleaks-private-detail.toml; only `gh` and the rules download are
stubs, so the assertion is on what would go public.
"""
import os
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
AGENT = ROOT / ".github" / "workflows" / "agent.yml"
RULES = ROOT / ".github" / "gitleaks-private-detail.toml"
SHA = "3f9c2a1b7d4e5f60718293a4b5c6d7e8f9012345"
WITHHELD = "[a line was withheld: it matched a private-detail rule]"
STUB = """#!/usr/bin/env bash
case "$0" in
  */gh) printf "%s\\n" "$*" >> "$STATE/calls"
        while [ $# -gt 0 ]; do
          [ "$1" = --body ] && { printf "%s\\n===END===\\n" "$2" >> "$STATE/bodies"; break; }
          shift
        done
        exit 0 ;;
  */curl) [ -n "${RULES_SRC:-}" ] || exit 22
          while [ $# -gt 0 ]; do [ "$1" = -o ] && cp "$RULES_SRC" "$2"; shift; done
          exit 0 ;;
esac
"""


def _run_block():
    out = subprocess.run(
        ["yq", '.jobs.review.steps[] | select(.id == "review") | .run', str(AGENT)],
        check=True, capture_output=True, text=True,
    ).stdout
    assert out.strip(), "the review step's run block was not found"
    return out


def _scanner(run):
    """The scan and posting functions, scan() through retry(), as the step defines them."""
    lines = run.splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith("scan() {"))
    end = next(i for i, line in enumerate(lines) if line.startswith("retry() {"))
    assert start < end, "scan() must be defined before retry()"
    return "\n".join(lines[start:end + 1])


def _post(tmp_path, text, function="say", rules=RULES):
    state = tmp_path / "state"
    state.mkdir()
    stub_dir = tmp_path / "bin"
    stub_dir.mkdir()
    for name in ("gh", "curl"):
        (stub_dir / name).write_text(STUB)
        (stub_dir / name).chmod(0o755)
    env = {
        **os.environ,
        "PATH": f"{stub_dir}:{os.environ['PATH']}",
        "HOME": str(tmp_path / "home"),
        "RUNNER_TEMP": str(tmp_path / "temp"),
        "STATE": str(state),
        "REPO": "Nishfleet/fleet-ops",
        "PR": "7",
        "SHA": SHA,
        "RULES_SRC": "" if rules is None else str(rules),
    }
    pathlib.Path(env["RUNNER_TEMP"]).mkdir()
    script = _scanner(_run_block()) + f'\n{function} "$TEXT"\n'
    r = subprocess.run(
        ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", script],
        env={**env, "TEXT": text}, capture_output=True, text=True,
    )
    bodies = (state / "bodies").read_text().split("\n===END===\n") if (state / "bodies").exists() else []
    calls = (state / "calls").read_text() if (state / "calls").exists() else ""
    return r, bodies[:-1], calls


def test_clean_review_is_posted_unchanged(tmp_path):
    text = "No blockers.\nchecked: the token is read from the config file\nAPPROVE"
    r, bodies, _ = _post(tmp_path, text)
    assert r.returncode == 0, r.stderr
    assert bodies == [text]
    assert WITHHELD not in bodies[0]


def test_private_hostname_line_is_withheld_with_a_note(tmp_path):
    text = "No blockers.\nchecked: db1.fake-tailnet.ts.net answers on the private network\nAPPROVE"  # gitleaks:allow
    r, bodies, _ = _post(tmp_path, text)
    assert r.returncode == 0, r.stderr
    assert "fake-tailnet" not in bodies[0]
    assert WITHHELD in bodies[0]
    assert "No blockers." in bodies[0] and "APPROVE" in bodies[0]


def test_blocker_line_with_private_detail_is_withheld_but_the_rest_posts(tmp_path):
    text = "blocker app/main.ts: reads /home/nish/fleet-ops/seats.env\nrisk: none\nBLOCK"  # gitleaks:allow
    r, bodies, _ = _post(tmp_path, text)
    assert r.returncode == 0, r.stderr
    assert "/home/nish" not in bodies[0]
    assert WITHHELD in bodies[0]
    assert "risk: none" in bodies[0] and "BLOCK" in bodies[0]


def test_cloudflare_account_id_is_withheld(tmp_path):
    text = "blocker wrangler.toml: pins account_id: 0123456789abcdef0123456789abcdef\nBLOCK"  # gitleaks:allow
    r, bodies, _ = _post(tmp_path, text)
    assert r.returncode == 0, r.stderr
    assert "0123456789abcdef" not in bodies[0]
    assert WITHHELD in bodies[0]


def test_quoted_allow_marker_does_not_bypass_the_scan(tmp_path):
    text = "risk: host fake-net.ts.net # gitleaks:allow\nAPPROVE"
    r, bodies, _ = _post(tmp_path, text)
    assert r.returncode == 0, r.stderr
    assert "fake-net.ts.net" not in bodies[0]  # gitleaks:allow
    assert WITHHELD in bodies[0]


def test_a_hit_that_spans_two_lines_is_withheld_as_one_note(tmp_path):
    rules = tmp_path / "multiline.toml"
    rules.write_text('[[rules]]\nid = "test-multiline"\ndescription = "two lines"\nregex = \'\'\'token\\nvalue-\\w+\'\'\'\nmultiline = true\n')
    text = "No blockers.\ntoken\nvalue-abc123\nAPPROVE"
    r, bodies, _ = _post(tmp_path, text, rules=rules)
    assert r.returncode == 0, r.stderr
    assert bodies == [f"No blockers.\n{WITHHELD}\nAPPROVE"]


def test_unreadable_rules_post_no_review_text(tmp_path):
    text = "No blockers.\nchecked: db1.fake-tailnet.ts.net\nAPPROVE"  # gitleaks:allow
    r, bodies, _ = _post(tmp_path, text, rules=None)
    assert r.returncode == 1
    assert "::error::the private-detail scan could not run" in r.stdout
    assert bodies, "the author must be told why no review was posted"
    assert "fake-tailnet" not in bodies[0] and "No blockers." not in bodies[0]


def test_approval_waits_for_the_scan(tmp_path):
    text = "coordinator-approval: %s\n\nreviewer: %s approved.\n\nNo blockers.\nAPPROVE" % (SHA, SHA)
    r, bodies, calls = _post(tmp_path, text, function="approve_say", rules=None)
    assert r.returncode == 1
    assert "pulls/7/reviews" not in calls, "the head was approved although the scan could not run"
    assert bodies and "No blockers." not in bodies[0]


def test_approval_posts_the_scanned_text(tmp_path):
    text = "coordinator-approval: %s\n\nreviewer: %s approved.\n\nNo blockers.\nAPPROVE" % (SHA, SHA)
    r, bodies, calls = _post(tmp_path, text, function="approve_say")
    assert r.returncode == 0, r.stderr
    assert "repos/Nishfleet/fleet-ops/pulls/7/reviews" in calls
    assert bodies == [text]


def test_the_retry_path_scans_too(tmp_path):
    r, bodies, _ = _post(tmp_path, "the judge call failed with /home/nish/fleet-ops/run", function="retry")  # gitleaks:allow
    assert r.returncode == 1, "retry must stop the step"
    assert bodies == [WITHHELD]


def test_both_posting_paths_scan_before_they_post():
    run = _run_block()
    assert "approve; say" not in run, "an approval path still posts without the scan"
    assert run.count("out=$(scan \"$1\") || scan_failed") == 2, "say and approve_say must both scan"
    assert "https://raw.githubusercontent.com/Nishfleet/fleet-ops/main/.github/gitleaks-private-detail.toml" in run, (
        "the scan must read the shared rule file the PR scan uses"
    )


def test_every_place_that_installs_gitleaks_pins_the_secret_scan_release():
    scan = (ROOT / ".github/workflows/secret-scan.yml").read_text()
    version = re.search(r"GITLEAKS_VERSION: (\S+)", scan).group(1)
    digest = re.search(r"GITLEAKS_SHA256: (\w+)", scan).group(1)
    release = f"gitleaks/releases/download/v{version}/gitleaks_{version}_linux_x64.tar.gz"
    for name in ("ci.yml", "agent.yml"):
        workflow = (ROOT / ".github/workflows" / name).read_text()
        assert release in workflow, f"{name} downloads a gitleaks the secret scan does not pin"
        assert digest in workflow, f"{name} checks a gitleaks hash the secret scan does not pin"
