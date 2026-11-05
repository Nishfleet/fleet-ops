"""Agent sandboxes hide the home directory by default and bind back what they need.

A hand-kept InaccessiblePaths= list under /home fails open: a credential file
written after the list was made stays readable until someone adds a line. With
ProtectHome=tmpfs or TemporaryFileSystem= over /home plus BindPaths= and
BindReadOnlyPaths=, a path that is not bound back does not exist in the unit
(https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html,
ProtectHome=, TemporaryFileSystem=, BindReadOnlyPaths=). fleet-ops#10935.
"""

from pathlib import Path

import pytest

SYSTEM = Path(__file__).resolve().parents[1] / "rootfs/etc/systemd/system"
UNITS = ["dockerd-eval.service", "hermes-.service.d/sandbox.conf"]


def values(path: Path, key: str) -> list[str]:
    return [line.split("=", 1)[1] for line in path.read_text().splitlines() if line.startswith(key + "=")]


@pytest.mark.parametrize("name", UNITS)
def test_home_is_empty_and_lists_no_hidden_path_under_it(name: str) -> None:
    unit = SYSTEM / name
    empty_home = values(unit, "ProtectHome") == ["tmpfs"] or any(
        v.startswith("/home/nish:") for v in values(unit, "TemporaryFileSystem")
    )
    assert empty_home, f"{name}: hide /home with ProtectHome=tmpfs and bind back what the unit needs"
    listed = [w for v in values(unit, "InaccessiblePaths") for w in v.split() if w.lstrip("-").startswith("/home/")]
    assert not listed, f"{name}: drop these lines, the empty home already hides them: {listed}"
