"""Claude Code lanes in .github/workflows/agent.yml, run from the workflow's own
text (read out with yq, never a copy).

Gate: strong-only work goes to claude-sonnet-5-5, and a packet that failed twice
escalates to the worker-capable pool (fleet-ops#10750). Any other issue is
classified by a stubbed Jev:
p >= 0.9 judgment goes to claude, p <= 0.1 or anything between (or a Jev error)
to the free pi lane; the decision is logged and written to the
job summary.
Worker: the claude invocation, the seat (the runner's CLAUDE_CONFIG_DIR, or the
default login when it has none; a seat with no login file hands the job to the other
seat, or skips the lane when both lack one), the rate-limit fallthrough, and the
engines-ran record the review reads.
Token auth: a seat with a one-year `claude setup-token` file
(seats/claude-seat-<x>.env) logs in with that token alone, exported from the file
into the environment, with a fresh empty CLAUDE_CONFIG_DIR; no file keeps the
login path. The log line is `claude lane: seat=<x> auth=token|login`.
Secret isolation: every other engine's jail hides the Claude seat logins; the
claude jail sees only its own seat. The real-bwrap tests prove both halves, and
that the token reaches claude through the environment only: both token files, the
backup dir and the Max dir are unreadable inside every jail.

Fakes (gh, pgrep, curl as Jev, bwrap, claude, pi, yq) live in a temp
dir. bwrap's fake drops its own options and runs the command after `--`, and
logs its argv.
"""
import json
import os
import pathlib
import shutil
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = ROOT / ".github/workflows/agent.yml"
SEATS_REL = ".config/fleet-ops/seats"  # gitleaks:allow


def _yq(expr):
    return subprocess.run(["yq", expr, str(WF)], capture_output=True, text=True, check=True).stdout


def _step(job, name):
    return _yq(f'.jobs.{job}.steps[] | select(.name == "{name}") | .run')


PGREP = """#!/bin/bash
pat=${@: -1}
eng=${pat#*-- }; eng=${eng% }
var=LIVE_${eng//-/_}
n=${!var:-0}
for ((k=0; k<n; k++)); do echo "100$k bwrap --dev-bind / / -- $eng --chdir /w/agent-worktrees/issue-x-$k"; done
"""
GH = """#!/bin/bash
case "$*" in *compare/main*) echo "${AHEAD:-0}"; exit 0 ;; esac
q=
while [ $# -gt 0 ]; do [ "$1" = --jq ] && q=$2; shift; done
case "$*$q" in *) ;; esac
if [ -n "$q" ]; then jq -r "$q" <<<"${COMMENTS_JSON:-{\\"comments\\":[]}}"; fi
"""
BWRAP = """#!/bin/bash
echo "$*" >> "$STATE/bwrap.log"
while [ "$1" != -- ]; do shift; done
shift
exec "$@"
"""
CLAUDE = """#!/bin/bash
{ echo "claude $*"; echo "CCD=${CLAUDE_CONFIG_DIR-unset}"; echo "TOK=${CLAUDE_CODE_OAUTH_TOKEN-unset}"; echo "SCRUB=${CLAUDE_CODE_SUBPROCESS_ENV_SCRUB-unset}"; echo "CCDFILES=$(ls -A "$CLAUDE_CONFIG_DIR" 2>/dev/null | wc -l)"; } >> "$STATE/claude.log"
cat > "$STATE/claude.stdin"
# CLAUDE_BAD_TOKENS: tokens the API has revoked; claude answers them with an auth error.
for bad in $CLAUDE_BAD_TOKENS; do
  if [ "$CLAUDE_CODE_OAUTH_TOKEN" = "$bad" ]; then echo "API Error: 401 authentication_error: OAuth token has been revoked" >&2; exit 1; fi
done
[ -z "$CLAUDE_OUT" ] || echo "$CLAUDE_OUT"
[ -z "$CLAUDE_ERR" ] || echo "$CLAUDE_ERR" >&2
exit "${CLAUDE_RC:-0}"
"""
# Stands in for claude under the real bwrap: reports what the jail shows it. Every
# planted file holds the word "planted"; PROBE_PATHS lists the files to try.
PROBE = """#!/bin/bash
cat > /dev/null
{
echo "ARGV=$*"
echo "ENV=${CLAUDE_CODE_OAUTH_TOKEN-unset}"
echo "CCD=${CLAUDE_CONFIG_DIR-unset}"
echo "CCDFILES=$(ls -A "$CLAUDE_CONFIG_DIR" 2>/dev/null | wc -l)"
for p in $PROBE_PATHS; do
  if grep -qr planted "$p" 2>/dev/null; then echo "READ $p"; else echo "HIDDEN $p"; fi
done
} > "$STATE/probe.log"
"""
# pi is a no-op: PATH is only the fakes plus the system dirs, so a real pi from
# the developer's own bin is never started.
NOOP = """#!/bin/bash
me=$(basename "$0")
echo "$0 $*" >> "$STATE/noop.log"
echo "$me TOK=${CLAUDE_CODE_OAUTH_TOKEN-unset} CCD=${CLAUDE_CONFIG_DIR-unset} OTHER=${OTHER-unset}" >> "$STATE/fallback-env.log"
[ "$me" = "${NOOP_FAIL:-}" ] || exit 0
[ -z "${NOOP_ERR:-}" ] || echo "$NOOP_ERR" >&2
exit 1
"""
# Jev stub: JEV_FAIL makes it exit non-zero; otherwise it answers JEV_CHOICE with JEV_P.
CURL = """#!/bin/bash
echo "$*" >> "$STATE/curl.log"
cat >/dev/null <<<""
[ -z "$JEV_FAIL" ] || exit 22
for a in "$@"; do last=$a; done
echo "$last" > "$STATE/jev-body.json"
echo "{\\"answers\\":{\\"needs_judgment\\":{\\"choice\\":\\"$JEV_CHOICE\\",\\"probabilities\\":{\\"$JEV_CHOICE\\":$JEV_P}}}}"
"""
SYS_PATH = "/usr/bin:/bin"
# pi_free's seat sum. The real yq reads the runner's copy of
# config/litellm-proxy.yaml, the same file this repo ships, so a case that needs
# a specific cap sets YQ_SLOTS instead of pointing at a second copy of the rows.
YQ = """#!/bin/bash
echo "${YQ_SLOTS:-65}"
"""


def _bin(tmp, real_bwrap=False):
    b = tmp / "bin"
    b.mkdir()
    for name, body in (("pgrep", PGREP), ("gh", GH), ("bwrap", BWRAP), ("claude", PROBE if real_bwrap else CLAUDE), ("pi", NOOP), ("yq", YQ), ("curl", CURL)):
        if real_bwrap and name == "bwrap":
            continue  # the system's bwrap is found on PATH
        (b / name).write_text(body)
        (b / name).chmod(0o755)
    home = tmp / "home"
    (home / "workspaces/tooling/fleet-ops-deploy-clone").mkdir(parents=True)
    seats = home / ".config" / "fleet-ops" / "seats"
    seats.mkdir(parents=True)
    for name in ("mobbin-mcp.env",):
        (seats / name).write_text("")
    (seats / "typesafe-jev.env").write_text("LITELLM_JEV_KEY=not-a-key\n")
    return b, home


