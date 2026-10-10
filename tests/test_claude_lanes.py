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


def _bin(tmp, seat_out):
    b = tmp / "bin"
    b.mkdir()
    for name, body in (("pgrep", PGREP), ("gh", GH), ("bwrap", BWRAP), ("claude", CLAUDE), ("cursor-agent", CURSOR), ("pi", NOOP), ("devin", NOOP), ("opencode", NOOP)):
        (b / name).write_text(body)
        (b / name).chmod(0o755)
    home = tmp / "home"
    s = home / "workspaces/tooling/fleet-ops-deploy-clone/scripts"
    s.mkdir(parents=True)
    (s / "claude-lane-seat.sh").write_text(f"#!/bin/bash\necho {seat_out}\n")
    (s / "claude-lane-seat.sh").chmod(0o755)
    (home / ".config/fleet-ops/seats").mkdir(parents=True)
    (home / ".config/fleet-ops/seats/cursor.env").write_text("")
    (home / ".config/fleet-ops/seats/cursor-2.env").write_text("")
    (home / ".config/fleet-ops/seats/mobbin-mcp.env").write_text("")
    return b, home


def _comments(failed=0):
    return json.dumps({"comments": [{"body": f"agent run failed: https://x/{k}", "authorAssociation": "NONE"} for k in range(failed)]})


def _gate(tmp_path, labels=",strong-only,", failed=0, seat="keep", live=None):
    script = _step("work", "Gate")
    start = script.index("claude_seat=")
    start = script.rindex("live() {", 0, start)
    end = script.index('gh issue edit "$i" -R "$REPO" --remove-label agent-ready')
    seg = script[start:end]
    b, home = _bin(tmp_path, seat)
    prog = f'skip() {{ echo "SKIP $1"; exit 0; }}\ni=5 REPO=o/r labels="{labels}"\n{seg}\necho "engine=$engine model=$claude_model"\n'
    env = {**os.environ, "HOME": str(home), "PATH": f"{b}:{SYS_PATH}", "COMMENTS_JSON": _comments(failed), **{f"LIVE_{k}": str(v) for k, v in (live or {}).items()}}
    r = subprocess.run(["bash", "-c", prog], env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip().splitlines()[-1]


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


def test_claude_cap_is_two_then_cursor_then_wait(tmp_path):
    assert _gate(tmp_path, live={"claude": 1}).startswith("engine=claude ")
    d = tmp_path / "b"
    d.mkdir()
    assert _gate(d, live={"claude": 2}).startswith("engine=cursor ")
    d = tmp_path / "c"
    d.mkdir()
    assert _gate(d, live={"claude": 2, "cursor_agent": 1}) == "SKIP lanes-full"


def test_non_senior_work_never_uses_claude(tmp_path):
    out = _gate(tmp_path, labels=",bug,")
    assert out.startswith("engine=pi") or out.startswith("engine=opencode") or out.startswith("engine=devin") or out.startswith("SKIP")


def _worker(tmp_path, engine, seat="keep", model="claude-sonnet-5-5", claude_rc=0, claude_out="", cursor_live=0, cfg_dir=True):
    b, home = _bin(tmp_path, seat)
    state = tmp_path / "state"
    tmp = tmp_path / "runner-tmp"
    state.mkdir()
    tmp.mkdir()
    seat_a = tmp_path / "seat-a"
    seat_a.mkdir()
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


def test_seat_b_run_unsets_the_config_dir_and_hides_seat_a(tmp_path):
    r, bwrap, claude, _, _, seat_a, home = _worker(tmp_path, "claude", seat="default")
    assert "CCD=unset" in claude
    assert f"--tmpfs {seat_a}" in bwrap
    assert f"--ro-bind /dev/null {home}/.claude/.credentials.json" not in bwrap


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


@pytest.mark.skipif(not _real_bwrap_ok(), reason="bwrap cannot run here")
def test_real_jail_other_engines_cannot_read_seat_logins(tmp_path):
    home = tmp_path / "home"
    seat_a = tmp_path / "seat-a"
    (home / ".claude").mkdir(parents=True)
    (home / ".config/gh").mkdir(parents=True)
    (home / "workspaces/tooling/fleet-ops-deploy-clone").mkdir(parents=True)
    seat_a.mkdir()
    for p in (seat_a / ".credentials.json", home / ".claude/.credentials.json", home / ".claude.json"):
        p.write_text("planted")
    lines = _jail_lines()

    def read_all(name):
        cmd = lines[name].replace("$HOME", str(home)).replace("$seat_a", str(seat_a)).split() + ["--"]
        out = {}
        for key, path in (("a", seat_a / ".credentials.json"), ("b", home / ".claude/.credentials.json"), ("cj", home / ".claude.json")):
            r = subprocess.run(cmd + ["cat", str(path)], capture_output=True, text=True)
            out[key] = "planted" in r.stdout
        return out

    assert read_all("jail_base") == {"a": False, "b": False, "cj": False}
    assert read_all("claude_jail_a") == {"a": True, "b": False, "cj": False}
    assert read_all("claude_jail_b") == {"a": False, "b": True, "cj": True}
