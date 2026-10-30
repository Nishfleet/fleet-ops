"""One fleet-pr-sweep timer instance per enrolled repo, from the step 2a enable line.

A repo enrolled without its `fleet-pr-sweep@<name>.timer` runs the stuck-PR
sweep only on GitHub's own `agent-dispatch` `schedule` cron (17 */6 * * *),
which fired 4 to 5 times a day in the measured repos, so a PR waiting over an
hour waited up to a quarter of a day (fleet-ops#10760: seo-fix-kit was
enrolled 2026-10-28 and its instance was missing). A timer for a repo that no
longer exists in the config is the same class of drift in the other direction
(tether: enrolled, lost a timer case, then deleted in fleet-ops#11087).
"""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).parent.parent
CFG = json.loads((ROOT / "config" / "intake-repos.json").read_text())
EXPECTED = {r["name"] for r in CFG["repos"]} | {r["name"] for r in CFG["sweep_only"]}
ENABLE_LINE = re.compile(
    r"^ExecStart=/usr/bin/systemctl --user enable --now"
    r"(.*\bfleet-pr-sweep@[^ ]+\.timer\b.*)$"
)
TIMER = re.compile(r"\bfleet-pr-sweep@([^ ]+)\.timer\b")


def live_timer_names() -> set[str]:
    """Every fleet-pr-sweep timer the step 2a enable line switches on."""
    text = (ROOT / "systemd" / "fleet-sync.service").read_text()
    lines = [line for line in text.splitlines() if ENABLE_LINE.match(line)]
    assert len(lines) == 1, (
        f"expected exactly one fleet-pr-sweep enable line in systemd/fleet-sync.service, got {len(lines)}"
    )
    return set(TIMER.findall(lines[0]))


def test_every_enrolled_and_sweep_only_repo_has_a_timer_instance():
    missing = EXPECTED - live_timer_names()
    assert not missing, f"enrolled without a fleet-pr-sweep timer: {sorted(missing)}"


def test_no_timer_instance_for_a_repo_out_of_the_config():
    extra = live_timer_names() - EXPECTED
    assert not extra, f"timer for a repo not in intake-repos.json: {sorted(extra)}"


def test_the_template_pair_the_enable_line_needs_exists():
    for unit in ("systemd/fleet-pr-sweep@.service", "systemd/fleet-pr-sweep@.timer"):
        assert (ROOT / unit).is_file(), unit
