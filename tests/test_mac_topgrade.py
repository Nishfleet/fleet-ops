"""The Mac's daily topgrade job runs from mac/, one run a day, unchanged, with no home path."""
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
    job = plist()
    assert job["Label"] == "com.nish.topgrade"
    assert job["ProgramArguments"] == [
        "/opt/homebrew/bin/topgrade",
        "--yes",
        "--no-ask-retry",
        "--no-self-update",
    ]
    assert job["StartCalendarInterval"] == {"Hour": 4, "Minute": 30}
    assert set(job) == {
        "Label",
        "ProgramArguments",
        "StartCalendarInterval",
        "EnvironmentVariables",
        "ProcessType",
        "LowPriorityIO",
        "Nice",
    }, "another key could add a second trigger (RunAtLoad, StartInterval) or a log file"


def test_runs_at_low_priority():
    assert plist()["ProcessType"] == "Background"
    assert plist()["LowPriorityIO"] is True
    assert plist()["Nice"] == 10


def test_path_holds_only_absolute_directories():
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
    misc = config()["misc"]
    assert set(misc.pop("disable")) == {
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
    }
    assert misc == {
        "assume_yes": True,
        "no_retry": True,
        "notify_end": "never",
        "no_self_update": True,
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
    data = config()
    assert set(data) == {"misc", "commands"}
    for key, value in data["misc"].items():
        assert "~" not in str(value), f"misc.{key} holds `~`, which topgrade does not expand there"


def test_ci_runs_this_file():
    lines = [line for line in CI.read_text().splitlines() if "tests/test_mac_topgrade.py" in line]
    assert lines, "ci.yml runs no step naming this file"
    assert any("pipx run --spec pytest" in line for line in lines), lines
