"""The Mac's daily topgrade job runs from mac/, one run a day, unchanged, with no home path."""
import plistlib
import tomllib
from collections.abc import Iterator
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLIST = ROOT / "mac/com.nish.topgrade.plist"
CONFIG = ROOT / "mac/topgrade.toml"

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


def test_plist_has_no_home_path():
    offenders = [
        value for value in strings(plist())
        if "~" in value or any(home in value for home in HOME_PREFIXES)
    ]
    assert offenders == [], (
        f"{offenders} in {PLIST.name}: launchd does not expand `~`, and a home path "
        "pins the job to one account's home directory"
    )


def test_config_has_no_absolute_home_path():
    text = CONFIG.read_text()
    for home in HOME_PREFIXES:
        assert home not in text, f"{home} in {CONFIG.name}"


def test_config_expands_tilde_only_where_topgrade_expands_it():
    data = config()
    assert set(data) == {"misc", "commands"}
    for key, value in data["misc"].items():
        assert "~" not in str(value), f"misc.{key} holds `~`, which topgrade does not expand there"
