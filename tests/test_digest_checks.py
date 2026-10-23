"""The digest fact checks (Nishfleet/fleet-ops#9706 follow-up).

The evening digest's site row was always UNKNOWN because it read a feed
address that redirects to an HTML page, and the shipped and watch rows were
blocked by the shell guard in Hermes before they ran. This file keeps the
canonical prompts under config/hermes/ honest:

- the site check reads the real feed and the real page,
- no command line matches the guard's deny globs for a pipe from curl,
- no command uses a bare bracket test, which the guard cannot resolve,
- the stored-item command, run against a fake gh and a fake notepad, classifies
  each stored item the way the reply rules say,
- a stored broken item is classified from that workflow's own latest run on
  main, read directly, so a busy main branch cannot push the workflow out of a
  run window and turn a real status into an unreadable one (fleet-ops#9902),
- a stored broken item whose latest run passed before the digest window started
  is dropped as STALE and never reported as newly fixed, because a pass from
  days earlier is not a repair that happened now (fleet-ops#9924),
- the waiting count is printed by the command that lists the backlog, so the
  reply copies a number instead of computing one (fleet-ops#10072),
- a repository with issues disabled never turns the waiting count into
  COUNT FAILED, because the listing is filtered before it runs,
- ansible/host.yml applies the prompts to the live jobs.
"""
import datetime
import fnmatch
import json
import pathlib
import re
import shutil
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MORNING = ROOT / "config/hermes/digest-morning.md"
EVENING = ROOT / "config/hermes/digest-evening.md"
HOST = ROOT / "ansible/host.yml"
CI = ROOT / ".github/workflows/ci.yml"

_DENY = ["*curl*|*bash*", "*curl*|*sh*", "*wget*|*sh*", "*<<*", "*>*.sh*", "*>*.py*", "*>*.js*"]
_BRACKET = re.compile(r"(^|[;&|(]\s*|\b(if|then|elif|while|until|do)\s+)\[ ")


def test_site_check_reads_the_real_feed():
    for prompt in (MORNING, EVENING):
        assert "inish.in" not in prompt.read_text(), prompt.name
        assert "rss.xml" not in prompt.read_text(), prompt.name
    text = EVENING.read_text()
    assert "https://nish.sh/daily/feed.xml" in text
    assert re.search(r"https://nish\.sh/daily(?![/\w])", text)


def test_no_command_line_matches_a_deny_glob():
    for prompt in (MORNING, EVENING):
        for n, line in enumerate(prompt.read_text().splitlines(), 1):
            for glob in _DENY:
                assert not fnmatch.fnmatchcase(line.lower(), glob.lower()), f"{prompt.name}:{n} matches {glob}"


def test_no_bare_bracket_test_in_commands():
    for prompt in (MORNING, EVENING):
        for n, line in enumerate(prompt.read_text().splitlines(), 1):
            assert not _BRACKET.search(line), f"{prompt.name}:{n} uses a bracket test"


def test_shipped_count_has_no_command_substitution_in_its_loop():
    for prompt in (MORNING, EVENING):
        line = next(x for x in prompt.read_text().splitlines() if "COUNT FAILED" in x and "date -u -d" in x)
        loop = line[line.index("do "):line.index("; done")]
        assert "$(" not in loop, prompt.name


def test_host_yml_applies_the_prompts_to_the_live_jobs():
    text = HOST.read_text()
    assert "config/hermes/" in text
    assert "digest-morning" in text and "digest-evening" in text
    assert "- cron" in text and "- edit" in text and "- --prompt" in text


def test_ci_runs_this_file():
    assert "tests/test_digest_checks.py" in CI.read_text()


FAKE_GH = """#!/usr/bin/env python3
import json, os, subprocess, sys
a = sys.argv[1:]
d = json.load(open(os.environ["FAKE_GH"]))
if a[:2] == ["repo", "list"]:
    if "--jq" in a:
        objs = [
            {"name": n, "hasIssuesEnabled": n not in d.get("no_issues", []), "isArchived": n in d.get("archived", [])}
            for n in d["repos"]
        ]
        f = a[a.index("--jq") + 1]
        print(subprocess.run(["jq", "-r", f], input=json.dumps(objs), capture_output=True, text=True).stdout.strip())
    else:
        print("\\n".join(d["repos"]))
elif a[:2] == ["issue", "view"]:
    key = a[a.index("--repo") + 1] + "#" + a[2]
    if key not in d["issues"]:
        sys.exit(1)
    print(json.dumps(d["issues"][key]))
elif a[:2] == ["issue", "list"]:
    repo = a[a.index("--repo") + 1].split("/")[-1]
    if repo in d.get("no_issues", []) or repo in d.get("broken_lists", []):
        sys.exit(1)
    print(json.dumps(d.get("lists", {}).get(a[a.index("--repo") + 1], [])))
elif a[:2] == ["run", "list"]:
    key = a[a.index("--repo") + 1]
    if "--workflow" in a:
        key = key + "::" + a[a.index("--workflow") + 1]
    if key not in d["runs"]:
        sys.exit(1)
    print(json.dumps(d["runs"][key]))
else:
    sys.exit(2)
"""

