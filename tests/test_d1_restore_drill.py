import pathlib
import shlex
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd/fleet-d1-restore-drill.service"
TIMER = ROOT / "systemd/fleet-d1-restore-drill.timer"
SYNC = ROOT / "systemd/fleet-sync.service"

DUMP = """CREATE TABLE IF NOT EXISTS alpha (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS beta (name TEXT);
INSERT INTO alpha (id) VALUES (1), (2), (3);
INSERT INTO beta (name) VALUES ('x'), ('y');
"""

_ESCAPES = {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v", "\\": "\\", '"': '"', "'": "'", "s": " "}


def _cunescape(text: str) -> str:
    """systemd unescapes a backslash pair before any shell sees the word (fleet-ops#8382)."""
    out, i = [], 0
    while i < len(text):
        if text[i] == "\\" and i + 1 < len(text) and text[i + 1] in _ESCAPES:
            out.append(_ESCAPES[text[i + 1]])
            i += 2
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


_SPECIFIERS = (("%%", "\x00"), ("%h", "/home/nish"), ("%t", "/run/user/1000"), ("%N", "fleet-d1-restore-drill.service"))


def _expand(text: str, specifiers=_SPECIFIERS) -> str:
    for old, new in specifiers:
        text = text.replace(old, new)
    return _cunescape(text).replace("$$", "$").replace("\x00", "%")


def _exec(unit: pathlib.Path, key: str = "ExecStart", specifiers=_SPECIFIERS) -> list[list[str]]:
    text = unit.read_text().replace("\\\n", "")
    return [shlex.split(_expand(ln[len(key) + 1 :], specifiers)) for ln in text.splitlines() if ln.startswith(key + "=")]


def _env_defaults() -> dict[str, str]:
    env = {}
    for ln in UNIT.read_text().splitlines():
        if ln.startswith("Environment="):
            key, _, value = ln[len("Environment=") :].partition("=")
            env[key] = _expand(value)
    return env


def _stub_dir(tmp_path: pathlib.Path, run: str = "40838700865", artifacts: str = "d1-backup-alpha d1-backup-beta", broken: str = "") -> pathlib.Path:
    bindir = tmp_path / "bin"
    bindir.mkdir()
    dump = tmp_path / "dump.sql"
    dump.write_text(DUMP)
    (bindir / "gh").write_text(
        "#!/bin/sh\n"
        'if [ "$1" = run ] && [ "$2" = list ]; then test -n "$STUB_RUN_ID" && echo "$STUB_RUN_ID"; exit 0; fi\n'
        'if [ "$1" = run ] && [ "$2" = download ]; then\n'
        '  name=; dir=\n'
        "  while [ $# -gt 0 ]; do case \"$1\" in -n) name=$2; shift 2 ;; -D) dir=$2; shift 2 ;; *) shift ;; esac; done\n"
        '  stem=${name#d1-backup-}\n'
        '  mkdir -p "$dir"; cp "$STUB_DUMP" "$dir/$stem.sql.age"\n'
        "  exit 0\n"
        "fi\n"
        'case "$*" in *DELETE*) echo "revoked" >> "$STUB_LOG" ;; *) for a in $STUB_ARTIFACTS; do echo "$a"; done ;; esac\n'
    )
    (bindir / "age").write_text(
        "#!/bin/sh\n"
        'out=; in=\n'
        "while [ $# -gt 0 ]; do case \"$1\" in -o) out=$2; shift 2 ;; -i) shift 2 ;; *) in=$1; shift ;; esac; done\n"
        'if [ -n "$STUB_BROKEN" ]; then case "$in" in *"$STUB_BROKEN"*) echo "age: no identity matched $in" >&2; exit 1 ;; esac; fi\n'
        'cp "$STUB_DUMP" "$out"\n'
    )
    (bindir / "sqlite3").write_text(
        "#!/usr/bin/env python3\n"
        "import sqlite3, sys\n"
        "con = sqlite3.connect(sys.argv[1])\n"
        "if len(sys.argv) > 2:\n"
        "    for row in con.execute(sys.argv[2]): print(row[0])\n"
        "else:\n"
        "    con.executescript(sys.stdin.read())\n"
    )
    for name in ("gh", "age", "sqlite3"):
        (bindir / name).chmod(0o755)
    (tmp_path / "log").write_text("")
    (tmp_path / "key").write_text("AGE-SECRET-KEY-XYZ\n")
    return bindir


def _run(tmp_path: pathlib.Path, bindir: pathlib.Path, steps: list[list[str]] | None = None, extra: dict | None = None) -> subprocess.CompletedProcess:
    runtime = tmp_path / "run"
    runtime.mkdir()
    state = tmp_path / "state"
    state.mkdir()
    env = {
        "PATH": f"{bindir}:/usr/bin:/bin",
        "STUB_RUN_ID": "40838700865",
        "STUB_ARTIFACTS": "d1-backup-alpha d1-backup-beta",
        "STUB_DUMP": str(tmp_path / "dump.sql"),
        "STUB_BROKEN": "",
        "STUB_LOG": str(tmp_path / "log"),
        "GH_TOKEN": "ghs_probe",
        **_env_defaults(),
        "DRILL_KEY": str(tmp_path / "key"),
        "DRILL_STATE": str(state),
        "RUNTIME_DIRECTORY": str(runtime),
    }
    env.update(extra or {})
    for argv in _exec(UNIT) if steps is None else steps:
        done = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=120)
        if done.returncode:
            return done
    return done