def _comments(failed=0, login="nishfleet-worker", assoc="CONTRIBUTOR"):
    return json.dumps({"comments": [{"body": f"agent run failed: https://x/{k}", "author": {"login": login}, "authorAssociation": assoc} for k in range(failed)]})


def _gate_full(tmp_path, labels=",strong-only,", failed=0, live=None, env=None, comments=None):
    """Runs the Gate's engine routing; the issue is titled t with body b."""
    script = _step("work", "Gate")
    start = script.index("jev_env=")
    start = script.rindex("live() {", 0, start)
    end = script.index('gh issue edit "$i" -R "$REPO" --remove-label agent-ready')
    seg = script[start:end]
    b, home = _bin(tmp_path)
    prog = f'skip() {{ echo "SKIP $1"; exit 0; }}\ni=5 REPO=o/r labels="{labels}"\nissue=\'{{"title":"t","body":"b"}}\'\n{seg}\necho "engine=$engine model=$claude_model"\n'
    env = {**os.environ, "HOME": str(home), "PATH": f"{b}:{SYS_PATH}", "COMMENTS_JSON": comments or _comments(failed), **{f"LIVE_{k}": str(v) for k, v in (live or {}).items()}, **(env or {})}
    r = subprocess.run(["bash", "-c", prog], env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip().splitlines()


def _gate(*a, **kw):
    return _gate_full(*a, **kw)[-1]


def test_senior_work_goes_to_claude_sonnet(tmp_path):
    assert _gate(tmp_path) == "engine=claude model=claude-sonnet-5-5"


def test_one_failed_run_still_sonnet(tmp_path):
    assert _gate(tmp_path, failed=1) == "engine=claude model=claude-sonnet-5-5"


def test_second_strike_escalates_to_the_worker_capable_pool(tmp_path):
    assert _gate(tmp_path, failed=2) == "engine=pi model=claude-sonnet-5-5"


def test_failed_comments_from_strangers_do_not_count_toward_the_escalation(tmp_path):
    stranger = _comments(failed=3, login="someone-else", assoc="NONE")
    assert _gate(tmp_path, comments=stranger) == "engine=claude model=claude-sonnet-5-5"


def test_failed_comments_from_a_member_count_toward_the_escalation(tmp_path):
    member = _comments(failed=2, login="a-member", assoc="MEMBER")
    assert _gate(tmp_path, comments=member) == "engine=pi model=claude-sonnet-5-5"


def test_no_gate_input_resolves_to_a_reviewer_model(tmp_path):
    for k, (labels, failed) in enumerate([(",strong-only,", 0), (",bug,", 1), (",strong-only,", 2), (",bug,", 3)]):
        d = tmp_path / str(k)
        d.mkdir()
        got = _gate(d, labels=labels, failed=failed)
        assert got.endswith("model=claude-sonnet-5-5"), got


def _route(tmp_path, jev=None, labels=",bug,", live=None, env=None):
    """Runs the Gate's routing. jev = (choice, p), "fail", or None for no stub answer."""
    state = tmp_path / "state"
    state.mkdir()
    summary = tmp_path / "summary.md"
    e = {"STATE": str(state), "GITHUB_STEP_SUMMARY": str(summary), "JEV_CHOICE": "", "JEV_P": "0", "JEV_FAIL": "", **(env or {})}
    if jev == "fail":
        e["JEV_FAIL"] = "1"
    elif jev:
        e["JEV_CHOICE"], e["JEV_P"] = jev
    out = _gate_full(tmp_path, labels=labels, live=live, env=e)
    log = [ln for ln in out if ln.startswith("judgment:")]
    assert len(log) == 1, out
    assert summary.read_text().strip() == log[0], "the decision is recorded in the job summary"
    return out[-1], log[0], out, state


FREE = ("engine=pi",)


def test_judgment_p_95_goes_to_claude_sonnet(tmp_path):
    last, log, out, _ = _route(tmp_path, ("judgment", "0.95"))
    assert last == "engine=claude model=claude-sonnet-5-5"
    assert log == "judgment: p=0.95 -> claude (needs judgment)"


def test_mechanical_p_05_goes_to_the_free_lanes(tmp_path):
    # Jev answers "mechanical" at 0.95, so P(judgment) = 0.05
    last, log, _, _ = _route(tmp_path, ("mechanical", "0.95"))
    assert log == "judgment: p=0.05 -> free (mechanical)"
    assert last.split()[0] in FREE


def test_free_lanes_whatever_claude_headroom(tmp_path):
    last, _, _, _ = _route(tmp_path, ("mechanical", "0.95"), live={"claude": 0})
    assert last.split()[0] in FREE


def test_unsure_strong_only_goes_to_claude(tmp_path):
    last, log, _, state = _route(tmp_path, ("judgment", "0.5"), labels=",strong-only,")
    assert last == "engine=claude model=claude-sonnet-5-5"
    assert log == "judgment: p=n/a -> claude (strong-only label)"
    assert not (state / "curl.log").exists()  # the label decides; Jev is not asked


def test_unsure_without_strong_only_goes_to_the_free_lanes(tmp_path):
    last, log, _, _ = _route(tmp_path, ("judgment", "0.5"))
    assert log == "judgment: p=0.5 -> free (not sure enough)"
    assert last.split()[0] in FREE
    d = tmp_path / "b"
    d.mkdir()
    # 0.89 is still not enough, 0.9 is
    assert _route(d, ("judgment", "0.89"))[0].split()[0] in FREE
    d = tmp_path / "c"
    d.mkdir()
    assert _route(d, ("judgment", "0.9"))[0].startswith("engine=claude ")


def test_jev_error_falls_through_with_a_warning(tmp_path):
    last, log, out, _ = _route(tmp_path, "fail")
    assert log == "judgment: p=n/a -> free (jev-error)"
    assert any(ln.startswith("::warning::judgment") for ln in out)
    assert last.split()[0] in FREE
    d = tmp_path / "b"
    d.mkdir()
    # a strong-only issue still goes to claude when Jev is down (it is not asked)
    assert _route(d, "fail", labels=",strong-only,")[0].startswith("engine=claude ")


def test_jev_is_asked_the_question_with_the_issue_text(tmp_path):
    _, _, _, state = _route(tmp_path, ("judgment", "0.95"))
    body = json.loads((state / "jev-body.json").read_text())
    q = body["questions"]["needs_judgment"]
    assert q["instructions"] == "Does completing this issue require engineering judgment (design choice, ambiguity, multi-file reasoning, debugging), as opposed to a mechanical, fully specified change?"
    assert body["model"] == "jev-latest" and body["state"]["item"].startswith("t\n\nb")
    assert set(q["criteria"]) == {"judgment", "mechanical"}


def test_there_is_no_claude_cap(tmp_path):
    # Nothing stock gives N slots; agent.slice governs the RAM. Many live workers change nothing.
    assert _route(tmp_path, ("judgment", "0.95"), live={"claude": 40})[0].startswith("engine=claude ")


def _worker(tmp_path, engine, model="claude-sonnet-5-5", claude_rc=0, claude_out="", runner_name="netcup-agent-1", issue=5, claude_err="", login_a="x", login_b="x", tok_a=None, tok_b=None, real_bwrap=False, bad_tokens="", ahead="0", live=None):
    b, home = _bin(tmp_path, real_bwrap)
    state = tmp_path / "state"
    tmp = tmp_path / "runner-tmp"
    state.mkdir()
    tmp.mkdir()
    seat_a = home / ".claude-seat-a"
    seat_a.mkdir()
    # Fake login files (login_a / login_b: their content, None for no file). Only
    # their presence and size matter to the lane; they hold no real credential.
    (home / ".claude").mkdir()
    if login_a is not None:
        (seat_a / ".credentials.json").write_text(login_a)
    if login_b is not None:
        (home / ".claude/.credentials.json").write_text(login_b)
    for d in (".claude-auth-backup-x", "backups-claude-x", ".claude-other-seat", ".claude-max", ".local/share/claude-seat-backup"):
        (home / d).mkdir(parents=True)
        (home / d / "creds").write_text("planted")
    # One-year token files (fake values; the seats dir already exists), mode 600.
    for seat, tok in (("a", tok_a), ("b", tok_b)):
        if tok is not None:
            f = home / SEATS_REL / f"claude-seat-{seat}.env"
            f.write_text(tok[4:] if tok.startswith("RAW:") else f"CLAUDE_CODE_OAUTH_TOKEN={tok}\n" if tok else "")
            f.chmod(0o600)
    script = _step("work", "Worker")
    env = {
        **os.environ,
        "HOME": str(home),
        "PATH": f"{b}:{SYS_PATH}",
        "STATE": str(state),
        "RUNNER_TEMP": str(tmp),
        "ENGINE": engine,
        "MISS": "false",
        "REF": "claim/issue-%s-x" % issue,
        "REPO": "o/r",
        "CLAUDE_MODEL": model,
        "CLAUDE_MAX_TURNS": "200",
        "CLAUDE_RC": str(claude_rc),
        "CLAUDE_OUT": claude_out,
        "CLAUDE_ERR": claude_err,
        **{f"LIVE_{k}": str(v) for k, v in (live or {}).items()},
        "RUNNER_NAME": runner_name,
        "CLAUDE_BAD_TOKENS": bad_tokens,
        "AHEAD": ahead,
    }
    paths = [home / SEATS_REL / f"claude-seat-{x}.env" for x in "ab"] + [home / ".local/share/claude-seat-backup", home / ".claude-max", home / ".claude-other-seat", seat_a / ".credentials.json", home / ".claude/.credentials.json", home / ".claude.json"]
    env["PROBE_PATHS"] = " ".join(map(str, paths))
    env["CLAUDE_CONFIG_DIR"] = str(seat_a)  # every runner carries seat a; the lane drops it on an even runner
    r = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)

    def rd(n):
        p = state / n
        return p.read_text() if p.exists() else ""

    ran = tmp / "engines-ran"
    return r, rd("bwrap.log"), rd("claude.log"), (ran.read_text().split() if ran.exists() else []), str(seat_a), str(home)