FAKE_HERMES = """#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]
if a[:3] == ["cron", "notepad", "3acce3a945cb"] and a[3] == "get":
    sys.stdout.write(open(os.environ["FAKE_STORE"]).read())
elif a[:3] == ["cron", "notepad", "3acce3a945cb"] and a[3] == "set":
    open(os.environ["FAKE_SAVED"], "w").write(a[5])
else:
    sys.exit(2)
"""


def _command(prompt, start):
    return next(x for x in prompt.read_text().splitlines() if x.startswith(start))


def _fake_box(tmp_path, gh, store):
    if shutil.which("jq") is None:
        pytest.skip("jq is not installed")
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for name, body in (("gh", FAKE_GH), ("hermes", FAKE_HERMES)):
        (bindir / name).write_text(body)
        (bindir / name).chmod(0o755)
    (tmp_path / "gh.json").write_text(json.dumps(gh))
    (tmp_path / "store.json").write_text(store)
    env = {
        "PATH": f"{bindir}:/usr/bin:/bin",
        "HOME": str(tmp_path),
        "FAKE_GH": str(tmp_path / "gh.json"),
        "FAKE_STORE": str(tmp_path / "store.json"),
        "FAKE_SAVED": str(tmp_path / "saved.json"),
    }
    return env


def _run_2a(prompt, tmp_path, gh, store):
    env = _fake_box(tmp_path, gh, store)
    r = subprocess.run(["bash", "-c", _command(prompt, "R=$(hermes cron notepad")], env=env, capture_output=True, text=True, timeout=60)
    saved = pathlib.Path(env["FAKE_SAVED"])
    return r.stdout.splitlines(), (json.loads(saved.read_text()) if saved.exists() else None)


def _issue(state, *labels):
    return {"state": state, "labels": [{"name": x} for x in labels], "url": "https://example.com/i"}


def _run_row(conclusion, name, days_ago=1):
    when = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"workflowName": name, "conclusion": conclusion, "url": f"https://example.com/{name}/{days_ago}", "createdAt": when}


def _recent_run(conclusion, name, hours_ago):
    when = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"workflowName": name, "conclusion": conclusion, "url": f"https://example.com/{name}/h{hours_ago}", "createdAt": when}


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_stored_item_command_classifies_each_item(prompt, tmp_path):
    gh = {
        "repos": ["alpha", "beta"],
        "issues": {
            "Nishfleet/alpha#1": _issue("CLOSED", "needs-nish-decision"),
            "Nishfleet/alpha#2": _issue("OPEN", "needs-nish-decision", "priority-now"),
            "Nishfleet/alpha#3": _issue("OPEN", "needs-nish-decision"),
        },
        "runs": {
            "Nishfleet/alpha": [
                _run_row("", "Midrun", 0),
                _run_row("failure", "Midrun", 1),
                _run_row(None, "Nullrun", 0),
                _run_row("failure", "Nullrun", 1),
                _run_row("cancelled", "Cancelled", 0),
                _run_row("failure", "Cancelled", 2),
                _run_row("success", "Healed", 0),
                _run_row("failure", "Healed", 2),
                _run_row("timed_out", "Slow", 0),
            ],
            "Nishfleet/beta": [_run_row("failure", "Build", 1), _run_row("success", "Build", 3)],
            "Nishfleet/alpha::Midrun": [_run_row("", "Midrun", 0)],
            "Nishfleet/alpha::Nullrun": [_run_row(None, "Nullrun", 0)],
            "Nishfleet/alpha::Cancelled": [_run_row("cancelled", "Cancelled", 0)],
            "Nishfleet/alpha::Healed": [_run_row("success", "Healed", 0)],
            "Nishfleet/alpha::Slow": [_run_row("timed_out", "Slow", 0)],
        },
    }
    store = json.dumps({
        "wait:alpha#1": "open|needs-nish-decision",
        "wait:alpha#2": "open|needs-nish-decision",
        "wait:alpha#3": "open|needs-nish-decision",
        "wait:alpha#4": "open|needs-nish-decision",
        "broken:alpha:Midrun": "failure",
        "broken:alpha:Nullrun": "failure",
        "broken:alpha:Cancelled": "failure",
        "broken:alpha:Healed": "failure",
        "broken:alpha:Slow": "failure",
    })
    lines, saved = _run_2a(prompt, tmp_path, gh, store)
    rows = {l.split(" ")[1]: l.split(" ")[2] for l in lines if l.startswith("ROW ")}
    assert rows == {
        "wait:alpha#1": "FIXED",
        "wait:alpha#2": "CHANGED",
        "wait:alpha#3": "UNCHANGED",
        "wait:alpha#4": "UNKNOWN",
        "broken:alpha:Midrun": "UNCHANGED",
        "broken:alpha:Nullrun": "UNCHANGED",
        "broken:alpha:Cancelled": "UNCHANGED",
        "broken:alpha:Healed": "FIXED",
        "broken:alpha:Slow": "UNCHANGED",
        "broken:beta:Build": "NEW",
    }
    assert "UNCHANGED_TOTAL 5" in lines
    assert lines[-1] == "STORED-SAVED"
    assert saved == {
        "wait:alpha#2": "open|needs-nish-decision,priority-now",
        "wait:alpha#3": "open|needs-nish-decision",
        "wait:alpha#4": "open|needs-nish-decision",
        "broken:alpha:Midrun": "failure",
        "broken:alpha:Nullrun": "failure",
        "broken:alpha:Cancelled": "failure",
        "broken:alpha:Slow": "failure",
        "broken:beta:Build": "failure",
    }


