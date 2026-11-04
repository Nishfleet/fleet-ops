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


def test_only_the_deploy_runners_read_the_system_journal() -> None:
    for n in (1, 2):
        conf = UNITS / f"actions.runner.Nishfleet.netcup-fleet-ci-{n}.service.d/40-no-bus.conf"
        assert _service(conf).get("SupplementaryGroups") == "systemd-journal", conf
    eval_pool = UNITS / "actions.runner.Nishfleet.netcup-fleet-ci-3.service.d"
    shared = UNITS / "actions.runner.Nishfleet.netcup-fleet-ci-.service.d"
    for conf in [*eval_pool.glob("*.conf"), *shared.glob("*.conf")]:
        assert "SupplementaryGroups" not in conf.read_text(), conf
