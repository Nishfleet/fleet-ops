"""podman-eval's /run/podman-eval comes from tmpfiles.d and is never removed (fleet-ops#9983).

The runners hide it with InaccessiblePaths=-/run/podman-eval, which skips a missing path, so
the parent dir must be made at boot and keep its inode. The unit's RuntimeDirectory= must be
the nested one, so only the inner dir is wiped on stop.
"""

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
UNIT = (ROOT / "rootfs/etc/systemd/system/podman-eval.service").read_text()
CONF = ROOT / "rootfs/etc/tmpfiles.d/podman-eval.conf"
DROPIN = ROOT / "rootfs/etc/systemd/system/actions.runner.Nishfleet.netcup-fleet-ci-3.service.d/30-eval.conf"


def _lines(text):
    return [line for line in text.splitlines() if line.strip() and not line.startswith("#")]


def test_tmpfiles_makes_the_parent_and_never_ages_it_out():
    (line,) = _lines(CONF.read_text())
    kind, path, mode, user, group, age = line.split()
    assert (kind, path, mode, user, group, age) == ("d", "/run/podman-eval", "0700", "nish", "nish", "-")


def test_unit_uses_the_nested_runtime_dir_inside_the_tmpfiles_dir():
    assert re.search(r"^RuntimeDirectory=podman-eval/rt$", UNIT, re.M)
    assert re.search(r"^After=.*\bsystemd-tmpfiles-setup\.service\b", UNIT, re.M)
    assert "Environment=XDG_RUNTIME_DIR=/run/podman-eval/rt\n" in UNIT
    assert "--runroot /run/podman-eval/rt/runroot" in UNIT
    assert "unix:///run/podman-eval/rt/podman.sock" in UNIT
    assert not re.search(r"^RuntimeDirectory=podman-eval$", UNIT, re.M)


def test_eval_runner_points_at_the_socket_the_unit_binds():
    assert "DOCKER_HOST=unix:///run/podman-eval/rt/podman.sock" in DROPIN.read_text()