_WINDOW_PUSHES = 30


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_broken_item_outside_the_main_window_reads_the_workflows_own_run(prompt, tmp_path):
    gh = {
        "repos": ["alpha"],
        "issues": {},
        "runs": {
            "Nishfleet/alpha": [_run_row("success", "Chatter", d) for d in range(_WINDOW_PUSHES)],
            "Nishfleet/alpha::Deploy production": [_run_row("failure", "Deploy production", 4)],
        },
    }
    lines, saved = _run_2a(prompt, tmp_path, gh, json.dumps({"broken:alpha:Deploy production": "failure"}))
    assert "ROW broken:alpha:Deploy production UNCHANGED" in lines
    assert not any("UNKNOWN" in l for l in lines)
    assert saved == {"broken:alpha:Deploy production": "failure"}


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_broken_item_fixed_when_the_workflows_own_latest_run_passed_in_the_window(prompt, tmp_path):
    gh = {
        "repos": ["alpha"],
        "issues": {},
        "runs": {
            "Nishfleet/alpha": [_run_row("success", "Chatter", d) for d in range(_WINDOW_PUSHES)],
            "Nishfleet/alpha::Deploy production": [_recent_run("success", "Deploy production", 2)],
        },
    }
    lines, saved = _run_2a(prompt, tmp_path, gh, json.dumps({"broken:alpha:Deploy production": "failure"}))
    assert any(l.startswith("ROW broken:alpha:Deploy production FIXED ") for l in lines)
    assert not any("UNKNOWN" in l for l in lines)
    assert saved == {}


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
@pytest.mark.parametrize("hours_ago", [13, 97])
def test_broken_item_that_healed_before_the_window_is_stale_never_fixed(prompt, tmp_path, hours_ago):
    gh = {
        "repos": ["alpha"],
        "issues": {},
        "runs": {
            "Nishfleet/alpha": [_run_row("success", "Chatter", d) for d in range(_WINDOW_PUSHES)],
            "Nishfleet/alpha::Site secret scan": [_recent_run("success", "Site secret scan", hours_ago)],
        },
    }
    lines, saved = _run_2a(prompt, tmp_path, gh, json.dumps({"broken:alpha:Site secret scan": "failure"}))
    assert any(l.startswith("ROW broken:alpha:Site secret scan STALE ") for l in lines)
    assert not any(" FIXED " in l for l in lines)
    assert not any("UNKNOWN" in l for l in lines)
    assert saved == {}


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_broken_item_unknown_only_when_the_workflows_own_read_fails(prompt, tmp_path):
    gh = {
        "repos": ["alpha"],
        "issues": {},
        "runs": {"Nishfleet/alpha": [_run_row("success", "Chatter", d) for d in range(_WINDOW_PUSHES)]},
    }
    lines, saved = _run_2a(prompt, tmp_path, gh, json.dumps({"broken:alpha:Deploy production": "failure"}))
    assert "ROW broken:alpha:Deploy production UNKNOWN" in lines
    assert saved == {"broken:alpha:Deploy production": "failure"}


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_broken_item_with_a_run_still_in_progress_is_unchanged(prompt, tmp_path):
    gh = {
        "repos": ["alpha"],
        "issues": {},
        "runs": {
            "Nishfleet/alpha": [_run_row("success", "Chatter", d) for d in range(_WINDOW_PUSHES)],
            "Nishfleet/alpha::Deploy production": [_run_row(None, "Deploy production", 0)],
        },
    }
    lines, saved = _run_2a(prompt, tmp_path, gh, json.dumps({"broken:alpha:Deploy production": "failure"}))
    assert "ROW broken:alpha:Deploy production UNCHANGED" in lines
    assert not any("UNKNOWN" in l for l in lines)
    assert saved == {"broken:alpha:Deploy production": "failure"}


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_stored_item_command_writes_nothing_when_the_store_is_unreadable(prompt, tmp_path):
    lines, saved = _run_2a(prompt, tmp_path, {"repos": [], "issues": {}, "runs": {}}, "not json")
    assert "STORED-UNREADABLE" in lines
    assert saved is None


