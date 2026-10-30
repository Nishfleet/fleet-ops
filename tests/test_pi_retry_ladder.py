"""Pi's agent retry ladder must outlast the cooldown the router names in its 429.

On a hand-off whose seat group is cooling, the router answers
`429: {"message":"No deployments available for selected model, Try again in 900
seconds"}` and pi 1.4.0 burns its own retry ladder against that wait. The ladder
is pure exponential backoff — `min(baseDelayMs * 2**attempt, maxAgentDelayMs)`
per wait, from pi's `retry` settings block (pi docs/settings.md) — with no
parsing of the server-named delay, so the only way to wait out the 900-second
window (`cooldown_time: 900` on the worker rows in `config/litellm-proxy.yaml`,
fleet-ops#11151) is a ladder whose cumulative wait crosses 900 seconds before
the retries run out.

The shipped block was `{"maxRetries": 6, "baseDelayMs": 10000}`: waits
10+20+40+60+60+60 s (the 60000 ms default cap binds from attempt 4), last call
at 250 s, exit 1 while 650 s of the window remained — the 2026-10-30 hand-off
deaths, e.g. run 41007456096. The recorded run on a mock that 429s naming 900
seconds and then releases: old block died at 250 s (exit 1), the shipped block
`{"maxRetries": 7, "baseDelayMs": 10000, "maxAgentDelayMs": 900000}` made its
8th call at 1271.7 s, got 200, and exited 0.

The file is live-only (pi rewrites it; docs/install.md), so this test reads the
installed file and holds the box to the invariant, in both directions: the
ladder must reach a call after the shortest worker cooldown (waiting it out),
and its give-up tail — last call plus last wait, the worst case a session sits
in a 429 before dying — must stay under the tightest wall a pi lane on this box
runs under, the 40-minute inish-daily timeout (the worker step has 55 minutes,
the hand-off job 75). Longer windows the router can name — the 1800 s desk rows
and the 21600 s budget-exhausted rows in the same config — name a wait no
in-session ladder can cover; they are out of scope here (fleet-ops#11151 pins
the 900-second case).
"""
import json
import pathlib
import re

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SETTINGS = pathlib.Path.home() / ".pi/agent/settings.json"
ROUTER_CONFIG = ROOT / "config/litellm-proxy.yaml"
NAMED_WINDOW_MS = 900_000
TIGHTEST_PI_WALL_MS = 40 * 60 * 1000

requires_settings = pytest.mark.skipif(
    not SETTINGS.exists(), reason="no ~/.pi/agent/settings.json on this box"
)


def worker_cooldown_ms() -> int:
    text = ROUTER_CONFIG.read_text()
    blocks = re.findall(r"- model_name: (\S+)\n(.*?)(?=- model_name:|\Z)", text, re.S)
    cooldowns = [
        int(re.search(r"cooldown_time: (\d+)", body).group(1))
        for name, body in blocks
        if name == "worker-capable" and "cooldown_time:" in body
    ]
    assert cooldowns, "no worker-capable cooldown_time in config/litellm-proxy.yaml"
    return min(cooldowns) * 1000


def ladder_waits_ms(retry: dict) -> list[int]:
    enabled = retry.get("enabled", True)
    base = retry.get("baseDelayMs", 2000)
    retries = retry.get("maxRetries", 3)
    cap = retry.get("maxAgentDelayMs", 60000)
    return [min(base * 2**i, cap) for i in range(retries)] if enabled else []


@requires_settings
def test_retry_is_enabled():
    retry = json.loads(SETTINGS.read_text()).get("retry", {})
    assert retry.get("enabled", True) is True


@requires_settings
def test_ladder_makes_a_call_after_the_named_window():
    waits = ladder_waits_ms(json.loads(SETTINGS.read_text()).get("retry", {}))
    cooldown = worker_cooldown_ms()
    assert sum(waits) > cooldown, (
        f"ladder's last call lands at {sum(waits) / 1000:g}s, inside the "
        f"{cooldown / 1000:g}s window the router names: the session dies on a "
        f"recoverable 429 (fleet-ops#11151)"
    )


@requires_settings
def test_give_up_tail_stays_under_the_tightest_pi_wall():
    waits = ladder_waits_ms(json.loads(SETTINGS.read_text()).get("retry", {}))
    tail = sum(waits) + waits[-1] if waits else 0
    assert tail < TIGHTEST_PI_WALL_MS, (
        f"worst-case stall {tail / 1000:g}s reaches past the 40-minute inish wall"
    )
