"""deploy-box starts fleet-host-config.service itself and reads its journal.

`systemctl start` on a Type=oneshot unit blocks until the unit ends and returns its
result (https://www.freedesktop.org/software/systemd/man/latest/systemctl.html), so
the job needs a polkit grant for that one start
(https://www.freedesktop.org/software/polkit/docs/latest/polkit.8.html) and, to print
the run's log, the systemd-journal group on the runners that take the job (journalctl(1)).
"""
import configparser
import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
RULES = ROOT / "rootfs/etc/polkit-1/rules.d/50-fleet-host-config.rules"
UNITS = ROOT / "rootfs/etc/systemd/system"


def test_polkit_grants_only_the_start_of_the_deploy_unit() -> None:
    text = RULES.read_text()
    units = re.search(r"var fleetStartableUnits = \[(.*?)\];", text, re.DOTALL)
    assert units and '"fleet-host-config.service"' in units.group(1)
    assert 'action.lookup("verb") == "start"' in text
    assert 'subject.user == "nish"' in text


def _service(path: Path) -> dict:
    cp = configparser.ConfigParser(strict=False, interpolation=None)
    cp.optionxform = str
    cp.read(path)
    return dict(cp["Service"])


def test_the_deploy_runner_runs_as_fleet_ci_and_reads_the_journal() -> None:
    """GitHub's runner hardening: the runner is its own low-privilege user, never the owner's uid.

    https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners
    """
    svc = _service(UNITS / "fleet-ci-runner.service")
    assert (svc["User"], svc["Group"]) == ("fleet-ci", "fleet-ci")
    assert svc["ProtectHome"] == "yes"
    assert svc["SupplementaryGroups"] == "systemd-journal"
    assert not list(UNITS.glob("actions.runner.*")), "a runner unit drop-in implies a runner on nish's uid"


def test_polkit_lets_fleet_ci_start_only_the_deploy_unit() -> None:
    rule = RULES.read_text().split('subject.user == "nish"', 1)[1]
    assert 'action.lookup("unit") == "fleet-host-config.service"' in rule
    assert 'subject.user == "fleet-ci"' in rule


DEPLOY_BOX = ROOT / ".github/workflows/deploy-box.yml"


def _run_lines(workflow: str) -> list[str]:
    steps = yaml.safe_load(workflow)["jobs"]["apply"]["steps"]
    return [line for s in steps for line in s.get("run", "").splitlines()]


def assert_waits_on_the_unit(workflow: str) -> None:
    lines = _run_lines(workflow)
    starts = [line for line in lines if "systemctl start fleet-host-config.service" in line]
    assert starts, "deploy-box must start fleet-host-config.service"
    assert not any("--no-block" in line for line in starts), "a --no-block start returns before the deploy ends"
    assert not any(word in line for line in lines for word in ("sleep", "until ", "while ")), "no hand-made wait loop"


def test_deploy_box_waits_on_the_unit_itself() -> None:
    """The job blocks on the start and owns no wait loop of its own (fleet-ops#10935 glue audit)."""
    assert_waits_on_the_unit(DEPLOY_BOX.read_text())