def test_shipped_count_command_prints_a_total_or_fails_loudly(tmp_path):
    gh = {"repos": ["alpha", "beta"], "issues": {}, "runs": {}}
    env = _fake_box(tmp_path, gh, "{}")
    (tmp_path / "bin/gh").write_text(
        "#!/bin/sh\n"
        "case \"$1\" in repo) printf 'alpha\\nbeta\\n';; pr) case \"$4\" in Nishfleet/alpha) echo 3;; *) test \"$FAKE_FAIL\" = 1 && exit 1; echo 0;; esac;; esac\n"
    )
    for prompt in (MORNING, EVENING):
        text = prompt.read_text()
        start = text.index("S=$(date -u -d '12 hours ago' +%Y-%m-%dT%H:%M:%SZ); for r in")
        cmd = text[start:text.index("\n", start)]
        ok = subprocess.run(["bash", "-c", cmd], env=env, capture_output=True, text=True, timeout=60)
        assert ok.stdout.splitlines() == ["alpha 3", "TOTAL 3 REPOS 2"], ok.stdout
        bad = subprocess.run(["bash", "-c", cmd], env={**env, "FAKE_FAIL": "1"}, capture_output=True, text=True, timeout=60)
        assert bad.stdout.splitlines()[-1] == "COUNT FAILED", bad.stdout


def _run_3(prompt, tmp_path, gh):
    assert any(x.startswith("set -o pipefail") for x in prompt.read_text().splitlines()), prompt.name
    env = _fake_box(tmp_path, gh, "{}")
    r = subprocess.run(["bash", "-c", _command(prompt, "set -o pipefail")], env=env, capture_output=True, text=True, timeout=60)
    return r.stdout.splitlines()


