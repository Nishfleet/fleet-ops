"""needs-triage admission: the admit job in agent-dispatch.yml.

Runs the job's real `run:` block, EXCLUDE program, BAND program and REQUEST
program (read out with yq, never copied) against a fake gh and a fake Jev
router on PATH. Covers each band, each hard exclusion, the fleet-ops lock, a
repo that is not enrolled, an untrusted labeller, and a missing Jev answer.
"""
import base64
import json
import os
import pathlib
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent-dispatch.yml")
STEP = '.jobs.admit.steps[] | select(.id == "admit")'

CFG = {"repos": [{"name": "0509", "product": True}, {"name": "tool", "product": False}]}

FAKE_GH = r"""#!/usr/bin/env bash
q=; args=("$@")
for ((i = 0; i < $#; i++)); do [ "${args[$i]}" = --jq ] && q=${args[$((i + 1))]}; done
emit() { if [ -n "$q" ]; then jq -r "$q" "$1"; else cat "$1"; fi; }
case "$1 $2" in
  "api repos/Nishfleet/fleet-ops/contents/config/intake-repos.json") emit "$FAKE_DIR/cfg.json" ;;
  "issue list") jq -r '.[].number' "$FAKE_DIR/list.json" ;;
  "issue edit"|"issue comment"|"label create") echo "$*" >> "$FAKE_DIR/writes.log" ;;
  "api "*/events) emit "$FAKE_DIR/events.json" ;;
  "api "*/issues/*) emit "$FAKE_DIR/issue.json" ;;
  *) exit 1 ;;
esac
"""

FAKE_CURL = r"""#!/usr/bin/env bash
for a in "$@"; do case $a in \{*) printf '%s' "$a" > "$FAKE_DIR/jev-request.json" ;; esac; done
echo called >> "$FAKE_DIR/curl.log"
cat "$FAKE_DIR/jev-response.json"
"""


def _y(expr):
    out = subprocess.run(["yq", expr, WF], check=True, capture_output=True, text=True).stdout
    assert out.strip() and out.strip() != "null", expr
    return out


def _env_var(name):
    return _y(f"{STEP} | .env.{name}")


def _jq(prog, data, **args):
    cmd = ["jq", "-r"]
    for k, v in args.items():
        cmd += ["--argjson", k, json.dumps(v)]
    if data is None:
        cmd.append("-n")
    r = subprocess.run(cmd + [prog], input=json.dumps(data), capture_output=True, text=True, check=True)
    return r.stdout.strip()


def issue(title="Fix the footer link colour", body="The footer link is grey on grey. Make it pass AA.", labels=("needs-triage",)):
    return {"number": 7, "state": "open", "title": title, "body": body, "labels": [{"name": n} for n in labels]}


@pytest.mark.parametrize(
    "title,body,labels,want",
    [
        ("Fix the footer link colour", "grey on grey", ["needs-triage"], ""),
        ("Rotate the API key", "x", ["needs-triage"], "secrets"),
        ("Move the Stripe webhook", "x", ["needs-triage"], "money or payments"),
        ("Tidy", "Show the new pricing table", ["needs-triage"], "money or payments"),
        ("Cleanup", "Delete all customer records older than a year", ["needs-triage"], "customer-data deletion"),
        ("Tidy", "x", ["needs-triage", "blocked-on: nish-decision"], "a reserved label"),
        ("Tidy", "x", ["needs-triage", "nish-reserved"], "a reserved label"),
        ("Tidy", "Add the DB password to .env", ["needs-triage"], "secrets"),
        ("Tidy", "x", ["needs-triage", "payments"], "money or payments"),
        ("Remove the unused avatar", "Delete the old png", ["needs-triage"], ""),
    ],
)
def test_exclusion(title, body, labels, want):
    assert _jq(_env_var("EXCLUDE"), issue(title, body, labels)) == want


@pytest.mark.parametrize(
    "p,want",
    [(0.95, "admit"), (0.9, "admit"), (0.89, "orchestrator"), (0.5, "orchestrator"), (0.11, "orchestrator"), (0.1, "decline"), (0.0, "decline")],
)
def test_bands(p, want):
    assert _jq(_env_var("BAND"), None, p=p) == want


def test_request_shape():
    out = subprocess.run(
        ["jq", "-c", _env_var("REQUEST")], input=json.dumps(issue()), capture_output=True, text=True, check=True,
        env={**os.environ, "REPO": "Nishfleet/0509"},
    ).stdout
    req = json.loads(out)
    assert req["model"] == "jev-latest"
    assert req["questions"]["admit"]["type"] == "boolean"
    assert req["state"]["title"] == "Fix the footer link colour"
    assert req["state"]["labels"] == ["needs-triage"]