def test_claude_lane_invocation(tmp_path):
    r, bwrap, claude, ran, seat_a, home = _worker(tmp_path, "claude", model="claude-opus-5-5")
    assert r.returncode == 0, r.stderr
    assert "--model claude-opus-5-5" in claude
    assert "--permission-mode bypassPermissions" in claude
    assert "--allowedTools Bash Read Edit Write" in claude and "mcp__chrome-devtools" in claude
    assert "--max-turns 200" in claude
    assert "Fleet issue worker" in (tmp_path / "state/claude.stdin").read_text()
    assert "-- claude -p" in bwrap and "--chdir" in bwrap and "agent-worktrees/issue-" in bwrap
    assert ran == ["claude"]


@pytest.mark.parametrize("name", ["netcup-agent-1", "netcup-agent-2", "netcup-agent-3", "netcup-agent-4", "netcup-agent-11", "netcup-agent-09", "runner-without-a-number"])
def test_odd_issue_keeps_seat_a_on_every_runner(tmp_path, name):
    r, bwrap, claude, _, seat_a, home = _worker(tmp_path, "claude", runner_name=name, issue=5)
    assert r.returncode == 0, r.stderr
    assert f"CCD={seat_a}" in claude
    assert f"claude lane: seat=a auth=login issue=5 runner={name}" in r.stdout
    assert f"--ro-bind /dev/null {home}/.claude/.credentials.json" in bwrap
    assert f"--tmpfs {seat_a}" not in bwrap
    # every other Claude dir and backup dir is hidden; only the running seat stays
    _assert_backups_hidden(bwrap, home)


@pytest.mark.parametrize("name", ["netcup-agent-1", "netcup-agent-2", "netcup-agent-4", "netcup-agent-12", "netcup-agent-22", "netcup-agent-08", "runner-without-a-number"])
def test_even_issue_unsets_the_config_dir_on_every_runner(tmp_path, name):
    r, bwrap, claude, _, seat_a, home = _worker(tmp_path, "claude", runner_name=name, issue=6)
    assert r.returncode == 0, r.stderr
    assert "CCD=unset" in claude
    assert f"claude lane: seat=b auth=login issue=6 runner={name}" in r.stdout
    assert f"--tmpfs {seat_a}" in bwrap
    assert f"--ro-bind /dev/null {home}/.claude/.credentials.json" not in bwrap
    _assert_backups_hidden(bwrap, home)


def test_seat_follows_the_issue_not_the_runner(tmp_path):
    runners = ["netcup-agent-1", "netcup-agent-2", "netcup-agent-13", "netcup-agent-99", "runner-without-a-number"]
    for i, runner in enumerate(runners):
        d = tmp_path / f"even-{i}"; d.mkdir()
        r, _, claude, _, _, _ = _worker(d, "claude", runner_name=runner, issue=9696)
        assert r.returncode == 0, r.stderr
        assert f"claude lane: seat=b auth=login issue=9696 runner={runner}" in r.stdout
        assert "CCD=unset" in claude
    for i, runner in enumerate(runners):
        d = tmp_path / f"odd-{i}"; d.mkdir()
        r, _, claude, _, seat_a, _ = _worker(d, "claude", runner_name=runner, issue=9695)
        assert r.returncode == 0, r.stderr
        assert f"claude lane: seat=a auth=login issue=9695 runner={runner}" in r.stdout
        assert f"CCD={seat_a}" in claude


