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
- the stored-item command discovers every open issue labelled
  needs-nish-decision from the repositories it reads, stores each one, and
  prints WAITING-UNREAD for a repository whose list could not be read, so a
  labelled decision can never be missed by a title judgement
  (fleet-ops#9741),
- the waiting step runs no command of its own: the label alone decides, and a
  stored issue whose label was removed prints UNLABELLED and drops out
  (fleet-ops#9741),
- a repository with issues enabled and no labelled issue reads as empty, not as
  unreadable, and stores no key for it, so a healthy repository cannot flood the
  reply with a false unread line (fleet-ops#9741),
- a stored broken item is classified from that workflow's own latest run on
  main, read directly, so a busy main branch cannot push the workflow out of a
  run window and turn a real status into an unreadable one (fleet-ops#9902),
- a stored broken item whose latest run passed before the digest window started
  is dropped as STALE and never reported as newly fixed, because a pass from
  days earlier is not a repair that happened now (fleet-ops#9924),
- a stored wait item closed as not planned is never reported as FIXED, so a
  decision Nish declined is not shipped to him as a fix (fleet-ops#10289),
- the evening site check stores a timestamped site_checked row on every run, so
  an audit can verify the nightly publish claim after the fact, and the reply
  carries one short line when that row could not be saved (fleet-ops#9862),
- and the evening site check never writes over a store it could not read, so a
  run that reads nothing leaves every stored wait and broken item alone, and it
  reports STORED-SAVE-FAILED instead of claiming the row was saved
  (fleet-ops#9862),
- ansible/host.yml applies the prompts to the live jobs,
- and it deletes the named retired jobs from the same cron store, so a proof job
  whose issue has closed stops existing, while a fresh one is left alone
  (fleet-ops#10545).
"""
import datetime
import fnmatch
import json
import pathlib
import re
import shutil
import subprocess

import pytest
import ansible_host

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
        line = next(x for x in prompt.read_text().splitlines() if "COUNT FAILED" in x and "for r in" in x)
        loop = line[line.index("do "):line.index("; done")]
        assert "$(" not in loop, prompt.name


def test_host_yml_applies_the_prompts_to_the_live_jobs():
    text = ansible_host.text()
    assert "config/hermes/" in text
    assert "digest-morning" in text and "digest-evening" in text
    assert "- cron" in text and "- edit" in text and "- --prompt" in text


def test_ci_runs_this_file():
    # ci.yml finds every test under tests/ (fleet-ops#10721), so this file runs without being named there.
    assert re.search(r"pytest\b[^\n]*\stests(\s|$)", CI.read_text()), "ci.yml has no step that runs pytest on the whole tests/ directory"


FAKE_GH = """#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
d = json.load(open(os.environ["FAKE_GH"]))
if a[:2] == ["repo", "list"]:
    if d.get("failrepos"):
        print("the repositories could not be read", file=sys.stderr)
        sys.exit(1)
    repos = d["repos"]
    if "--jq" in a:
        jq = a[a.index("--jq") + 1]
        if "hasIssuesEnabled" in jq:
            repos = [r for r in repos if r not in d.get("noissues", [])]
        print("\\n".join(repos))
    else:
        print(json.dumps([{"name": r, "hasIssuesEnabled": r not in d.get("noissues", [])} for r in repos]))
elif a[:2] == ["issue", "list"]:
    repo = a[a.index("--repo") + 1]
    if repo.split("/")[-1] in d.get("faillist", []):
        print("the repository could not be read", file=sys.stderr)
        sys.exit(1)
    if repo.split("/")[-1] in d.get("silentfail", []):
        sys.exit(1)
    out = []
    for key, obj in d["issues"].items():
        if not key.startswith(repo + "#"):
            continue
        if obj.get("state") != "OPEN":
            continue
        if "needs-nish-decision" not in [x["name"] for x in obj.get("labels", [])]:
            continue
        num = int(key.rsplit("#", 1)[1])
        out.append({"number": num, "title": obj.get("title", "issue %d" % num), "url": obj.get("url", ""), "labels": obj.get("labels", [])})
    print(json.dumps(out))
elif a[:2] == ["issue", "view"]:
    key = a[a.index("--repo") + 1] + "#" + a[2]
    if key not in d["issues"]:
        sys.exit(1)
    print(json.dumps(d["issues"][key]))
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
    if os.environ.get("FAKE_SET_FAIL"):
        sys.exit(1)
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
    bindir.mkdir(exist_ok=True)
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


def _issue(state, *labels, state_reason="COMPLETED"):
    return {"state": state, "stateReason": state_reason if state == "CLOSED" else None, "labels": [{"name": x} for x in labels], "url": "https://example.com/i"}


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
            "Nishfleet/alpha#5": _issue("OPEN", "priority-now"),
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
        "wait:alpha#5": "open|needs-nish-decision",
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
        "wait:alpha#5": "UNLABELLED",
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


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_wait_item_closed_as_not_planned_is_not_reported_as_fixed(prompt, tmp_path):
    gh = {
        "repos": ["alpha"],
        "issues": {
            "Nishfleet/alpha#7": _issue("CLOSED", "needs-nish-decision", state_reason="NOT_PLANNED"),
            "Nishfleet/alpha#8": _issue("CLOSED", "needs-nish-decision", state_reason=None),
        },
        "runs": {"Nishfleet/alpha": []},
    }
    store = json.dumps({"wait:alpha#7": "open|needs-nish-decision", "wait:alpha#8": "open|needs-nish-decision"})
    lines, saved = _run_2a(prompt, tmp_path, gh, store)
    assert "ROW wait:alpha#7 NOT-PLANNED https://example.com/i" in lines
    assert "ROW wait:alpha#8 NOT-PLANNED https://example.com/i" in lines
    assert not any(" FIXED " in l for l in lines)
    assert saved == {}


_WINDOW_PUSHES = 30


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_waiting_issue_not_in_the_store_is_discovered_and_stored(prompt, tmp_path):
    gh = {
        "repos": ["alpha", "quiet"],
        "noissues": ["quiet"],
        "issues": {
            "Nishfleet/alpha#6": _issue("OPEN", "needs-nish-decision"),
            "Nishfleet/alpha#7": _issue("OPEN", "needs-nish-decision"),
            "Nishfleet/alpha#8": _issue("OPEN", "needs-nish-decision", "priority-now"),
            "Nishfleet/alpha#9": _issue("OPEN", "agent-ready"),
            "Nishfleet/alpha#10": _issue("CLOSED", "needs-nish-decision"),
        },
        "runs": {"Nishfleet/alpha": [], "Nishfleet/quiet": []},
    }
    lines, saved = _run_2a(prompt, tmp_path, gh, json.dumps({"wait:alpha#6": "open|needs-nish-decision"}))
    rows = {l.split(" ")[1]: l.split(" ")[2] for l in lines if l.startswith("ROW ")}
    assert rows["wait:alpha#6"] == "UNCHANGED"
    assert rows["wait:alpha#7"] == "NEW"
    assert rows["wait:alpha#8"] == "NEW"
    assert not any("alpha#9" in l or "alpha#10" in l for l in lines)
    assert not any("WAITING-UNREAD" in l for l in lines)
    assert "UNCHANGED_TOTAL 1" in lines
    assert saved == {
        "wait:alpha#6": "open|needs-nish-decision",
        "wait:alpha#7": "open|needs-nish-decision",
        "wait:alpha#8": "open|needs-nish-decision,priority-now",
    }


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_waiting_discovery_repo_failure_is_loud_and_the_rest_is_stored(prompt, tmp_path):
    gh = {
        "repos": ["alpha", "beta"],
        "faillist": ["beta"],
        "issues": {"Nishfleet/alpha#7": _issue("OPEN", "needs-nish-decision")},
        "runs": {"Nishfleet/alpha": [], "Nishfleet/beta": []},
    }
    lines, saved = _run_2a(prompt, tmp_path, gh, "{}")
    assert "WAITING-UNREAD beta" in lines
    assert "ROW wait:alpha#7 NEW https://example.com/i" in lines
    assert lines[-1] == "STORED-SAVED"
    assert saved == {"wait:alpha#7": "open|needs-nish-decision"}


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_waiting_discovery_skips_a_repository_with_issues_disabled(prompt, tmp_path):
    gh = {
        "repos": ["alpha", "quiet"],
        "noissues": ["quiet"],
        "faillist": ["quiet"],
        "issues": {"Nishfleet/alpha#7": _issue("OPEN", "needs-nish-decision")},
        "runs": {"Nishfleet/alpha": [], "Nishfleet/quiet": []},
    }
    lines, saved = _run_2a(prompt, tmp_path, gh, "{}")
    assert not any("WAITING-UNREAD" in l for l in lines)
    assert saved == {"wait:alpha#7": "open|needs-nish-decision"}


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_waiting_discovery_repo_list_failure_is_loud(prompt, tmp_path):
    gh = {
        "repos": ["alpha"],
        "failrepos": True,
        "issues": {"Nishfleet/alpha#7": _issue("OPEN", "needs-nish-decision")},
        "runs": {"Nishfleet/alpha": []},
    }
    lines, saved = _run_2a(prompt, tmp_path, gh, "{}")
    assert "WAITING-UNREAD all" in lines
    assert not any(l.startswith("ROW wait:") for l in lines)
    assert saved == {}


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_waiting_discovery_repo_list_failure_keeps_the_stored_items(prompt, tmp_path):
    gh = {
        "repos": ["alpha"],
        "failrepos": True,
        "issues": {"Nishfleet/alpha#6": _issue("OPEN", "needs-nish-decision")},
        "runs": {"Nishfleet/alpha": []},
    }
    lines, saved = _run_2a(
        prompt,
        tmp_path,
        gh,
        json.dumps({"wait:alpha#6": "open|needs-nish-decision", "broken:alpha:ci": "failure"}),
    )
    assert "WAITING-UNREAD all" in lines
    assert "ROW wait:alpha#6 UNCHANGED" in lines
    assert "ROW broken:alpha:ci UNKNOWN" in lines
    assert saved == {"wait:alpha#6": "open|needs-nish-decision", "broken:alpha:ci": "failure"}


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_waiting_discovery_reads_a_repository_with_no_labelled_issue_as_empty(prompt, tmp_path):
    gh = {
        "repos": ["alpha", "empty"],
        "issues": {"Nishfleet/alpha#7": _issue("OPEN", "needs-nish-decision")},
        "runs": {"Nishfleet/alpha": [], "Nishfleet/empty": []},
    }
    lines, saved = _run_2a(prompt, tmp_path, gh, "{}")
    assert not any("WAITING-UNREAD" in l for l in lines)
    assert "ROW wait:alpha#7 NEW https://example.com/i" in lines
    assert saved == {"wait:alpha#7": "open|needs-nish-decision"}


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_waiting_discovery_is_loud_when_gh_fails_without_output(prompt, tmp_path):
    gh = {
        "repos": ["alpha", "beta"],
        "silentfail": ["beta"],
        "issues": {"Nishfleet/alpha#7": _issue("OPEN", "needs-nish-decision")},
        "runs": {"Nishfleet/alpha": [], "Nishfleet/beta": []},
    }
    lines, saved = _run_2a(prompt, tmp_path, gh, "{}")
    assert "WAITING-UNREAD beta" in lines
    assert "ROW wait:alpha#7 NEW https://example.com/i" in lines
    assert saved == {"wait:alpha#7": "open|needs-nish-decision"}


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_waiting_count_is_the_labelled_backlog_not_the_rows_it_printed(prompt, tmp_path):
    labelled, stored = 68, 46
    issues = {f"Nishfleet/alpha#{n}": _issue("OPEN", "needs-nish-decision") for n in range(1, labelled + 1)}
    store = {f"wait:alpha#{n}": "open|needs-nish-decision" for n in range(1, stored + 1)}
    gh = {"repos": ["alpha"], "issues": issues, "runs": {"Nishfleet/alpha": []}}
    lines, saved = _run_2a(prompt, tmp_path, gh, json.dumps(store))
    assert lines[:2] == [f"WAITING_TOTAL {labelled}", f"WAITING_MORE {labelled - 2}"], lines[:2]
    assert len([l for l in lines if " NEW " in l]) == labelled - stored
    assert f"UNCHANGED_TOTAL {stored}" in lines
    assert len(saved) == labelled


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_waiting_count_carries_no_overflow_when_the_whole_backlog_fits(prompt, tmp_path):
    gh = {
        "repos": ["alpha"],
        "issues": {
            "Nishfleet/alpha#1": _issue("OPEN", "needs-nish-decision"),
            "Nishfleet/alpha#2": _issue("OPEN", "needs-nish-decision", "priority-now"),
        },
        "runs": {"Nishfleet/alpha": []},
    }
    lines, saved = _run_2a(prompt, tmp_path, gh, "{}")
    assert lines[0] == "WAITING_TOTAL 2", lines
    assert not any(l.startswith("WAITING_MORE") for l in lines), lines
    assert len(saved) == 2


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_waiting_count_fails_loudly_when_a_repository_could_not_be_read(prompt, tmp_path):
    gh = {
        "repos": ["alpha", "beta"],
        "faillist": ["beta"],
        "issues": {"Nishfleet/alpha#1": _issue("OPEN", "needs-nish-decision")},
        "runs": {"Nishfleet/alpha": [], "Nishfleet/beta": []},
    }
    lines, saved = _run_2a(prompt, tmp_path, gh, "{}")
    assert "WAITING_COUNT FAILED" in lines, lines
    assert not any(l.startswith("WAITING_TOTAL") or l.startswith("WAITING_MORE") for l in lines), lines
    assert "WAITING-UNREAD beta" in lines
    assert "ROW wait:alpha#1 NEW https://example.com/i" in lines
    assert saved == {"wait:alpha#1": "open|needs-nish-decision"}


def test_the_reply_copies_the_printed_waiting_count():
    for prompt in (MORNING, EVENING):
        text = prompt.read_text()
        step = next(l for l in text.splitlines() if l.startswith("3 WAITING ON NISH"))
        assert "copied exactly from that WAITING_MORE line" in step, prompt.name
        assert "never count the ROW lines" in step, prompt.name
        assert "WAITING_COUNT FAILED" in step, prompt.name
        assert "Never show the count of labelled issues" not in text, prompt.name


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_waiting_discovery_names_a_stored_issue_once(prompt, tmp_path):
    gh = {
        "repos": ["alpha"],
        "issues": {"Nishfleet/alpha#6": _issue("OPEN", "needs-nish-decision")},
        "runs": {"Nishfleet/alpha": []},
    }
    lines, saved = _run_2a(prompt, tmp_path, gh, json.dumps({"wait:alpha#6": "open|needs-nish-decision"}))
    rows = [l for l in lines if l.startswith("ROW wait:alpha#6 ")]
    assert rows == ["ROW wait:alpha#6 UNCHANGED"]
    assert saved == {"wait:alpha#6": "open|needs-nish-decision"}


def test_both_digests_run_the_same_waiting_discovery():
    segs = []
    for prompt in (MORNING, EVENING):
        line = next(x for x in prompt.read_text().splitlines() if "D=$(RL=" in x)
        seg = line[line.index("D=$(RL="):]
        segs.append(seg[:seg.index("; done)") + len("; done)")])
    assert segs[0] == segs[1]


def test_waiting_discovery_loop_has_no_command_substitution_in_its_body():
    for prompt in (MORNING, EVENING):
        line = next(x for x in prompt.read_text().splitlines() if "D=$(RL=" in x)
        seg = line[line.index("D=$(RL="):]
        body = seg[seg.index("do "):seg.index("; done")]
        assert "$(" not in body, prompt.name


def test_the_waiting_discovery_command_is_the_only_labelled_sweep():
    for prompt in (MORNING, EVENING):
        assert prompt.read_text().count("--label needs-nish-decision --state open") == 1, prompt.name


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


@pytest.mark.parametrize("prompt", [MORNING, EVENING])
def test_stored_item_command_carries_the_site_checked_row(prompt, tmp_path):
    store = json.dumps(
        {
            "site": "200|2026-10-15",
            "site_checked": "200|2026-10-15|2026-10-15T20:00:00Z",
        }
    )
    lines, saved = _run_2a(prompt, tmp_path, {"repos": [], "issues": {}, "runs": {}}, store)
    assert "STORED-SAVED" in lines
    assert saved == {
        "site": "200|2026-10-15",
        "site_checked": "200|2026-10-15|2026-10-15T20:00:00Z",
    }


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


FAKE_CURL = """#!/usr/bin/env python3
import os, sys
if "-w" in sys.argv:
    print(os.environ["FAKE_CODE"], end="")
else:
    sys.stdout.write(os.environ["FAKE_FEED"])
"""

_FEED = "<rss><channel><lastBuildDate>Thu, 15 Oct 2026 02:00:00 +0000</lastBuildDate><item><pubDate>Thu, 15 Oct 2026 02:00:00 +0000</pubDate></item></channel></rss>"


def _run_2b(tmp_path, store, code, feed, set_fails=False):
    env = _fake_box(tmp_path, {"repos": [], "issues": {}, "runs": {}}, store)
    (tmp_path / "bin/curl").write_text(FAKE_CURL)
    (tmp_path / "bin/curl").chmod(0o755)
    env = {**env, "FAKE_CODE": code, "FAKE_FEED": feed, "TZ": "UTC"}
    if set_fails:
        env["FAKE_SET_FAIL"] = "1"
    lo = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    r = subprocess.run(["bash", "-c", _site_command()], env=env, capture_output=True, text=True, timeout=60)
    hi = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=1)
    saved = pathlib.Path(env["FAKE_SAVED"])
    return r.stdout.splitlines(), (json.loads(saved.read_text()) if saved.exists() else None), (lo, hi)


def _site_command():
    text = EVENING.read_text()
    start = text.index("R=$(hermes cron notepad 3acce3a945cb get sent); W=$(printf '%s' \"$R\" | jq -c 'select(type==\"object\")|del(.inish)')")
    return text[start:text.index("\n", start)]


_STAMP = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")


def _checked(saved, window):
    parts = saved["site_checked"].split("|")
    assert len(parts) == 3 and _STAMP.fullmatch(parts[2]), f"site_checked is not code|edition|UTC stamp: {saved['site_checked']!r}"
    when = datetime.datetime.strptime(parts[2], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    lo, hi = window
    assert lo <= when <= hi, f"site check timestamp {parts[2]} is outside the run window {lo.isoformat()}..{hi.isoformat()}"
    return parts[0], parts[1]


def _without_checked(saved):
    return {k: v for k, v in saved.items() if k != "site_checked"}


def test_site_check_stores_the_newest_edition_date(tmp_path):
    lines, saved, window = _run_2b(tmp_path, json.dumps({"inish": "200|2026-09-29", "wait:a#1": "open|x"}), "200", _FEED)
    assert lines == ["ROW site CHANGED 200|2026-10-15", "STORED-SAVED"]
    assert _without_checked(saved) == {"wait:a#1": "open|x", "site": "200|2026-10-15"}
    assert _checked(saved, window) == ("200", "2026-10-15")


def test_site_check_with_the_same_edition_is_unchanged(tmp_path):
    lines, saved, window = _run_2b(tmp_path, json.dumps({"site": "200|2026-10-15"}), "200", _FEED)
    assert lines == ["ROW site UNCHANGED 200|2026-10-15", "STORED-SAVED"]
    assert _without_checked(saved) == {"site": "200|2026-10-15"}
    assert _checked(saved, window) == ("200", "2026-10-15")


def test_site_check_without_a_feed_date_still_stores_a_checked_row(tmp_path):
    lines, saved, window = _run_2b(tmp_path, json.dumps({"site": "200|2026-10-14"}), "200", "<html></html>")
    assert lines == ["ROW site UNKNOWN", "STORED-SAVED"]
    assert _without_checked(saved) == {"site": "200|2026-10-14"}
    assert _checked(saved, window) == ("200", "none")


def test_site_check_with_a_failing_page_still_stores_a_checked_row(tmp_path):
    lines, saved, window = _run_2b(tmp_path, "{}", "500", _FEED)
    assert lines == ["ROW site UNKNOWN", "STORED-SAVED"]
    assert saved.keys() == {"site_checked"}
    assert _checked(saved, window) == ("500", "none")


def test_site_check_stores_nothing_when_the_store_is_unreadable(tmp_path):
    lines, saved, _ = _run_2b(tmp_path, "not json", "200", _FEED)
    assert lines == ["ROW site UNSTORED 200|2026-10-15", "STORED-UNREADABLE"]
    assert saved is None


def test_site_check_stores_nothing_when_the_store_read_returns_nothing(tmp_path):
    lines, saved, _ = _run_2b(tmp_path, "", "200", _FEED)
    assert lines == ["ROW site UNSTORED 200|2026-10-15", "STORED-UNREADABLE"]
    assert saved is None


def test_site_check_reports_a_failed_save(tmp_path):
    lines, saved, _ = _run_2b(tmp_path, json.dumps({"site": "200|2026-10-14", "wait:a#1": "open|x"}), "200", _FEED, set_fails=True)
    assert lines == ["ROW site CHANGED 200|2026-10-15", "STORED-SAVE-FAILED"]
    assert saved is None


def test_site_check_reports_the_page_result_even_when_the_store_was_not_read(tmp_path):
    for code, feed, rows in (
        ("200", _FEED, ["ROW site UNSTORED 200|2026-10-15", "STORED-UNREADABLE"]),
        ("500", _FEED, ["ROW site UNKNOWN", "STORED-UNREADABLE"]),
        ("200", "<html></html>", ["ROW site UNKNOWN", "STORED-UNREADABLE"]),
    ):
        lines, saved, _ = _run_2b(tmp_path, "not json", code, feed)
        assert lines == rows, (code, lines)
        assert saved is None


def test_the_evening_sequence_carries_the_checked_row_from_2a_into_2b(tmp_path):
    gh = {"repos": [], "issues": {}, "runs": {}}
    two_a, stored_after_2a = _run_2a(EVENING, tmp_path, gh, "{}")
    assert two_a == ["WAITING_TOTAL 0", "UNCHANGED_TOTAL 0", "STORED-SAVED"], two_a
    assert stored_after_2a == {}
    (tmp_path / "bin/curl").write_text(FAKE_CURL)
    (tmp_path / "bin/curl").chmod(0o755)
    env = {**_fake_box(tmp_path, gh, json.dumps(stored_after_2a)), "FAKE_CODE": "200", "FAKE_FEED": _FEED, "TZ": "UTC"}
    lo = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    out = subprocess.run(["bash", "-c", _site_command()], env=env, capture_output=True, text=True, timeout=60)
    hi = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=1)
    saved = json.loads(pathlib.Path(env["FAKE_SAVED"]).read_text())
    assert out.stdout.splitlines() == ["ROW site CHANGED 200|2026-10-15", "STORED-SAVED"]
    assert _checked(saved, (lo, hi)) == ("200", "2026-10-15")


PRUNE = "Delete the retired jobs from Hermes' cron store"
READ = "Read Hermes' scheduled jobs"
REREAD = "Read Hermes' scheduled jobs again"
GUARD = "Fail when the retired Hermes reminder job is still in the store"

FAKE_CRON_STUB = """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if args[:2] != ["cron", "remove"] or len(args) != 3:
    sys.exit("unexpected call: %r" % (args,))
store = os.environ["FAKE_STORE"]
jobs = json.load(open(store))["jobs"]
left = [j for j in jobs if j["id"] != args[2]]
if len(left) == len(jobs):
    sys.exit("no such job: " + args[2])
json.dump({"jobs": left}, open(store, "w"))
open(os.environ["FAKE_LOG"], "a").write(args[2] + chr(10))
"""


def _cron(expr):
    return {"kind": "cron", "expr": expr, "display": expr}


def _once(offset_days):
    at = datetime.datetime.now().astimezone().replace(hour=10, minute=0, second=0, microsecond=0)
    at += datetime.timedelta(days=offset_days)
    return {"kind": "once", "run_at": at.isoformat(timespec="seconds"), "display": at.strftime("once at %Y-%m-%d %H:%M")}


def _job(job_id, name, enabled, **schedule):
    return {"id": job_id, "name": name, "enabled": enabled, "schedule": schedule}


CRON_LIVE = [
    _job("3acce3a945cb", "digest-morning", True, **_cron("0 8 * * *")),
    _job("682de9846caa", "digest-evening", True, **_cron("0 20 * * *")),
    _job("9fdc0c9fff6c", "scorecard-weekly", True, **_cron("0 9 * * 1")),
    _job("b30761322118", "audit-claims", True, **_cron("30 8,20 * * *")),
    _job("783b31b9d5e5", "audit-urgent", True, **_cron("50 8,20 * * *")),
    _job("6362250bf181", "audit-file", True, **_cron("10 9,21 * * *")),
    _job("4231290e3e00", "sec-k3-key-renewal", True, **_once(400)),
    _job("1145b749d731", "sec-daily-summary", True, **_cron("0 21 * * *")),
    _job("33199b7bfff5", "sec-coordinator-backstop", True, **_cron("41 */6 * * *")),
]

CRON_RETIRED_REMINDER = [
    _job("527a50bfda03", "remind-orchestrator-app", True, **_cron("0 10 * * *")),
]

CRON_PROOF = [
    _job("13d3db49b9c5", "tmp-9579-proof", True, **_cron("0 20 1 1 *")),
    _job("f16c57bb6885", "tmp-9717-proof", True, **_cron("0 0 1 1 *")),
]

CRON_EXPIRED = [
    _job("d4efa85f43c3", "sec-k1-limited-key", False, **_once(-5)),
    _job("50229bbf6c4a", "sec-r2-deadline", False, **_once(-2)),
    _job("0de3952d8ecb", "sec-r2-precheck", False, **_once(-3)),
    _job("df6163647275", "sec-k2-cloudflare-key", False, **_once(-2)),
    _job("bdc37cb70a4a", "sec-c5-before-monday", False, **_once(-3)),
    _job("fc1c6a815b80", "sec-dnssec-cf-registrar", False, **_once(-5)),
    _job("7eda90c8dd97", "sec-morning-yes-1023", False, **_once(-5)),
]

CRON_KEPT = [
    _job("eba16b1df90e", "tmp-9737-proof", False, **_cron("5 22 * * *")),
    _job("111111111111", "sec-future-reminder", False, **_once(3)),
    _job("222222222222", "atmp-proof", True, **_cron("0 7 4 4 *")),
    _job("333333333333", "tmp-10600-proof", True, **_once(2)),
]


def _retired_ids():
    lines = ansible_host.text().splitlines()
    out = []
    for line in lines[lines.index("    hermes_retired_jobs:") + 1 :]:
        if line.startswith("      #"):
            continue
        if not line.startswith("      - "):
            break
        out.append(line.split("- ", 1)[1].strip())
    return out


def _task_text(name):
    lines = ansible_host.text().splitlines()
    start = lines.index(f"    - name: {name}")
    end = start + 1
    while end < len(lines) and not lines[end].startswith("    - "):
        end += 1
    block = [line for line in lines[start:end] if line.strip() not in ("become: true", "become_user: nish")]
    while block and not block[-1].strip():
        block.pop()
    return block


def _prune(tmp_path, jobs, guard=False, retired=None):
    if shutil.which("ansible-playbook") is None:
        pytest.skip("ansible-playbook is not installed")
    stub = tmp_path / ".local/bin/hermes"
    stub.parent.mkdir(parents=True, exist_ok=True)
    stub.write_text(FAKE_CRON_STUB)
    stub.chmod(0o755)
    store = tmp_path / ".hermes/cron/jobs.json"
    store.parent.mkdir(parents=True, exist_ok=True)
    if jobs is not None:
        store.write_text(json.dumps({"jobs": jobs}))
    log = tmp_path / "calls.log"
    log.write_text("")
    playbook = tmp_path / "prune.yml"
    playbook.write_text(
        "\n".join(
            [
                "- hosts: localhost",
                "  connection: local",
                "  gather_facts: false",
                "  vars:",
                f"    nish_home: {tmp_path}",
                f"    hermes_retired_jobs: {json.dumps(_retired_ids() if retired is None else retired)}",
                "    nish_env:",
                f"      HOME: {tmp_path}",
                f"      PATH: {stub.parent}:/usr/local/bin:/usr/bin:/bin",
                f"      FAKE_STORE: {store}",
                f"      FAKE_LOG: {log}",
                "  tasks:",
                *_task_text(READ),
                *_task_text(PRUNE),
                *(_task_text(REREAD) if guard else []),
                *(_task_text(GUARD) if guard else []),
                "",
            ]
        )
    )
    run = subprocess.run(
        ["ansible-playbook", "-i", "localhost,", str(playbook)],
        cwd=tmp_path,
        env={"HOME": str(tmp_path), "PATH": "/usr/local/bin:/usr/bin:/bin", "ANSIBLE_LOCALHOST_WARNING": "false"},
        capture_output=True,
        text=True,
        timeout=300,
    )
    left = json.loads(store.read_text())["jobs"] if store.exists() else None
    if not guard:
        assert run.returncode == 0, run.stdout + run.stderr
    return left, log.read_text().split(), run.returncode, run.stdout + run.stderr


def test_the_host_jobs_remove_the_retired_jobs_and_the_expired_one_shots(tmp_path):
    retired = CRON_RETIRED_REMINDER + CRON_PROOF + CRON_EXPIRED
    assert _retired_ids() == [job["id"] for job in retired]
    jobs, calls, _, _ = _prune(tmp_path, CRON_LIVE + retired + CRON_KEPT)
    assert sorted(calls) == sorted(job["id"] for job in retired)
    assert jobs == CRON_LIVE + CRON_KEPT


def test_the_reminder_guard_passes_once_the_job_is_gone(tmp_path):
    retired = CRON_RETIRED_REMINDER + CRON_PROOF + CRON_EXPIRED
    jobs, calls, rc, out = _prune(tmp_path, CRON_LIVE + retired + CRON_KEPT, guard=True)
    assert jobs == CRON_LIVE + CRON_KEPT
    assert rc == 0, out


def test_the_reminder_guard_fails_while_the_job_is_still_in_the_store(tmp_path):
    wrong_id = [job["id"] for job in CRON_PROOF + CRON_EXPIRED]
    jobs, calls, rc, out = _prune(tmp_path, CRON_LIVE + CRON_RETIRED_REMINDER + CRON_KEPT, guard=True, retired=wrong_id)
    assert calls == []
    assert [job for job in jobs if job["name"] == "remind-orchestrator-app"] == CRON_RETIRED_REMINDER
    assert rc != 0
    assert "hermes_retired_jobs" in out


def test_the_host_jobs_leave_a_fresh_proof_job_alone(tmp_path):
    fresh = _job("444444444444", "tmp-10600-proof", True, **_once(0))
    jobs, calls, _, _ = _prune(tmp_path, CRON_LIVE + [fresh])
    assert calls == []
    assert jobs == CRON_LIVE + [fresh]


def test_the_host_jobs_remove_nothing_on_a_second_run(tmp_path):
    jobs, _, _, _ = _prune(tmp_path, CRON_LIVE + CRON_RETIRED_REMINDER + CRON_PROOF + CRON_EXPIRED + CRON_KEPT)
    again, calls, _, _ = _prune(tmp_path, jobs)
    assert calls == []
    assert again == jobs


def test_the_host_jobs_remove_nothing_without_a_store(tmp_path):
    jobs, calls, _, _ = _prune(tmp_path, None)
    assert calls == []
    assert jobs is None
