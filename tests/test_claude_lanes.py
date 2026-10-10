"""Claude Code lanes in .github/workflows/agent.yml, run from the workflow's own
text (read out with yq, never a copy).

Gate: strong-only work goes to claude-sonnet-5-5, to claude-opus-5-5 after two
failed runs or with needs-opus, and to Cursor when both seats are full or the
claude cap (2) is reached.
Worker: the claude invocation, the seat choice, the rate-limit fallthrough to
Cursor, and the engines-ran record the review reads.
Secret isolation: every other engine's jail hides the Claude seat logins; the
claude jail sees only its own seat. The last test runs real bwrap.

Fakes (gh, pgrep, bwrap, claude, cursor-agent, the seat script) live in a temp
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
SYS_PATH = "/usr/bin:/bin"


SEAT = """#!/bin/bash
# fake claude-lane-seat.sh: five_hour is $UTIL; full at or over CLAUDE_SEAT_SKIP_AT (default 95)
util=%s; forced=%s; skip=${CLAUDE_SEAT_SKIP_AT:-95}
mode=$forced
if [ "$util" != n/a ] && awk "BEGIN{exit !($util >= $skip)}"; then mode=full; fi
if [ "$1" = --usage ]; then echo "$mode a $util"; else echo "$mode"; fi
"""


def _bin(tmp, seat_out, util="10"):
    b = tmp / "bin"
    b.mkdir()
    for name, body in (("pgrep", PGREP), ("gh", GH), ("bwrap", BWRAP), ("claude", CLAUDE), ("cursor-agent", CURSOR), ("pi", NOOP), ("devin", NOOP), ("opencode", NOOP)):
        (b / name).write_text(body)
        (b / name).chmod(0o755)
    home = tmp / "home"
    s = home / "workspaces/tooling/fleet-ops-deploy-clone/scripts"
    s.mkdir(parents=True)
    (s / "claude-lane-seat.sh").write_text(SEAT % (util, "full" if seat_out == "full" else seat_out))
    (s / "claude-lane-seat.sh").chmod(0o755)
    (home / ".config/fleet-ops/seats").mkdir(parents=True)
    (home / ".config/fleet-ops/seats/cursor.env").write_text("")
    (home / ".config/fleet-ops/seats/cursor-2.env").write_text("")
    (home / ".config/fleet-ops/seats/mobbin-mcp.env").write_text("")
    return b, home


def _comments(failed=0):
    return json.dumps({"comments": [{"body": f"agent run failed: https://x/{k}", "authorAssociation": "NONE"} for k in range(failed)]})


def _gate_full(tmp_path, labels=",strong-only,", failed=0, seat="keep", live=None, util="10", env=None):
    script = _step("work", "Gate")
    start = script.index("claude_seat=")
    start = script.rindex("live() {", 0, start)
    end = script.index('gh issue edit "$i" -R "$REPO" --remove-label agent-ready')
    seg = script[start:end]
    b, home = _bin(tmp_path, seat, util)
    prog = f'skip() {{ echo "SKIP $1"; exit 0; }}\ni=5 REPO=o/r labels="{labels}"\n{seg}\necho "senior=$senior"\necho "engine=$engine model=$claude_model"\n'
    env = {**os.environ, "HOME": str(home), "PATH": f"{b}:{SYS_PATH}", "COMMENTS_JSON": _comments(failed), **{f"LIVE_{k}": str(v) for k, v in (live or {}).items()}, **(env or {})}
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


def test_needs_opus_label_goes_to_claude_opus(tmp_path):
    assert _gate(tmp_path, labels=",strong-only,needs-opus,") == "engine=claude model=claude-opus-5-5"


def test_both_seats_full_falls_back_to_cursor(tmp_path):
    assert _gate(tmp_path, seat="full").startswith("engine=cursor ")


def test_senior_claude_cap_then_cursor_then_wait(tmp_path):
    assert _gate(tmp_path, live={"claude": 3}).startswith("engine=claude ")
    d = tmp_path / "b"
    d.mkdir()
    assert _gate(d, live={"claude": 4}).startswith("engine=cursor ")
    d = tmp_path / "c"
    d.mkdir()
    assert _gate(d, live={"claude": 4, "cursor_agent": 1}) == "SKIP lanes-full"


def _pacing(tmp_path, util, labels=",bug,", live=None, env=None, seat="keep"):
    out = _gate_full(tmp_path, labels=labels, util=util, live=live, env=env, seat=seat)
    log = [ln for ln in out if ln.startswith("claude fill:")]
    assert len(log) == 1, out
    return out[-1], log[0]


def test_fill_below_threshold_sends_ordinary_work_to_claude_sonnet(tmp_path):
    last, log = _pacing(tmp_path, "50")
    assert last == "engine=claude model=claude-sonnet-5-5"
    assert log == "claude fill: seat=a five_hour=50 live=0/4 -> claude"


def test_fill_skips_at_the_threshold_and_keeps_the_old_order(tmp_path):
    last, log = _pacing(tmp_path, "80")
    assert log == "claude fill: seat=a five_hour=80 live=0/4 -> skip(seat-full)"
    assert last.split()[0] in ("engine=pi", "engine=opencode", "engine=devin")


def test_fill_threshold_is_the_repo_variable(tmp_path):
    assert _pacing(tmp_path, "60", env={"CLAUDE_FILL_BELOW": "50"})[1].endswith("skip(seat-full)")
    d = tmp_path / "b"
    d.mkdir()
    assert _pacing(d, "40", env={"CLAUDE_FILL_BELOW": "50"})[0].startswith("engine=claude ")


def test_fill_skips_at_the_live_cap(tmp_path):
    last, log = _pacing(tmp_path, "10", live={"claude": 4})
    assert log == "claude fill: seat=? five_hour=n/a live=4/4 -> skip(cap)"
    assert not last.startswith("engine=claude")


def test_cap_is_the_repo_variable_and_clamped_to_six(tmp_path):
    assert _pacing(tmp_path, "10", live={"claude": 2}, env={"CLAUDE_MAX_LIVE": "2"})[1].endswith("skip(cap)")
    d = tmp_path / "b"
    d.mkdir()
    assert _pacing(d, "10", live={"claude": 5}, env={"CLAUDE_MAX_LIVE": "99"})[1].endswith("-> claude")
    d = tmp_path / "c"
    d.mkdir()
    assert _pacing(d, "10", live={"claude": 6}, env={"CLAUDE_MAX_LIVE": "99"})[1].endswith("live=6/6 -> skip(cap)")


def test_strong_only_still_takes_a_seat_at_90_percent(tmp_path):
    last, log = _pacing(tmp_path, "90", labels=",strong-only,")
    assert last == "engine=claude model=claude-sonnet-5-5"
    assert log == "claude fill: seat=a five_hour=90 live=0/4 -> claude"
    # the same seat gets no new fill job
    d = tmp_path / "b"
    d.mkdir()
    assert _pacing(d, "90", labels=",bug,")[1].endswith("skip(seat-full)")


def test_both_seats_full_falls_back_to_the_old_lanes(tmp_path):
    last, log = _pacing(tmp_path, "99")
    assert log.endswith("skip(seat-full)") and last.split()[0] in ("engine=pi", "engine=opencode", "engine=devin")
    d = tmp_path / "b"
    d.mkdir()
    last, log = _pacing(d, "99", labels=",strong-only,")
    assert log.endswith("skip(seat-full)") and last.startswith("engine=cursor ")


def test_fill_never_runs_on_an_unreadable_usage_but_strong_only_does(tmp_path):
    assert _pacing(tmp_path, "n/a")[1].endswith("skip(usage-unreadable)")
    d = tmp_path / "b"
    d.mkdir()
    assert _pacing(d, "n/a", labels=",strong-only,")[0].startswith("engine=claude ")


def test_fill_job_is_not_senior_and_never_opus(tmp_path):
    out = _gate_full(tmp_path, labels=",bug,needs-opus,", util="10", failed=3)
    assert "senior=false" in out and out[-1] == "engine=claude model=claude-sonnet-5-5"
    d = tmp_path / "b"
    d.mkdir()
    assert "senior=true" in _gate_full(d)


def _worker(tmp_path, engine, seat="keep", model="claude-sonnet-5-5", claude_rc=0, claude_out="", cursor_live=0, cfg_dir=True, senior="true"):
    b, home = _bin(tmp_path, seat)
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


def test_seat_a_run_keeps_its_dir_and_hides_the_default_login(tmp_path):
    r, bwrap, claude, _, _, seat_a, home = _worker(tmp_path, "claude", seat="keep")
    assert f"CCD={seat_a}" in claude
    assert f"--ro-bind /dev/null {home}/.claude/.credentials.json" in bwrap
    assert f"--tmpfs {seat_a}" not in bwrap
    # every other Claude dir and backup dir is hidden; only the running seat stays
    _assert_backups_hidden(bwrap, home)


def test_seat_b_run_unsets_the_config_dir_and_hides_seat_a(tmp_path):
    r, bwrap, claude, _, _, seat_a, home = _worker(tmp_path, "claude", seat="default")
    assert "CCD=unset" in claude
    assert f"--tmpfs {seat_a}" in bwrap
    assert f"--ro-bind /dev/null {home}/.claude/.credentials.json" not in bwrap
    _assert_backups_hidden(bwrap, home)


def test_both_seats_full_runs_cursor_not_claude(tmp_path):
    r, bwrap, claude, cursor, ran, _, _ = _worker(tmp_path, "claude", seat="full")
    assert r.returncode == 0, r.stderr
    assert claude == "" and "--model cursor-grok-4.6-high" in cursor
    assert ran == ["cursor"]


def test_rate_limited_claude_falls_through_to_cursor(tmp_path):
    r, _, claude, cursor, ran, _, _ = _worker(tmp_path, "claude", claude_rc=1, claude_out="API Error: 429 rate limit")
    assert r.returncode == 0, r.stderr
    assert "claude -p" in claude and "--model cursor-grok-4.6-high" in cursor
    assert ran == ["claude", "cursor"]


def test_other_claude_failure_does_not_fall_through(tmp_path):
    r, _, _, cursor, ran, _, _ = _worker(tmp_path, "claude", claude_rc=1, claude_out="some other error")
    assert r.returncode == 1 and cursor == "" and ran == ["claude"]


def test_rate_limit_with_cursor_full_fails_with_a_429_line_for_the_wall(tmp_path):
    r, _, _, cursor, _, _, _ = _worker(tmp_path, "claude", claude_rc=1, claude_out="usage limit reached", cursor_live=1)
    assert r.returncode == 1 and cursor == ""
    assert "429" in r.stderr


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
def test_real_jail_other_engines_cannot_read_seat_logins_or_backups(tmp_path):
    home = tmp_path / "home"
    seat_a = home / ".claude-seat"
    (home / ".claude").mkdir(parents=True)
    (home / ".config/gh").mkdir(parents=True)
    (home / "workspaces/tooling/fleet-ops-deploy-clone").mkdir(parents=True)
    seat_a.mkdir()
    backups = [home / ".claude-auth-backup-x", home / "backups-claude-x", home / ".claude-team-x"]
    for d in backups:
        d.mkdir()
        (d / "creds").write_text("planted")
    (home / ".claude-backup.json").write_text("planted")  # a plain file matching the glob
    for p in (seat_a / ".credentials.json", home / ".claude/.credentials.json", home / ".claude.json"):
        p.write_text("planted")
    lines = _jail_lines()
    sub = {"hide_all": _hides(home, ""), "hide_but_a": _hides(home, str(seat_a))}

    def expand(name):
        line = lines[name].replace("$HOME", str(home)).replace("$seat_a", str(seat_a))
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
    assert read_all("jail_base") == {"a": False, **none}
    assert read_all("claude_jail_a") == {"a": True, **none}
    assert read_all("claude_jail_b") == {"a": False, **{**none, "b": True, "cj": True}}


def test_fill_job_falls_to_pi_not_cursor_when_seats_are_full(tmp_path):
    r, _, claude, cursor, ran, _, _ = _worker(tmp_path, "claude", seat="full", senior="false")
    assert r.returncode == 0, r.stderr
    assert claude == "" and cursor == "" and ran == ["pi"]


def test_fill_job_rate_limited_falls_to_pi_even_with_cursor_busy(tmp_path):
    r, _, claude, cursor, ran, _, _ = _worker(tmp_path, "claude", claude_rc=1, claude_out="429 rate limit", cursor_live=1, senior="false")
    assert r.returncode == 0, r.stderr
    assert "claude -p" in claude and cursor == "" and ran == ["claude", "pi"]
