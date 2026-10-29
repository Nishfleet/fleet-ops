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


def test_the_container_is_passed_no_var_the_router_config_does_not_read():
    passed = set(re.findall(r"^PodmanArgs=--env=([A-Z0-9_]+)$", QUADLET, re.M))
    used = set(re.findall(r"os\.environ/([A-Z0-9_]+)", CONFIG))
    assert passed <= used, (
        f"the container is passed {sorted(passed - used)} but no row in config/litellm-proxy.yaml reads it, "
        "so the key of a provider with no router row still reaches the router"
    )


SEAT_FILE = {
    "ALIBABA_CODING_API_KEY": "alibaba-coding",
    "ANTHROPIC_API_KEY": "anthropic-api",
    "COMMANDCODE_API_KEY": "commandcode",
    "MINIMAX_API_KEY": "minimax",
    "OPENCODE_API_KEY": "opencode",
    "STEPFUN_API_KEY": "stepfun",
    "SYNTHETIC_API_KEY": "synthetic",
    "VERCEL_AI_GATEWAY_JEV_KEY": "typesafe-jev",
    "ZAI_API_KEY": "zai",
}
OTHER_ENV_FILES = {"DATABASE_URL", "LITELLM_MASTER_KEY", "REDIS_PASSWORD", "STRAITLY_API_KEY"}


def test_every_seat_var_in_the_config_has_its_file_listed():
    listed = set(re.findall(r"^EnvironmentFile=-%h/\.config/fleet-ops/seats/([\w-]+)\.env$", QUADLET, re.M))
    used = set(re.findall(r"os\.environ/([A-Z0-9_]+)", CONFIG)) - OTHER_ENV_FILES
    assert used <= set(SEAT_FILE), sorted(used - set(SEAT_FILE))
    assert {SEAT_FILE[var] for var in used} == listed, sorted(listed - {SEAT_FILE[var] for var in used})