def _listed(number, title, url, *labels, last=""):
    return {
        "number": number,
        "title": title,
        "url": url,
        "labels": [{"name": x} for x in labels],
        "comments": ([{"body": last}] if last else []),
    }


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_waiting_count_command_prints_the_total_and_the_remainder(prompt, tmp_path):
    gh = {
        "repos": ["alpha", "beta"],
        "lists": {
            "Nishfleet/alpha": [_listed(1, "a one", "u1", "needs-nish-decision"), _listed(2, "a two", "u2", "needs-nish-decision")],
            "Nishfleet/beta": [_listed(3, "b one", "u3", "needs-nish-decision", "priority-now", last="still waiting")],
        },
    }
    lines = _run_3(prompt, tmp_path, gh)
    assert lines[-2:] == ["WAITING_TOTAL 3", "WAITING_MORE 1"], lines
    assert lines[0] == '{"r":"alpha","n":1,"t":"a one","u":"u1","l":["needs-nish-decision"],"last":""}'
    assert lines[2] == '{"r":"beta","n":3,"t":"b one","u":"u3","l":["needs-nish-decision","priority-now"],"last":"still waiting"}'


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_waiting_count_command_skips_a_repository_with_issues_disabled(prompt, tmp_path):
    gh = {
        "repos": ["alpha", "beta"],
        "no_issues": ["beta"],
        "lists": {
            "Nishfleet/alpha": [_listed(1, "a one", "u1", "needs-nish-decision")],
            "Nishfleet/beta": [_listed(9, "never listed", "u9", "needs-nish-decision")],
        },
    }
    lines = _run_3(prompt, tmp_path, gh)
    assert lines == [
        '{"r":"alpha","n":1,"t":"a one","u":"u1","l":["needs-nish-decision"],"last":""}',
        "WAITING_TOTAL 1",
    ], lines


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_waiting_count_command_fails_loudly_when_a_repository_listing_fails(prompt, tmp_path):
    gh = {
        "repos": ["alpha", "beta"],
        "broken_lists": ["beta"],
        "lists": {"Nishfleet/alpha": [_listed(1, "a one", "u1", "needs-nish-decision")]},
    }
    lines = _run_3(prompt, tmp_path, gh)
    assert lines[-1] == "COUNT FAILED", lines
    assert not any(x.startswith("WAITING_TOTAL") for x in lines), lines


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_waiting_count_command_prints_zero_for_an_empty_backlog(prompt, tmp_path):
    lines = _run_3(prompt, tmp_path, {"repos": ["alpha", "beta"], "lists": {}})
    assert lines == ["WAITING_TOTAL 0"], lines


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_waiting_count_command_fails_loudly_when_the_repository_list_is_empty(prompt, tmp_path):
    lines = _run_3(prompt, tmp_path, {"repos": [], "lists": {}})
    assert lines == ["COUNT FAILED"], lines


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_waiting_count_command_has_no_command_substitution_in_its_loop(prompt):
    line = next(x for x in prompt.read_text().splitlines() if x.startswith("set -o pipefail"))
    loop = line[line.index("for r in"):line.index("; done")]
    assert "$(" not in loop, prompt.name


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_the_waiting_overflow_count_is_copied_from_a_printed_line(prompt):
    text = prompt.read_text()
    step = text[text.index("3 WAITING ON NISH"):text.index("4 CHANGED SINCE LAST DIGEST")]
    assert "WAITING_TOTAL" in step and "WAITING_MORE" in step
    assert '"and N more waiting"' in step
    assert "copied exactly from the WAITING_MORE line" in step
    assert "Never count the printed lines" in step
    assert "never show a count of labelled issues" in step
    assert "never show a count of your own" in step
    assert "if more items are new" not in step


FAKE_CURL = """#!/usr/bin/env python3
import os, sys
if "-w" in sys.argv:
    print(os.environ["FAKE_CODE"], end="")
else:
    sys.stdout.write(os.environ["FAKE_FEED"])
"""

_FEED = "<rss><channel><lastBuildDate>Thu, 15 Oct 2026 02:00:00 +0000</lastBuildDate><item><pubDate>Thu, 15 Oct 2026 02:00:00 +0000</pubDate></item></channel></rss>"


def _run_2b(tmp_path, store, code, feed):
    env = _fake_box(tmp_path, {"repos": [], "issues": {}, "runs": {}}, store)
    (tmp_path / "bin/curl").write_text(FAKE_CURL)
    (tmp_path / "bin/curl").chmod(0o755)
    env = {**env, "FAKE_CODE": code, "FAKE_FEED": feed, "TZ": "UTC"}
    r = subprocess.run(["bash", "-c", _site_command()], env=env, capture_output=True, text=True, timeout=60)
    saved = pathlib.Path(env["FAKE_SAVED"])
    return r.stdout.splitlines(), (json.loads(saved.read_text()) if saved.exists() else None)


def _site_command():
    text = EVENING.read_text()
    start = text.index("R=$(hermes cron notepad 3acce3a945cb get sent); test -z \"$R\" && R='{}'; W=$(printf '%s' \"$R\" | jq -c 'select(type==\"object\")|del(.inish)')")
    return text[start:text.index("\n", start)]


def test_site_check_stores_the_newest_edition_date(tmp_path):
    lines, saved = _run_2b(tmp_path, json.dumps({"inish": "200|2026-09-29", "wait:a#1": "open|x"}), "200", _FEED)
    assert lines == ["ROW site CHANGED 200|2026-10-15", "STORED-SAVED"]
    assert saved == {"wait:a#1": "open|x", "site": "200|2026-10-15"}


def test_site_check_with_the_same_edition_is_unchanged(tmp_path):
    lines, _ = _run_2b(tmp_path, json.dumps({"site": "200|2026-10-15"}), "200", _FEED)
    assert lines[0] == "ROW site UNCHANGED 200|2026-10-15"


def test_site_check_without_a_feed_date_is_unknown_and_saves_nothing(tmp_path):
    lines, saved = _run_2b(tmp_path, json.dumps({"site": "200|2026-10-14"}), "200", "<html></html>")
    assert lines == ["ROW site UNKNOWN"]
    assert saved is None


def test_site_check_with_a_failing_page_is_unknown(tmp_path):
    lines, saved = _run_2b(tmp_path, "{}", "500", _FEED)
    assert lines == ["ROW site UNKNOWN"]
    assert saved is None