def _stop_post(index: int, specifiers=_SPECIFIERS) -> list[str]:
    return _exec(UNIT, "ExecStopPost", specifiers)[index]


def test_unit_env_defaults_match_the_test():
    text = UNIT.read_text()
    assert "Environment=GH_REPO=Nishfleet/drive" in text
    assert "Environment=GH_WORKFLOW=d1-export.yml" in text
    assert "Environment=DRILL_KEY=%h/.config/drive/d1-backup-key.txt" in text
    assert "Environment=DRILL_STATE=%h/workspaces/agent-state/d1-restore-drill" in text
    assert "Environment=TZ=Asia/Kolkata" in text
    assert "OnFailure=fleet-unit-failed@%N.service" in text
    assert "Requires=fleet-worker-github-token@actions:drive.service" in text
    assert "RuntimeDirectory=fleet-d1-restore-drill" in text
    assert "RuntimeDirectoryMode=0700" in text


def test_timer_runs_monthly_on_the_host_clock_and_persists():
    text = TIMER.read_text()
    assert "OnCalendar=*-*-01 05:30:00 Asia/Kolkata" in text
    assert "Persistent=true" in text
    assert "WantedBy=timers.target" in text


def test_fleet_sync_links_the_drill_pair_and_enables_the_timer():
    text = SYNC.read_text()
    assert "for f in fleet-d1-restore-drill.service fleet-d1-restore-drill.timer; do" in text
    assert (
        "systemctl --user link %h/workspaces/tooling/fleet-ops-deploy-clone/systemd/fleet-d1-restore-drill.service "
        "%h/workspaces/tooling/fleet-ops-deploy-clone/systemd/fleet-d1-restore-drill.timer"
    ) in text
    assert "systemctl --user enable --now fleet-d1-restore-drill.timer" in text


def test_the_drill_never_calls_the_cloudflare_api():
    for argv in _exec(UNIT):
        body = " ".join(argv)
        for banned in ("cloudflare", "wrangler", "/d1/database", "CF_ACCOUNT", "CF_API"):
            assert banned not in body


def test_a_restore_produces_a_report_with_counts(tmp_path):
    bindir = _stub_dir(tmp_path)
    done = _run(tmp_path, bindir)
    assert done.returncode == 0, done.stdout + done.stderr
    report = tmp_path / "state" / "report-2026-10-29.md"
    assert report.is_file()
    text = report.read_text()
    assert "# D1 restore drill, 2026-10-29 (Asia/Kolkata)" in text
    assert "Backup run: https://github.com/Nishfleet/drive/actions/runs/40838700865" in text
    assert "| alpha | d1-backup-alpha |" in text
    assert "| beta | d1-backup-beta |" in text
    assert "| ok | 5 |" in text
    assert "- alpha: alpha=3 beta=2" in text
    assert "- beta: alpha=3 beta=2" in text
    assert "2 database(s) restored." in text
    assert "No Cloudflare database was created" in text


def test_no_completed_backup_run_fails_the_unit(tmp_path):
    bindir = _stub_dir(tmp_path)
    done = _run(tmp_path, bindir, extra={"STUB_RUN_ID": ""})
    assert done.returncode != 0
    assert "no completed d1-export.yml run" in done.stderr


def test_a_run_that_left_no_backup_artifact_fails_the_unit(tmp_path):
    bindir = _stub_dir(tmp_path)
    done = _run(tmp_path, bindir, extra={"STUB_ARTIFACTS": "other-artifact"})
    assert done.returncode != 0
    assert "left no d1-backup-* artifact" in done.stderr


