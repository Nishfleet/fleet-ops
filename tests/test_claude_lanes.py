"""Claude Code lanes in .github/workflows/agent.yml, run from the workflow's own
text (read out with yq, never a copy).

Gate: strong-only work goes to claude-sonnet-5-5, or claude-opus-5-5 after two
failed runs or with needs-opus. Any other issue is classified by a stubbed Jev:
p >= 0.9 judgment goes to claude, p <= 0.1 or anything between (or a Jev error)
to the free pi, opencode, devin order; the decision is logged and written to the
job summary.
Worker: the claude invocation, the seat (the runner's CLAUDE_CONFIG_DIR, or the
default login when it has none), the rate-limit fallthrough, and the
engines-ran record the review reads.
Secret isolation: every other engine's jail hides the Claude seat logins; the
claude jail sees only its own seat. The real-bwrap test proves both halves.

Fakes (gh, pgrep, curl as Jev, bwrap, claude, cursor-agent) live in a temp
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
{ echo "claude $*"; echo "CCD=${CLAUDE_CONFIG_DIR-unset}"; } >> "$STATE/claude.log"
cat > "$STATE/claude.stdin"
[ -z "$CLAUDE_OUT" ] || echo "$CLAUDE_OUT"
[ -z "$CLAUDE_ERR" ] || echo "$CLAUDE_ERR" >&2
exit "${CLAUDE_RC:-0}"
"""
CURSOR = """#!/bin/bash
echo "cursor-agent $*" >> "$STATE/cursor.log"
"""
# Every other engine is a no-op: PATH is only the fakes plus the system dirs, so a
# real pi, devin or opencode from the developer's own bin is never started.
NOOP = """#!/bin/bash
echo "$0 $*" >> "$STATE/noop.log"
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


def _bin(tmp):
    b = tmp / "bin"
    b.mkdir()
    for name, body in (("pgrep", PGREP), ("gh", GH), ("bwrap", BWRAP), ("claude", CLAUDE), ("cursor-agent", CURSOR), ("pi", NOOP), ("devin", NOOP), ("opencode", NOOP), ("curl", CURL)):
        (b / name).write_text(body)
        (b / name).chmod(0o755)
    home = tmp / "home"
    (home / "workspaces/tooling/fleet-ops-deploy-clone").mkdir(parents=True)
    seats = home / ".config" / "fleet-ops" / "seats"
    seats.mkdir(parents=True)
    for name in ("cursor.env", "cursor-2.env", "mobbin-mcp.env"):
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
    prog = f'skip() {{ echo "SKIP $1"; exit 0; }}\ni=5 REPO=o/r labels="{labels}"\nissue=\'{{"title":"t","body":"b"}}\'\n{seg}\necho "senior=$senior"\necho "engine=$engine model=$claude_model"\n'
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


def test_second_strike_goes_to_claude_opus(tmp_path):
    assert _gate(tmp_path, failed=2) == "engine=claude model=claude-opus-5-5"


def test_failed_comments_from_strangers_do_not_count_toward_opus(tmp_path):
    stranger = _comments(failed=3, login="someone-else", assoc="NONE")
    assert _gate(tmp_path, comments=stranger) == "engine=claude model=claude-sonnet-5-5"


def test_failed_comments_from_a_member_count_toward_opus(tmp_path):
    member = _comments(failed=2, login="a-member", assoc="MEMBER")
    assert _gate(tmp_path, comments=member) == "engine=claude model=claude-opus-5-5"


def test_needs_opus_label_goes_to_claude_opus(tmp_path):
    assert _gate(tmp_path, labels=",strong-only,needs-opus,") == "engine=claude model=claude-opus-5-5"


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


FREE = ("engine=pi", "engine=opencode", "engine=devin")


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
    d = tmp_path / "b"
    d.mkdir()
    assert _gate(d, live={"claude": 40, "cursor_agent": 1}).startswith("engine=claude ")


def test_needs_opus_picks_opus_and_only_claude_jobs_are_senior(tmp_path):
    last, _, out, _ = _route(tmp_path, ("judgment", "0.95"), labels=",bug,needs-opus,")
    assert last == "engine=claude model=claude-opus-5-5" and "senior=false" in out
    d = tmp_path / "b"
    d.mkdir()
    assert "senior=true" in _route(d, labels=",strong-only,")[2]


def _worker(tmp_path, engine, model="claude-sonnet-5-5", claude_rc=0, claude_out="", cursor_live=0, cfg_dir=True, senior="true", claude_err=""):
    b, home = _bin(tmp_path)
    state = tmp_path / "state"
    tmp = tmp_path / "runner-tmp"
    state.mkdir()
    tmp.mkdir()
    seat_a = home / ".claude-seat-a"
    seat_a.mkdir()
    for d in (".claude-auth-backup-x", "backups-claude-x", ".claude-other-seat"):
        (home / d).mkdir()
        (home / d / "creds").write_text("planted")
    script = _step("work", "Worker")
    env = {
        **os.environ,
        "HOME": str(home),
        "PATH": f"{b}:{SYS_PATH}",
        "STATE": str(state),
        "RUNNER_TEMP": str(tmp),
        "ENGINE": engine,
        "MISS": "false",
        "REF": "claim/issue-5-x",
        "REPO": "o/r",
        "CLAUDE_MODEL": model,
        "CLAUDE_MAX_TURNS": "200",
        "SENIOR": senior,
        "CLAUDE_RC": str(claude_rc),
        "CLAUDE_OUT": claude_out,
        "CLAUDE_ERR": claude_err,
        "LIVE_cursor_agent": str(cursor_live),
    }
    env.pop("CLAUDE_CONFIG_DIR", None)
    if cfg_dir:
        env["CLAUDE_CONFIG_DIR"] = str(seat_a)
    r = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)

    def rd(n):
        p = state / n
        return p.read_text() if p.exists() else ""

    ran = tmp / "engines-ran"
    return r, rd("bwrap.log"), rd("claude.log"), rd("cursor.log"), (ran.read_text().split() if ran.exists() else []), str(seat_a), str(home)


def test_claude_lane_invocation(tmp_path):
    r, bwrap, claude, cursor, ran, seat_a, home = _worker(tmp_path, "claude", model="claude-opus-5-5")
    assert r.returncode == 0, r.stderr
    assert "--model claude-opus-5-5" in claude
    assert "--permission-mode bypassPermissions" in claude
    assert "--max-turns 200" in claude
    assert "Fleet issue worker" in (tmp_path / "state/claude.stdin").read_text()
    assert "-- claude -p" in bwrap and "--chdir" in bwrap and "agent-worktrees/issue-" in bwrap
    assert ran == ["claude"] and cursor == ""


def test_seat_a_runner_keeps_its_dir_and_hides_the_default_login(tmp_path):
    r, bwrap, claude, _, _, seat_a, home = _worker(tmp_path, "claude")
    assert f"CCD={seat_a}" in claude
    assert f"--ro-bind /dev/null {home}/.claude/.credentials.json" in bwrap
    assert f"--tmpfs {seat_a}" not in bwrap
    # every other Claude dir and backup dir is hidden; only the running seat stays
    _assert_backups_hidden(bwrap, home)


def test_seat_b_runner_has_no_config_dir_and_hides_seat_a(tmp_path):
    r, bwrap, claude, _, _, seat_a, home = _worker(tmp_path, "claude", cfg_dir=False)
    assert "CCD=unset" in claude
    assert f"--tmpfs {seat_a}" in bwrap
    assert f"--ro-bind /dev/null {home}/.claude/.credentials.json" not in bwrap
    _assert_backups_hidden(bwrap, home)


def test_claude_worker_runs_with_hooks_disabled(tmp_path):
    r, _, claude, _, _, _, _ = _worker(tmp_path, "claude")
    assert r.returncode == 0, r.stderr
    assert """--settings {"disableAllHooks":true}""" in claude


def test_rate_limited_claude_falls_through_to_cursor(tmp_path):
    r, _, claude, cursor, ran, _, _ = _worker(tmp_path, "claude", claude_rc=1, claude_out="API Error: 429 rate limit")
    assert r.returncode == 0, r.stderr
    assert "claude -p" in claude and "--model cursor-grok-4.6-high" in cursor
    assert ran == ["claude", "cursor"]


def test_other_claude_failure_does_not_fall_through(tmp_path):
    r, _, _, cursor, ran, _, _ = _worker(tmp_path, "claude", claude_rc=1, claude_out="some other error")
    assert r.returncode == 1 and cursor == "" and ran == ["claude"]


def test_rate_limit_wording_early_in_the_output_is_not_a_refused_seat(tmp_path):
    # The model's own text mentions rate limits; the run then stops on the turn cap.
    out = "fixed the rate limit handling\nand the 429 retry\nmore work\nmore work\nmore work\nError: Reached max turns (200)"
    r, _, _, cursor, ran, _, _ = _worker(tmp_path, "claude", claude_rc=1, claude_out=out)
    assert r.returncode == 1 and cursor == "" and ran == ["claude"]
    assert "429" not in r.stderr


def test_rate_limit_with_cursor_full_fails_with_a_429_line_for_the_wall(tmp_path):
    r, _, _, cursor, _, _, _ = _worker(tmp_path, "claude", claude_rc=1, claude_out="usage limit reached", cursor_live=1)
    assert r.returncode == 1 and cursor == ""
    assert "429" in r.stderr


def test_rate_limit_seen_only_on_stderr_still_gets_the_429_line(tmp_path):
    r, _, _, cursor, _, _, _ = _worker(tmp_path, "claude", claude_rc=1, claude_err="usage limit reached", cursor_live=1)
    assert r.returncode == 1 and cursor == ""
    assert "claude: 429 rate limit, cursor lane full" in r.stderr


@pytest.mark.parametrize("engine", ["cursor", "pi", "opencode", "devin"])
def test_other_engines_jail_hides_both_seat_logins(tmp_path, engine):
    r, bwrap, _, _, ran, seat_a, home = _worker(tmp_path, engine)
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


@pytest.mark.skipif(not _real_bwrap_ok(), reason="bwrap cannot run here")
@pytest.mark.parametrize("runner", ["seat-a", "seat-b"])
def test_real_jail_claude_lane_reads_only_its_own_seat_and_nobody_reads_the_rest(tmp_path, runner):
    """Real bwrap. A seat-a runner has CLAUDE_CONFIG_DIR; a seat-b runner has none, and the
    Worker then uses the already-hidden gh dir as the stand-in `seat_a`."""
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
    lines = _jail_lines()
    seat_b = runner == "seat-b"
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
    # The claude lane reads the seat of the runner it runs on and nothing else: no other
    # seat, no Max dir, no backup, no plain backup file.
    if seat_b:
        assert read_all("claude_jail_b") == {"a": False, **{**none, "b": True, "cj": True}}
    else:
        assert read_all("claude_jail_a") == {"a": True, **none}


def test_judgment_job_rate_limited_falls_to_pi_even_with_cursor_busy(tmp_path):
    r, _, claude, cursor, ran, _, _ = _worker(tmp_path, "claude", claude_rc=1, claude_out="429 rate limit", cursor_live=1, senior="false")
    assert r.returncode == 0, r.stderr
    assert "claude -p" in claude and cursor == "" and ran == ["claude", "pi"]
