import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
QUADLET = (ROOT / "containers/quadlet/fleet-litellm-proxy.container").read_text()
CONFIG = (ROOT / "config/litellm-proxy.yaml").read_text()


def test_no_seat_glob():
    assert not re.search(r"^EnvironmentFile=.*seats/\*", QUADLET, re.M)


def test_seat_files_listed_once():
    listed = re.findall(r"^EnvironmentFile=-%h/\.config/fleet-ops/seats/([\w-]+)\.env$", QUADLET, re.M)
    assert listed and len(listed) == len(set(listed))
    for unused in ("claude-seat-a", "cursor", "devin", "hetzner", "nebius", "openrouter", "xkiro", "zenmux"):
        assert unused not in listed


def test_every_config_var_is_passed_to_the_container():
    passed = set(re.findall(r"^PodmanArgs=--env=([A-Z0-9_]+)$", QUADLET, re.M))
    used = set(re.findall(r"os\.environ/([A-Z0-9_]+)", CONFIG))
    assert used <= passed, sorted(used - passed)