def test_a_dump_that_does_not_decrypt_fails_the_unit(tmp_path):
    bindir = _stub_dir(tmp_path)
    done = _run(tmp_path, bindir, extra={"STUB_BROKEN": "beta"})
    assert done.returncode != 0
    assert "age: no identity matched" in done.stderr
    assert not (tmp_path / "state" / "report-2026-10-29.md").exists()


def test_a_dump_that_does_not_load_fails_the_unit(tmp_path):
    bindir = _stub_dir(tmp_path)
    dump = tmp_path / "dump.sql"
    dump.write_text("this is not SQL at all; drop table if exists")
    done = _run(tmp_path, bindir)
    assert done.returncode != 0
    assert "did not restore" in done.stderr or "syntax error" in done.stderr


def test_an_integrity_check_that_is_not_ok_fails_the_unit(tmp_path):
    bindir = _stub_dir(tmp_path)
    (tmp_path / "bin" / "sqlite3").write_text(
        "#!/usr/bin/env python3\n"
        "import sqlite3, sys\n"
        "con = sqlite3.connect(sys.argv[1])\n"
        "if len(sys.argv) > 2:\n"
        "    q = sys.argv[2]\n"
        "    print('row 1 missing from index' if q.startswith('PRAGMA') else ('0' if q.startswith('select count') else 'alpha'))\n"
        "    print('beta') if not q.startswith(('PRAGMA', 'select count')) else None\n"
        "else:\n"
        "    con.executescript(sys.stdin.read())\n"
    )
    (tmp_path / "bin" / "sqlite3").chmod(0o755)
    done = _run(tmp_path, bindir)
    assert done.returncode != 0
    assert "integrity_check answered row 1 missing from index" in done.stderr


def test_a_missing_private_key_fails_before_anything_is_downloaded(tmp_path):
    bindir = _stub_dir(tmp_path)
    done = _run(tmp_path, bindir, extra={"DRILL_KEY": str(tmp_path / "absent-key")})
    assert done.returncode != 0
    assert "the private key" in done.stderr
    assert not (tmp_path / "run" / "dumps").exists()


def test_an_empty_github_token_fails_the_pre_check(tmp_path):
    bindir = _stub_dir(tmp_path)
    pre = _exec(UNIT, "ExecStartPre")[0]
    done = subprocess.run(pre, env={"PATH": f"{bindir}:/usr/bin:/bin", "GH_TOKEN": ""}, capture_output=True, text=True, timeout=30)
    assert done.returncode != 0
    assert "no GitHub App token, refusing to run" in done.stderr


def test_the_deliverable_check_names_the_step_that_produced_nothing(tmp_path):
    bindir = _stub_dir(tmp_path)
    runtime = tmp_path / "run"
    runtime.mkdir()
    first = _exec(UNIT)[0]
    env = {"PATH": f"{bindir}:/usr/bin:/bin", "STUB_RUN_ID": "", **_env_defaults(), "DRILL_KEY": str(tmp_path / "key"), "DRILL_STATE": str(tmp_path), "RUNTIME_DIRECTORY": str(runtime)}
    done = subprocess.run(first, env=env, capture_output=True, text=True, timeout=60)
    assert done.returncode != 0
    assert (runtime / "date").is_file()
    out = subprocess.run(
        _stop_post(0),
        env={"PATH": f"{bindir}:/usr/bin:/bin", "RUNTIME_DIRECTORY": str(runtime), "DRILL_STATE": str(tmp_path)},
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert out.returncode != 0
    assert "no-deliverable: set-up stopped after the date write" in out.stderr


def test_the_revoke_step_revokes_the_token_and_removes_its_env_file(tmp_path):
    bindir = _stub_dir(tmp_path)
    runtime = tmp_path / "run-user"
    (runtime / "fleet-worker-github-token").mkdir(parents=True)
    (runtime / "fleet-worker-github-token" / "actions:drive.env").write_text("GH_TOKEN=ghs_probe\n")
    specifiers = (("%%", "\x00"), ("%h", "/home/nish"), ("%t", str(runtime)), ("%N", "fleet-d1-restore-drill.service"))
    env = {
        "PATH": f"{bindir}:/usr/bin:/bin",
        "STUB_LOG": str(tmp_path / "log"),
        "GH_TOKEN": "ghs_probe",
        "RUNTIME_DIRECTORY": str(tmp_path / "run"),
    }
    done = subprocess.run(_stop_post(1, specifiers), env=env, capture_output=True, text=True, timeout=30)
    assert done.returncode == 0
    assert "revoked" in (tmp_path / "log").read_text()
    assert not (runtime / "fleet-worker-github-token" / "actions:drive.env").exists()