@pytest.mark.parametrize("issue,seat", [("08", "b"), ("09", "a")])
def test_a_leading_zero_issue_is_read_as_decimal(tmp_path, issue, seat):
    r, _, _, ran, _, _ = _worker(tmp_path, "claude", issue=issue)
    assert r.returncode == 0, r.stderr
    assert f"claude lane: seat={seat} auth=login issue={issue}" in r.stdout
    assert ran == ["claude"]


def test_own_seat_with_a_login_is_used_without_a_warning(tmp_path):
    for i, (issue, seat) in enumerate(((5, "a"), (6, "b"))):
        d = tmp_path / str(i)
        d.mkdir()
        r, _, claude, ran, seat_a, _ = _worker(d, "claude", issue=issue)
        assert r.returncode == 0, r.stderr
        assert f"claude lane: seat={seat} auth=login issue={issue} runner=netcup-agent-1" in r.stdout
        assert "missing login" not in r.stdout and "::warning::" not in r.stdout
        assert (f"CCD={seat_a}" in claude) == (seat == "a")
        assert ran == ["claude"]


def test_odd_issue_with_seat_a_login_missing_uses_seat_b(tmp_path):
    r, bwrap, claude, ran, seat_a, home = _worker(tmp_path, "claude", issue=5, login_a=None)
    assert r.returncode == 0, r.stderr
    assert "::warning::claude lane: seat=a missing login, using seat=b" in r.stdout
    assert "claude lane: seat=b auth=login issue=5 runner=netcup-agent-1" in r.stdout
    assert "CCD=unset" in claude and ran == ["claude"]
    # the jail is seat b's: seat a hidden, the default login left readable
    assert f"--tmpfs {seat_a}" in bwrap
    assert f"--ro-bind /dev/null {home}/.claude/.credentials.json" not in bwrap


def test_even_issue_with_default_login_missing_uses_seat_a(tmp_path):
    r, bwrap, claude, ran, seat_a, home = _worker(tmp_path, "claude", issue=6, login_b=None)
    assert r.returncode == 0, r.stderr
    assert "::warning::claude lane: seat=b missing login, using seat=a" in r.stdout
    assert "claude lane: seat=a auth=login issue=6 runner=netcup-agent-1" in r.stdout
    assert f"CCD={seat_a}" in claude and ran == ["claude"]
    # the jail is seat a's: the default login hidden, seat a left readable
    assert f"--tmpfs {seat_a}" not in bwrap
    assert f"--ro-bind /dev/null {home}/.claude/.credentials.json" in bwrap
    assert f"--ro-bind /dev/null {home}/.claude.json" in bwrap


def test_an_empty_login_file_counts_as_missing(tmp_path):
    r, _, claude, _, _, _ = _worker(tmp_path, "claude", issue=5, login_a="")
    assert r.returncode == 0, r.stderr
    assert "::warning::claude lane: seat=a missing login, using seat=b" in r.stdout
    assert "CCD=unset" in claude


@pytest.mark.parametrize("issue", [5, 6])
def test_both_logins_missing_skips_the_claude_lane_and_falls_through(tmp_path, issue):
    r, bwrap, claude, ran, _, _ = _worker(tmp_path, "claude", issue=issue, login_a=None, login_b=None)
    assert r.returncode == 0, r.stderr
    assert "::warning::claude lane: seat=a and seat=b both missing login, skipping the claude lane" in r.stdout
    assert "fallthrough: pi (claude login missing)" in r.stdout
    assert claude == "" and "claude -p" not in bwrap
    assert ran == ["pi"]


def test_both_logins_missing_sends_non_senior_work_to_pi(tmp_path):
    r, _, claude, ran, _, _ = _worker(tmp_path, "claude", login_a=None, login_b=None)
    assert r.returncode == 0, r.stderr
    assert "fallthrough: pi (claude login missing)" in r.stdout
    assert claude == "" and ran == ["pi"]


def test_claude_worker_runs_with_hooks_disabled(tmp_path):
    r, _, claude, _, _, _ = _worker(tmp_path, "claude")
    assert r.returncode == 0, r.stderr
    assert """--settings {"disableAllHooks":true}""" in claude


def test_rate_limited_claude_falls_through_to_pi(tmp_path):
    r, _, claude, ran, _, _ = _worker(tmp_path, "claude", claude_rc=1, claude_out="API Error: 429 rate limit")
    assert r.returncode == 0, r.stderr
    assert "claude -p" in claude
    assert ran == ["claude", "pi"]


def test_other_claude_failure_does_not_fall_through(tmp_path):
    r, _, _, ran, _, _ = _worker(tmp_path, "claude", claude_rc=1, claude_out="some other error")
    assert r.returncode == 1 and ran == ["claude"]


def test_rate_limit_wording_early_in_the_output_is_not_a_refused_seat(tmp_path):
    # The model's own text mentions rate limits; the run then stops on the turn cap.
    out = "fixed the rate limit handling\nand the 429 retry\nmore work\nmore work\nmore work\nError: Reached max turns (200)"
    r, _, _, ran, _, _ = _worker(tmp_path, "claude", claude_rc=1, claude_out=out)
    assert r.returncode == 1 and ran == ["claude"]
    assert "429" not in r.stderr


@pytest.mark.parametrize("engine", ["pi"])
def test_other_engines_jail_hides_both_seat_logins(tmp_path, engine):
    r, bwrap, _, ran, seat_a, home = _worker(tmp_path, engine)
    # pi's seat file and the engine binaries are absent here; the jail line is what is tested.
    assert bwrap, r.stderr
    assert f"--tmpfs {seat_a}" in bwrap
    assert f"--ro-bind /dev/null {home}/.claude/.credentials.json" in bwrap
    assert f"--ro-bind /dev/null {home}/.claude.json" in bwrap
    _assert_backups_hidden(bwrap, home)


def _assert_backups_hidden(bwrap, home):
    for d in (".claude-auth-backup-x", "backups-claude-x", ".claude-other-seat"):
        assert f"--tmpfs {home}/{d}" in bwrap, d


def _jail_lines():
    script = _step("work", "Worker")
    out = {}
    for ln in script.splitlines():
        t = ln.strip()
        for name in ("jail_base", "claude_jail_a", "claude_jail_b"):
            if t.startswith(name + '="'):
                out[name] = t[len(name) + 2:-1]
    assert set(out) == {"jail_base", "claude_jail_a", "claude_jail_b"}
    return out


