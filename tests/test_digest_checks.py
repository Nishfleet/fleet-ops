"""The digest fact checks (Nishfleet/fleet-ops#9706 follow-up).

The evening digest's site row was always UNKNOWN because it read a feed
address that redirects to an HTML page, and the shipped and watch rows were
blocked by the shell guard in Hermes before they ran. This file keeps the
canonical prompts under config/hermes/ honest:

- the site check reads the real feed and the real page,
- no command line matches the guard's deny globs for a pipe from curl,
- no command uses a bare bracket test, which the guard cannot resolve,
- ansible/host.yml applies the prompts to the live jobs.
"""
import fnmatch
import pathlib
import re

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
    text = HOST.read_text()
    assert "config/hermes/" in text
    assert "digest-morning" in text and "digest-evening" in text
    assert "- cron" in text and "- edit" in text and "- --prompt" in text


def test_ci_runs_this_file():
    assert "tests/test_digest_checks.py" in CI.read_text()