def _run(tmp_path, *, repo="Nishfleet/0509", iss=None, actor="nish3451", resp=None, listed=(7,), issue_env="", cfg=CFG):
    fake = tmp_path / "fake"
    fake.mkdir(parents=True)
    home = tmp_path / "home"
    home.mkdir()
    (fake / "cfg.json").write_text(json.dumps({"content": base64.b64encode(json.dumps(cfg).encode()).decode()}))
    (fake / "list.json").write_text(json.dumps([{"number": n} for n in listed]))
    (fake / "issue.json").write_text(json.dumps(iss or issue()))
    (fake / "events.json").write_text(json.dumps([{"event": "labeled", "label": {"name": "needs-triage"}, "actor": {"login": actor}}]))
    (fake / "jev-response.json").write_text(json.dumps(resp) if resp is not None else "")
    for name, text in (("gh", FAKE_GH), ("curl", FAKE_CURL)):
        f = fake / name
        f.write_text(text)
        f.chmod(0o755)
    env = {
        **os.environ, "HOME": str(home), "PATH": f"{fake}:{os.environ['PATH']}", "FAKE_DIR": str(fake),
        "REPO": repo, "ISSUE": issue_env, "MAX_ISSUES": "20", "GITHUB_SERVER_URL": "https://github.com",
        "GITHUB_RUN_ID": "4242", "TRUSTED_LABELERS": _env_var("TRUSTED_LABELERS"),
        "EXCLUDE": _env_var("EXCLUDE"), "BAND": _env_var("BAND"), "REQUEST": _env_var("REQUEST"),
    }
    r = subprocess.run(
        ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{STEP} | .run")],
        env=env, capture_output=True, text=True,
    )
    writes = (fake / "writes.log").read_text() if (fake / "writes.log").exists() else ""
    calls = (fake / "curl.log").read_text().count("called") if (fake / "curl.log").exists() else 0
    return r, writes, calls


def _answer(p, model="jev-1.13.0"):
    return {"model": model, "answers": {"admit": {"probability": p}}}


def test_admit_adds_agent_ready(tmp_path):
    r, w, calls = _run(tmp_path, resp=_answer(0.96))
    assert r.returncode == 0, r.stderr
    assert "--add-label agent-ready --remove-label needs-triage" in w
    assert "p=0.96 (model jev-1.13.0)" in w and "actions/runs/4242" in w
    assert calls == 1


def test_decline_adds_triage_declined_and_comment_has_p(tmp_path):
    r, w, _ = _run(tmp_path, resp=_answer(0.04))
    assert r.returncode == 0, r.stderr
    assert "--add-label triage-declined --remove-label needs-triage" in w
    assert "--add-label agent-ready" not in w
    assert "p=0.04" in w


def test_middle_goes_to_orchestrator(tmp_path):
    r, w, _ = _run(tmp_path, resp=_answer(0.6))
    assert r.returncode == 0, r.stderr
    assert "--add-label needs-orchestrator --remove-label needs-triage" in w
    assert "--add-label agent-ready" not in w


def test_exclusion_never_asks_jev_and_never_admits(tmp_path):
    r, w, calls = _run(tmp_path, iss=issue("Change the Stripe key", "x"), resp=_answer(0.99))
    assert r.returncode == 0, r.stderr
    assert calls == 0
    assert "--add-label needs-orchestrator" in w and "--add-label agent-ready" not in w
    assert "p: not asked" in w


def test_fleet_ops_is_never_acted_on(tmp_path):
    r, w, calls = _run(tmp_path, repo="Nishfleet/fleet-ops", resp=_answer(0.99), cfg={"repos": [{"name": "fleet-ops", "product": True}]})
    assert r.returncode == 0 and w == "" and calls == 0


@pytest.mark.parametrize("repo", ["Nishfleet/unknown", "Nishfleet/tool"])
def test_repo_not_enrolled_or_not_product(tmp_path, repo):
    r, w, calls = _run(tmp_path, repo=repo, resp=_answer(0.99))
    assert r.returncode == 0 and w == "" and calls == 0


def test_untrusted_labeller_is_skipped(tmp_path):
    r, w, calls = _run(tmp_path, actor="someone-else", resp=_answer(0.99))
    assert r.returncode == 0 and w == "" and calls == 0


def test_no_answer_changes_nothing(tmp_path):
    r, w, _ = _run(tmp_path, resp={"error": "down"})
    assert r.returncode == 0 and w == ""


def test_issue_without_label_is_skipped(tmp_path):
    r, w, calls = _run(tmp_path, iss=issue(labels=("agent-ready",)), resp=_answer(0.99))
    assert r.returncode == 0 and w == "" and calls == 0


def test_job_condition_has_the_off_switch_and_the_fleet_ops_lock():
    cond = " ".join(_y(".jobs.admit.if").split())
    assert cond.startswith("vars.FLEET_DISPATCH_PAUSED != 'true' && vars.ADMIT_TRIAGE != 'off' && github.repository != 'Nishfleet/fleet-ops'")