def _real_bwrap_ok():
    if not shutil.which("bwrap"):
        return False
    return subprocess.run(["bwrap", "--dev-bind", "/", "/", "--", "true"], capture_output=True).returncode == 0


def _hide_fn():
    for ln in _step("work", "Worker").splitlines():
        if ln.strip().startswith("claude_hides()"):
            return ln.strip()
    raise AssertionError("claude_hides not found")


def _hides(home, keep):
    r = subprocess.run(["bash", "-c", f'{_hide_fn()}\nclaude_hides "$1"', "x", keep], env={"HOME": str(home), "PATH": SYS_PATH}, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


def _lane_seat(issue, home, seat_a_dir, runner_name="netcup-agent-1"):
    """Runs the lane's own seat lines (parity, then the login check) against real
    files under home and returns (seat, whether CLAUDE_CONFIG_DIR survives)."""
    lines = _step("work", "Worker").splitlines()
    a = next(i for i, ln in enumerate(lines) if ln.strip().startswith("seat_a_dir="))
    b = next(i for i, ln in enumerate(lines) if ln.strip().startswith('if [ "$claude_seat" = a ]; then claude_jail='))
    prog = "live() { echo 0; }\nENGINE=claude fallback=pi\nid=r-%s\n" % issue + "\n".join(lines[a:b]) + '\necho "$claude_seat ${CLAUDE_CONFIG_DIR:-unset}"\n'
    r = subprocess.run(["bash", "-c", prog], env={"HOME": str(home), "RUNNER_TEMP": str(home), "RUNNER_NAME": runner_name, "CLAUDE_CONFIG_DIR": str(seat_a_dir), "PATH": SYS_PATH}, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    seat, cfg = r.stdout.splitlines()[-1].split()
    return seat, cfg != "unset"


def test_a_non_numeric_id_keeps_seat_a(tmp_path):
    home = tmp_path / "home"
    seat_a = home / ".claude-seat"
    (home / ".claude").mkdir(parents=True)
    (home / ".config/gh").mkdir(parents=True)
    seat_a.mkdir()
    (seat_a / ".credentials.json").write_text("planted")
    assert _lane_seat("miss", home, seat_a) == ("a", True)


@pytest.mark.skipif(not _real_bwrap_ok(), reason="bwrap cannot run here")
@pytest.mark.parametrize("issue,missing,final", [
    (5, None, "a"),
    (6, None, "b"),
    (5, "a", "b"),  # own login missing: the lane moves to the other seat
    (6, "b", "a"),
])
def test_real_jail_claude_lane_reads_only_its_own_seat_and_nobody_reads_the_rest(tmp_path, issue, missing, final):
    """Real bwrap, an odd and an even issue. The lane's own issue-parity rule picks the seat:
    odd keeps CLAUDE_CONFIG_DIR (seat a), even unsets it (seat b); a missing login moves it to the
    other seat. The Worker then uses the already-hidden gh dir as the stand-in `seat_a` for
    seat b's jail. The jail shows only the seat finally used."""
    home = tmp_path / "home"
    seat_a = home / ".claude-seat"
    (home / ".claude").mkdir(parents=True)
    (home / ".config/gh").mkdir(parents=True)
    (home / "workspaces/tooling/fleet-ops-deploy-clone").mkdir(parents=True)
    seat_a.mkdir()
    # The Max dir and the credential backups sit beside the seats and are never readable.
    backups = [home / ".claude-auth-backup-x", home / "backups-claude-x", home / ".claude-max"]
    for d in backups:
        d.mkdir()
        (d / "creds").write_text("planted")
    (home / ".claude-backup.json").write_text("planted")  # a plain file matching the glob
    for p in (seat_a / ".credentials.json", home / ".claude/.credentials.json", home / ".claude.json"):
        p.write_text("planted")
    if missing:  # this seat has no login; the lane's check sees no file
        ((seat_a / ".credentials.json") if missing == "a" else (home / ".claude/.credentials.json")).unlink()
    seat, keeps_cfg = _lane_seat(issue, home, seat_a)
    assert (seat, keeps_cfg) == (final, final == "a")
    lines = _jail_lines()
    seat_b = seat == "b"
    jail_seat = home / ".config/gh" if seat_b else seat_a  # the Worker's seat_a=${CLAUDE_CONFIG_DIR:-$HOME/.config/gh}
    sub = {"hide_all": _hides(home, ""), "hide_but_a": _hides(home, str(jail_seat))}

    def expand(name):
        line = lines[name].replace("$HOME", str(home)).replace("$seat_a", str(jail_seat))
        for k, v in sub.items():
            line = line.replace("$" + k, v)
        return line.split() + ["--"]

    def read_all(name):
        cmd = expand(name)
        out = {}
        paths = {"a": seat_a / ".credentials.json", "b": home / ".claude/.credentials.json", "cj": home / ".claude.json", "file": home / ".claude-backup.json"}
        paths.update({f"bk{i}": d / "creds" for i, d in enumerate(backups)})
        for key, path in paths.items():
            r = subprocess.run(cmd + ["cat", str(path)], capture_output=True, text=True)
            out[key] = "planted" in r.stdout
        return out

    none = {k: False for k in ("b", "cj", "file", "bk0", "bk1", "bk2")}
    # Every other engine reads no login at all.
    assert read_all("jail_base") == {"a": False, **none}
    # The claude lane reads the seat the issue's parity picks and nothing else: no other
    # seat, no Max dir, no backup, no plain backup file.
    if seat_b:
        assert read_all("claude_jail_b") == {"a": False, **{**none, "b": True, "cj": True}}
    else:
        assert read_all("claude_jail_a") == {"a": True, **none}


TOK = "tok-%s-planted"


def _tok_env(seat):
    return TOK % seat


@pytest.mark.parametrize("name,seat", [("netcup-agent-1", "a"), ("netcup-agent-2", "b")])
def test_seat_with_a_token_file_logs_in_with_the_token_and_an_empty_config_dir(tmp_path, name, seat):
    r, bwrap, claude, ran, seat_a, home = _worker(tmp_path, "claude", runner_name=name, issue={"a": 5, "b": 6}[seat], tok_a=_tok_env("a"), tok_b=_tok_env("b"))
    assert r.returncode == 0, r.stderr
    assert f"claude lane: seat={seat} auth=token issue={5 if seat == 'a' else 6} runner={name}" in r.stdout
    assert f"TOK={_tok_env(seat)}" in claude and _tok_env("b" if seat == "a" else "a") not in claude
    # a fresh, empty CLAUDE_CONFIG_DIR inside the job's temp dir, not the seat's login dir
    ccd = next(ln for ln in claude.splitlines() if ln.startswith("CCD="))[4:]
    assert ccd.startswith(str(tmp_path / "runner-tmp") + "/") and ccd != seat_a
    assert "CCDFILES=0" in claude
    assert f"::add-mask::{_tok_env(seat)}" in r.stdout
    assert "::warning::" not in r.stdout and ran == ["claude"]
    # the token is never on a command line, in the log or on stderr
    assert _tok_env(seat) not in bwrap and _tok_env(seat) not in r.stderr
    assert _tok_env(seat) not in r.stdout.replace(f"::add-mask::{_tok_env(seat)}", "")
    # token auth needs no login: the jail is the one that hides them all
    assert f"--tmpfs {seat_a}" in bwrap and f"--ro-bind /dev/null {home}/.claude/.credentials.json" in bwrap


def test_token_seat_needs_no_login_file(tmp_path):
    r, _, claude, ran, _, _ = _worker(tmp_path, "claude", runner_name="netcup-agent-3", login_a=None, login_b=None, tok_a=_tok_env("a"))
    assert r.returncode == 0, r.stderr
    assert "claude lane: seat=a auth=token" in r.stdout and "missing login" not in r.stdout
    assert f"TOK={_tok_env('a')}" in claude and ran == ["claude"]


def test_missing_token_file_keeps_the_login_and_the_fallback(tmp_path):
    # seat a has no token file and no login: today's fallback to seat b's login; seat b's token
    # file is not read (it exists only to prove that).
    r, _, claude, ran, _, _ = _worker(tmp_path, "claude", runner_name="netcup-agent-3", login_a=None, tok_b=_tok_env("b"))
    assert r.returncode == 0, r.stderr
    assert "::warning::claude lane: seat=a missing login, using seat=b" in r.stdout
    assert "claude lane: seat=b auth=login issue=5 runner=netcup-agent-3" in r.stdout
    assert "TOK=unset" in claude and "CCD=unset" in claude and _tok_env("b") not in claude and ran == ["claude"]


def test_empty_token_file_counts_as_missing(tmp_path):
    r, _, claude, _, seat_a, _ = _worker(tmp_path, "claude", runner_name="netcup-agent-1", tok_a="")
    assert r.returncode == 0, r.stderr
    assert "claude lane: seat=a auth=login" in r.stdout
    assert "TOK=unset" in claude and f"CCD={seat_a}" in claude


def test_token_file_without_a_token_falls_back_to_the_login(tmp_path):
    r, _, claude, _, seat_a, _ = _worker(tmp_path, "claude", runner_name="netcup-agent-1", tok_a="RAW:OTHER=1\n")
    assert r.returncode == 0, r.stderr
    assert "::warning::claude lane: seat=a token file has no token, using the login" in r.stdout
    assert "claude lane: seat=a auth=login" in r.stdout
    assert "TOK=unset" in claude and f"CCD={seat_a}" in claude


def _probe(tmp_path, **kw):
    r, bwrap, _, _, seat_a, home = _worker(tmp_path, "claude", real_bwrap=True, **kw)
    assert r.returncode == 0, r.stderr
    rows = (tmp_path / "state/probe.log").read_text().splitlines()
    seen = {ln.split(" ", 1)[1].replace(home + "/", ""): ln.split(" ", 1)[0] for ln in rows if ln.startswith(("READ ", "HIDDEN "))}
    kv = dict(ln.split("=", 1) for ln in rows if "=" in ln and not ln.startswith(("READ", "HIDDEN")))
    return r, kv, seen, home


@pytest.mark.skipif(not _real_bwrap_ok(), reason="bwrap cannot run here")
@pytest.mark.parametrize("name,seat", [("netcup-agent-1", "a"), ("netcup-agent-2", "b")])
def test_real_jail_token_present_reaches_claude_through_the_environment_only(tmp_path, name, seat):
    r, kv, seen, home = _probe(tmp_path, runner_name=name, issue={"a": 5, "b": 6}[seat], login_a="planted", login_b="planted", tok_a=_tok_env("a"), tok_b=_tok_env("b"))
    assert f"claude lane: seat={seat} auth=token" in r.stdout
    assert kv["ENV"] == _tok_env(seat)  # in the environment ...
    assert kv["CCDFILES"] == "0" and kv["CCD"].startswith(str(tmp_path / "runner-tmp"))
    assert _tok_env(seat) not in kv["ARGV"]
    # ... and nowhere on disk: both token files, the backup dir, the Max dir and every login are hidden
    assert seen and set(seen.values()) == {"HIDDEN"}, seen
    assert f"{SEATS_REL}/claude-seat-a.env" in seen and f"{SEATS_REL}/claude-seat-b.env" in seen
    assert ".local/share/claude-seat-backup" in seen and ".claude-max" in seen


@pytest.mark.skipif(not _real_bwrap_ok(), reason="bwrap cannot run here")
@pytest.mark.parametrize("name,seat", [("netcup-agent-1", "a"), ("netcup-agent-2", "b")])
def test_real_jail_token_missing_keeps_the_login_and_hides_the_other_seats_token(tmp_path, name, seat):
    other = "b" if seat == "a" else "a"
    # only the other seat has a token file; the chosen seat has none, so it uses its login
    r, kv, seen, home = _probe(tmp_path, runner_name=name, issue={"a": 5, "b": 6}[seat], login_a="planted", login_b="planted", **{f"tok_{other}": _tok_env(other)})
    assert f"claude lane: seat={seat} auth=login" in r.stdout
    assert kv["ENV"] == "unset"
    login = ".claude-other-seat"  # not a seat; hidden by the glob
    assert seen[f"{SEATS_REL}/claude-seat-{other}.env"] == "HIDDEN"
    assert seen[".local/share/claude-seat-backup"] == "HIDDEN" and seen[".claude-max"] == "HIDDEN" and seen[login] == "HIDDEN"
    # the chosen seat's login is readable, the other seat's is hidden
    a_login = next(k for k in seen if k.endswith(".claude-seat-a/.credentials.json"))
    b_login = ".claude/.credentials.json"
    assert (seen[a_login], seen[b_login]) == (("READ", "HIDDEN") if seat == "a" else ("HIDDEN", "READ"))


@pytest.mark.skipif(not _real_bwrap_ok(), reason="bwrap cannot run here")
@pytest.mark.parametrize("engine", ["pi"])
def test_real_jail_other_engines_cannot_read_either_token_file_or_the_backups(tmp_path, engine):
    # Another engine's jail (jail_base) hides both token files and the backup dir.
    lines = _jail_lines()
    home = tmp_path / "home"
    seats = home / SEATS_REL
    seats.mkdir(parents=True)
    (home / "workspaces/tooling/fleet-ops-deploy-clone").mkdir(parents=True)
    (home / ".config/gh").mkdir(parents=True)
    (home / ".claude").mkdir()
    bk = home / ".local/share/claude-seat-backup"
    bk.mkdir(parents=True)
    (bk / "creds").write_text("planted")
    for x in "ab":
        (seats / f"claude-seat-{x}.env").write_text(f"CLAUDE_CODE_OAUTH_TOKEN={_tok_env(x)}\n")
    line = lines["jail_base"].replace("$HOME", str(home)).replace("$seat_a", str(home / ".config/gh")).replace("$hide_all", _hides(home, ""))
    for path in (seats / "claude-seat-a.env", seats / "claude-seat-b.env", bk / "creds"):
        r = subprocess.run(line.split() + ["--", "cat", str(path)], capture_output=True, text=True)
        assert "planted" not in r.stdout, path


def test_judgment_job_rate_limited_falls_through_to_pi(tmp_path):
    r, _, claude, ran, _, _ = _worker(tmp_path, "claude", claude_rc=1, claude_out="429 rate limit")
    assert r.returncode == 0, r.stderr
    assert "claude -p" in claude and ran == ["claude", "pi"]


def _fallback_env(tmp_path):
    p = tmp_path / "state/fallback-env.log"
    return p.read_text() if p.exists() else ""


@pytest.mark.parametrize("name,seat", [("netcup-agent-1", "a"), ("netcup-agent-2", "b")])
def test_token_never_reaches_the_engine_a_rate_limit_falls_through_to(tmp_path, name, seat):
    # A refused seat sends the packet to pi: that engine must not inherit the
    # seat's non-rotating token, nor the lane's temp config dir.
    r, _, claude, ran, _, _ = _worker(tmp_path, "claude", runner_name=name, issue={"a": 5, "b": 6}[seat], claude_rc=1, claude_out="429 rate limit", tok_a=_tok_env("a"), tok_b=_tok_env("b"))
    assert r.returncode == 0, r.stderr
    assert f"TOK={_tok_env(seat)}" in claude  # claude itself had it
    assert "fallthrough: pi (claude rate limit)" in r.stdout and ran == ["claude", "pi"]
    env = _fallback_env(tmp_path)
    assert "pi TOK=unset" in env, env
    assert "claude-config" not in env and _tok_env("a") not in env and _tok_env("b") not in env


def test_token_file_is_parsed_not_run_and_defines_nothing_else(tmp_path):
    # A token file is read, never sourced: its other lines run no code and export nothing.
    marker = tmp_path / "ran-as-shell"
    raw = f"RAW:OTHER=1\ntouch {marker}\nCLAUDE_CODE_OAUTH_TOKEN={_tok_env('a')}\n"
    r, _, claude, ran, _, _ = _worker(tmp_path, "claude", runner_name="netcup-agent-1", claude_rc=1, claude_out="429 rate limit", tok_a=raw)
    assert r.returncode == 0, r.stderr
    assert f"TOK={_tok_env('a')}" in claude and "auth=token" in r.stdout
    assert not marker.exists()
    assert "pi TOK=unset" in _fallback_env(tmp_path) and "OTHER=unset" in _fallback_env(tmp_path)


def _tokens_tried(claude):
    return [ln[4:] for ln in claude.splitlines() if ln.startswith("TOK=")]


@pytest.mark.parametrize("name,seat,other", [("netcup-agent-1", "a", "b"), ("netcup-agent-2", "b", "a")])
def test_revoked_token_retries_once_with_the_other_seats_token(tmp_path, name, seat, other):
    r, bwrap, claude, ran, _, _ = _worker(tmp_path, "claude", runner_name=name, issue={"a": 5, "b": 6}[seat], tok_a=_tok_env("a"), tok_b=_tok_env("b"), bad_tokens=_tok_env(seat))
    assert r.returncode == 0, r.stderr
    assert _tokens_tried(claude) == [_tok_env(seat), _tok_env(other)]
    assert f"::warning::claude lane: seat={seat} token rejected, retrying with seat={other}" in r.stdout
    assert f"claude lane: seat={other} auth=token retry=after-auth-failure" in r.stdout
    assert f"::add-mask::{_tok_env(other)}" in r.stdout
    assert ran == ["claude"] and _fallback_env(tmp_path) == ""
    # each attempt had its own empty config dir, and nothing is left behind
    assert claude.count("CCDFILES=0") == 2
    assert not list((tmp_path / "runner-tmp").glob("claude-config*"))
    assert _tok_env(seat) not in bwrap and _tok_env(other) not in bwrap and _tok_env(other) not in r.stderr


def test_auth_failure_after_work_was_pushed_does_not_rerun_the_packet(tmp_path):
    # the closing text can mention a 401 on a run that did real work: no second run
    r, _, claude, ran, _, _ = _worker(tmp_path, "claude", runner_name="netcup-agent-1", tok_a=_tok_env("a"), tok_b=_tok_env("b"), bad_tokens=_tok_env("a"), ahead="2")
    assert r.returncode == 1
    assert _tokens_tried(claude) == [_tok_env("a")] and "retrying" not in r.stdout


def test_token_run_scrubs_the_tool_environment_and_the_file_may_quote_the_value(tmp_path):
    r, _, claude, _, _, _ = _worker(tmp_path, "claude", runner_name="netcup-agent-1", tok_a=f'RAW:CLAUDE_CODE_OAUTH_TOKEN="{_tok_env("a")}" \n')
    assert r.returncode == 0, r.stderr
    assert f"TOK={_tok_env('a')}" in claude and "SCRUB=1" in claude


def test_login_run_leaves_the_scrub_setting_alone(tmp_path):
    r, _, claude, _, _, _ = _worker(tmp_path, "claude", runner_name="netcup-agent-1")
    assert r.returncode == 0, r.stderr
    assert "SCRUB=unset" in claude


def test_revoked_token_with_no_token_on_the_other_seat_fails_the_run(tmp_path):
    r, _, claude, ran, _, _ = _worker(tmp_path, "claude", runner_name="netcup-agent-1", tok_a=_tok_env("a"), bad_tokens=_tok_env("a"))
    assert r.returncode == 1
    assert _tokens_tried(claude) == [_tok_env("a")] and "retrying" not in r.stdout
    assert "authentication_error" in r.stderr and _fallback_env(tmp_path) == ""


def test_both_tokens_revoked_fails_once_each_and_does_not_fall_through(tmp_path):
    r, _, claude, ran, _, _ = _worker(tmp_path, "claude", runner_name="netcup-agent-1", tok_a=_tok_env("a"), tok_b=_tok_env("b"), bad_tokens=f"{_tok_env('a')} {_tok_env('b')}")
    assert r.returncode == 1
    assert _tokens_tried(claude) == [_tok_env("a"), _tok_env("b")]  # exactly one retry
    assert ran == ["claude"] and _fallback_env(tmp_path) == ""
    assert not list((tmp_path / "runner-tmp").glob("claude-config*"))


def test_rate_limit_is_not_an_auth_failure_and_does_not_retry(tmp_path):
    r, _, claude, ran, _, _ = _worker(tmp_path, "claude", runner_name="netcup-agent-1", claude_rc=1, claude_out="429 rate limit", tok_a=_tok_env("a"), tok_b=_tok_env("b"))
    assert r.returncode == 0, r.stderr
    assert _tokens_tried(claude) == [_tok_env("a")] and "retrying" not in r.stdout and ran == ["claude", "pi"]


def test_login_seat_auth_error_does_not_retry_with_a_token(tmp_path):
    # the retry is for token auth only: a login seat keeps today's behaviour
    r, _, claude, _, _, _ = _worker(tmp_path, "claude", runner_name="netcup-agent-1", claude_rc=1, claude_err="API Error: 401 authentication_error", tok_b=_tok_env("b"))
    assert r.returncode == 1
    assert _tokens_tried(claude) == ["unset"] and "retrying" not in r.stdout


@pytest.mark.parametrize("rc", [0, 1])
def test_the_temp_config_dir_is_deleted_on_every_exit_path(tmp_path, rc):
    r, _, claude, _, _, _ = _worker(tmp_path, "claude", runner_name="netcup-agent-1", claude_rc=rc, tok_a=_tok_env("a"))
    assert r.returncode == rc
    assert "CCDFILES=0" in claude and "claude-config" in claude  # it existed during the run
    assert not list((tmp_path / "runner-tmp").glob("claude-config*"))


def test_hides_hides_the_target_of_a_symlink_and_skips_a_dangling_one(tmp_path):
    home = tmp_path / "home"
    vault = tmp_path / "vault"
    (vault / "backup").mkdir(parents=True)
    (vault / "tok.env").write_text("planted")
    seats = home / SEATS_REL
    seats.mkdir(parents=True)
    (home / ".local/share").mkdir(parents=True)
    (home / ".local/share/claude-seat-backup").symlink_to(vault / "backup")
    (seats / "claude-seat-a.env").symlink_to(vault / "tok.env")
    (seats / "claude-seat-b.env").symlink_to(vault / "gone.env")  # points nowhere
    out = _hides(home, "")
    assert f"--tmpfs {vault}/backup" in out and f"--ro-bind /dev/null {vault}/tok.env" in out
    assert "gone.env" not in out
    # the seat dir the lane runs on stays visible even when reached through a link
    keep = _hides(home, str(vault / "backup"))
    assert f"--tmpfs {vault}/backup" not in keep and f"--ro-bind /dev/null {vault}/tok.env" in keep


@pytest.mark.skipif(not _real_bwrap_ok(), reason="bwrap cannot run here")
def test_real_jail_hides_a_symlinked_token_file_and_backup_dir(tmp_path):
    lines = _jail_lines()
    home = tmp_path / "home"
    vault = tmp_path / "vault"
    (vault / "backup").mkdir(parents=True)
    (vault / "backup/creds").write_text("planted")
    (vault / "tok.env").write_text("planted")
    seats = home / SEATS_REL
    seats.mkdir(parents=True)
    (home / "workspaces/tooling/fleet-ops-deploy-clone").mkdir(parents=True)
    (home / ".config/gh").mkdir(parents=True)
    (home / ".claude").mkdir()
    (home / ".local/share").mkdir(parents=True)
    (home / ".local/share/claude-seat-backup").symlink_to(vault / "backup")
    (seats / "claude-seat-a.env").symlink_to(vault / "tok.env")
    line = lines["jail_base"].replace("$HOME", str(home)).replace("$seat_a", str(home / ".config/gh")).replace("$hide_all", _hides(home, ""))
    for path in (seats / "claude-seat-a.env", home / ".local/share/claude-seat-backup/creds", vault / "tok.env", vault / "backup/creds"):
        r = subprocess.run(line.split() + ["--", "cat", str(path)], capture_output=True, text=True)
        assert "planted" not in r.stdout, path


DUP_GH = """#!/bin/bash
echo "gh $*" >> "$STATE/gh.log"
case "$1 $2" in "issue list") [ -z "$LIST_FAIL" ] || exit 1; echo "$OPEN_JSON" ;; esac
"""


def _dup_gate(tmp_path, title, open_issues, list_fail=""):
    """Runs the Gate's duplicate-alert block (fleet-ops#10348) for issue 50 against a fake gh."""
    script = _step("work", "Gate")
    start = script.index("# A still-firing alert re-files")
    end = script.index("skip duplicate-alert; fi\n", start)
    end = script.index("fi\n", end + len("skip duplicate-alert; fi\n")) + 3
    b = tmp_path / "bin"
    b.mkdir()
    (b / "gh").write_text(DUP_GH)
    (b / "gh").chmod(0o755)
    issue = json.dumps({"title": title, "body": "b"})
    prog = f'skip() {{ echo "SKIP $1"; exit 0; }}\ni=50 REPO=o/r\nissue={json.dumps(issue)}\n{script[start:end]}\necho PROCEED\n'
    env = {**os.environ, "PATH": f"{b}:{SYS_PATH}", "STATE": str(tmp_path), "OPEN_JSON": json.dumps(open_issues), "LIST_FAIL": list_fail}
    r = subprocess.run(["bash", "-e", "-c", prog], env=env, capture_output=True, text=True)
    if list_fail:
        return r.returncode, r.stdout
    assert r.returncode == 0, r.stderr
    log = (tmp_path / "gh.log").read_text() if (tmp_path / "gh.log").exists() else ""
    return r.stdout.strip().splitlines()[-1], log


ALERT = "alert: SystemUnitFailed restic-r2-size-guard.service"


def test_alert_with_an_older_open_twin_is_closed_as_its_duplicate(tmp_path):
    out, log = _dup_gate(tmp_path, ALERT, [{"number": 50, "title": ALERT}, {"number": 41, "title": ALERT}, {"number": 30, "title": ALERT + " x"}])
    assert out == "SKIP duplicate-alert"
    assert "gh issue close 50 -R o/r --duplicate-of 41 --comment duplicate: the alert is still firing; #41 is open for it" in log
    assert "comment 41" not in log and "issue comment" not in log, "the older issue gets no comment"


def test_alert_without_an_open_twin_proceeds(tmp_path):
    out, log = _dup_gate(tmp_path, ALERT, [{"number": 50, "title": ALERT}, {"number": 60, "title": ALERT}, {"number": 30, "title": ALERT + " x"}])
    assert out == "PROCEED"
    assert "issue close" not in log


def test_non_alert_title_skips_the_lookup(tmp_path):
    out, log = _dup_gate(tmp_path, "grafana alert: DatasourceError", [{"number": 41, "title": "grafana alert: DatasourceError"}])
    assert out == "PROCEED"
    assert log == ""


def test_a_failed_twin_lookup_fails_the_gate_loud(tmp_path):
    rc, out = _dup_gate(tmp_path, ALERT, [], list_fail="1")
    assert rc != 0 and "PROCEED" not in out
