"""Hard block: the retired Cursor and Devin CLI lanes cannot come back.

The lanes were retired on Nish's order of 2026-10-28 (nish-vault#44 item 9): every
worker runs through pi, and each paid plan serves a model through the LiteLLM
router, not a standalone CLI harness. Every path that made a lane live is
guarded here.
"""

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
LANE_NAME = re.compile(r"(?i)\b(cursor|devin)\b")
LISTENER_UNIT = re.compile(r"(?i)tincan-listen-(cursor|devin)")
GONE_UNITS = ("tincan-listen-cursor-vps.service", "tincan-listen-devin-vps.service",
              "tincan-listen-command-code.service", "tincan-listen-opencode.service")


def test_no_retired_lane_in_agent_workflows():
    hits = []
    for name in ("agent.yml", "agent-dispatch.yml"):
        hits += LANE_NAME.findall((ROOT / ".github/workflows" / name).read_text())
    assert not hits, f"retired CLI lane names are back in the workflows: {sorted(set(hits))}"


def test_retired_listener_units_stay_gone():
    for name in GONE_UNITS:
        assert not (ROOT / "systemd" / name).exists(), (
            f"{name} is back — a retired CLI listener cannot be relinked"
        )


def test_fleet_sync_lists_no_retired_listener():
    sync = (ROOT / "systemd/fleet-sync.service").read_text()
    hits = LISTENER_UNIT.findall(sync)
    assert not hits, f"fleet-sync.service relinks a retired listener: {hits}"


def test_no_retired_seat_file_or_router_row():
    quadlet = (ROOT / "containers/quadlet/fleet-litellm-proxy.container").read_text()
    SEATS_REL = ".config/fleet-ops/seats"  # gitleaks:allow
    seats = re.findall("EnvironmentFile=-%h/" + SEATS_REL + r"/([\\w-]+)\\.env", quadlet, re.M)
    assert not [s for s in seats if LANE_NAME.search(s)], f"retired lane seat files are listed: {seats}"
    live = [
        line
        for line in (ROOT / "config/litellm-proxy.yaml").read_text().splitlines()
        if not line.lstrip().startswith("#")
    ]
    hits = LANE_NAME.findall("\n".join(live))
    assert not hits, f"retired CLI lane names are back in live router lines: {sorted(set(hits))}"
