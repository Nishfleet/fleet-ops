import os
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd/retro-weekly.service"

FINDING = [
    "class=tool-economy",
    "count=14",
    "rung=rule",
    "repo=fleet-ops",
    "fix=rule-edit",
]

GH_STUB = (
    "#!/bin/bash\n"
    'printf "%s\\n" "$*" >> "$GH_LOG"\n'
    'if [ "$1" = issue ] && [ "$2" = create ]; then\n'
    '  if [ "${GH_FAIL:-}" = 1 ]; then echo "gh: could not create the issue" >&2; exit 1; fi\n'
    '  n=$(cat "$GH_COUNTER" 2>/dev/null || echo 9000); n=$((n + 1)); echo "$n" > "$GH_COUNTER"\n'
    '  printf "https://github.com/Nishfleet/fleet-ops/issues/%s\\n" "$n"\n'
    "fi\n"
)


def step5_bash():
    text = UNIT.read_text()
    line = next(
        line
        for line in text.splitlines()
        if line.startswith("ExecStart=") and "retro-public-check: $$n issue file" in line
    )
    inner = line.split("ExecStart=/bin/bash -c ", 1)[1]
    assert inner.startswith("'") and inner.endswith("'")
    return inner[1:-1].replace("$$", "$").replace("%%", "%")


def file_tail_bash(home):
    bash = step5_bash()
    marker = 'echo "retro-public-check: $n issue file(s) passed"; '
    assert marker in bash
    return "set -eu; " + bash.split(marker, 1)[1].replace("%h", str(home))


def run_tail(tmp_path, findings, known=(), fail=False):
    home = tmp_path / "home"
    ghbin = home / ".local/bin"
    ghbin.mkdir(parents=True, exist_ok=True)
    (ghbin / "gh").write_text(GH_STUB)
    (ghbin / "gh").chmod(0o755)
    logdir = tmp_path / "logs"
    logdir.mkdir(parents=True, exist_ok=True)
    (logdir / "gh.log").write_text("")
    (logdir / "counter").write_text("9000")
    state = tmp_path / "state"
    run = state / "run-2026-10-28"
    (run / "issues").mkdir(parents=True)
    for index, finding in enumerate(findings, start=1):
        (run / "issues" / f"{index}.md").write_text("".join(line + "\n" for line in finding))
    rt = tmp_path / "rt"
    rt.mkdir(parents=True, exist_ok=True)
    (rt / "gh").mkdir(exist_ok=True)
    (rt / "queue").write_text(
        "".join(f"{index}.md\n" for index in range(1, len(findings) + 1))
    )
    (rt / "known-issues.txt").write_text("".join(line + "\n" for line in known))
    for index, finding in enumerate(findings, start=1):
        (rt / f"t.{index}.md").write_text(f"Retro: {finding[0].split('=', 1)[1]}\n")
        (rt / f"b.{index}.md").write_text("Week ending: 2026-10-28\n")
    token = tmp_path / "token"
    token.write_text("stub-token\n")
    env = {
        "PATH": os.environ["PATH"],
        "HOME": str(home),
        "TZ": "Asia/Kolkata",
        "run": str(run),
        "RETRO_STATE": str(state),
        "RETRO_REPO": str(ROOT),
        "RETRO_TOKEN": str(token),
        "RUNTIME_DIRECTORY": str(rt),
        "GH_LOG": str(logdir / "gh.log"),
        "GH_COUNTER": str(logdir / "counter"),
        "GH_FAIL": "1" if fail else "",
    }
    result = subprocess.run(
        ["bash", "-c", file_tail_bash(home)], env=env, capture_output=True, text=True
    )
    return result, logdir


def created(logdir):
    return [
        line
        for line in (logdir / "gh.log").read_text().splitlines()
        if line.startswith("issue create")
    ]


def test_the_last_output_line_names_each_issue_its_repo_number_and_label(tmp_path):
    findings = [
        FINDING,
        ["class=corrections", "count=6", "rung=prose", "repo=fleet-ops", "fix=prompt-edit"],
    ]
    result, logdir = run_tail(tmp_path, findings)
    assert result.returncode == 0, result.stderr
    lines = result.stdout.strip().splitlines()
    assert len(created(logdir)) == 2
    assert lines[-1] == "retro-filed: Nishfleet/fleet-ops 9001 [retro] 9002 [retro]"


def test_a_week_with_nothing_new_ends_with_one_final_line(tmp_path):
    result, logdir = run_tail(tmp_path, [FINDING], known=["Retro: tool-economy"])
    assert result.returncode == 0, result.stderr
    assert created(logdir) == []
    assert result.stdout.strip().splitlines()[-1] == "retro-filed: nothing new this week"
    assert "retro: already open, skipped: Retro: tool-economy" in result.stdout


def test_a_filing_failure_stops_the_run_before_the_final_line(tmp_path):
    result, logdir = run_tail(tmp_path, [FINDING], fail=True)
    assert result.returncode != 0
    assert "could not create the issue" in result.stderr
    assert "retro-filed:" not in result.stdout


def test_the_filing_step_makes_no_paid_model_call(tmp_path):
    bash = step5_bash()
    for needle in ("4000", "jev", "anthropic", "curl", "litellm", "probability"):
        assert needle not in bash.lower(), needle


def test_the_issues_token_is_read_from_the_runtime_dir_not_argv(tmp_path):
    result, logdir = run_tail(tmp_path, [FINDING])
    assert result.returncode == 0, result.stderr
    logged = (logdir / "gh.log").read_text()
    assert "stub-token" not in logged
    assert len(created(logdir)) == 1
    assert "Authorization" not in logged


def test_the_repo_and_the_label_are_fixed_in_the_step_not_chosen_by_the_model(tmp_path):
    bash = step5_bash()
    assert 'labels=retro;' in bash
    assert re.search(
        r'gh issue create -R Nishfleet/fleet-ops --title "\$t" --label "\$labels" --body-file', bash
    )
    tail = bash.split("retro-public-check: $n issue file(s) passed", 1)[1]
    assert "Nishfleet/fleet-ops" not in tail.split("gh issue create", 1)[0]
