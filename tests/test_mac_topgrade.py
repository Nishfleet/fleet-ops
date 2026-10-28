"""The Mac's daily topgrade job runs from this repo's copy (fleet-ops#10508).

The job was hand-written, lived in no repo and had no test, so a schedule
change, a dropped argument or an absolute home path reaching launchd (which
does not expand `~`) went unseen. This file pins what mac/ must say: one run a
day at 04:30 local time at low priority, the four arguments, the same enabled
and disabled topgrade steps and custom commands, and no home path in either
file.
"""

import plistlib
import tomllib
from pathlib import Path
from typing import Iterator

ROOT = Path(__file__).resolve().parents[1]
PLIST = ROOT / "mac/com.nish.topgrade.plist"
CONFIG = ROOT / "mac/topgrade.toml"
CI = ROOT / ".github/workflows/ci.yml"

HOME_PREFIXES = ("/Users/",)


def strings(value: object) -> Iterator[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def plist() -> dict:
    with PLIST.open("rb") as handle:
        return plistlib.load(handle)


def config() -> dict:
    return tomllib.loads(CONFIG.read_text())


def test_runs_topgrade_once_a_day_at_0430_with_no_prompts():
    assert plist()["Label"] == "com.nish.topgrade"
    assert plist()["ProgramArguments"] == [
        "/opt/homebrew/bin/topgrade",
        "--yes",
        "--no-ask-retry",
        "--no-self-update",
    ]
    assert plist()["StartCalendarInterval"] == {"Hour": 4, "Minute": 30}


def test_runs_at_low_priority():
    assert plist()["ProcessType"] == "Background"
    assert plist()["LowPriorityIO"] is True
    assert plist()["Nice"] == 10


def test_path_lists_only_directories_launchd_can_reach():
    environment = plist()["EnvironmentVariables"]
    assert environment == {"PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"}
    for directory in environment["PATH"].split(":"):
        assert directory.startswith("/"), f"{directory} is not an absolute path"


def test_plist_has_no_home_path():
    offenders = [
        value for value in strings(plist())
        if "~" in value or any(home in value for home in HOME_PREFIXES)
    ]
    assert offenders == [], (
        f"{offenders} in {PLIST.name}: launchd does not expand `~`, and a home path "
        "pins the job to one account's home directory"
    )


def test_config_runs_the_same_steps():
    assert config()["misc"] == {
        "assume_yes": True,
        "no_retry": True,
        "notify_end": "never",
        "no_self_update": True,
        "disable": [
            "brew_formula",
            "brew_cask",
            "mas",
            "system",
            "gem",
            "ruby_gems",
            "hermes_agent",
            "self_update",
            "remotes",
            "restarts",
            "cursor_agent",
            "node",
            "skills",
            "github_cli_skills",
            "claude_code_plugins",
        ],
    }


def test_config_runs_the_same_custom_commands():
    assert config()["commands"] == {
        "npm local (~/.local: pi, rea-agents)": "/opt/homebrew/bin/npm update -g --prefix ~/.local",
        "npm brew (/opt/homebrew globals)": "/opt/homebrew/bin/npm update -g --prefix /opt/homebrew",
        "grok": "~/.local/bin/grok update",
        "herdr": "~/.local/bin/herdr update",
    }


def test_config_has_no_absolute_home_path():
    text = CONFIG.read_text()
    for home in HOME_PREFIXES:
        assert home not in text, f"{home} in {CONFIG.name}"


def test_config_expands_tilde_only_where_topgrade_expands_it():
    table = ""
    offenders = []
    for line in CONFIG.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            table = stripped
        elif "~" in stripped and not stripped.startswith("#") and table != "[commands]":
            offenders.append(line)
    assert offenders == [], f"{offenders} use `~` outside [commands], which topgrade does not expand"


def test_ci_runs_this_file():
    assert "tests/test_mac_topgrade.py" in CI.read_text()
