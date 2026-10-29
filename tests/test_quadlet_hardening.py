"""Every quadlet has a restart policy, a memory cap and a digest-pinned image,
and the daily update moves an image only when a quadlet asks for it.
"""

import json
import re
from collections.abc import Iterator
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
DIGEST = re.compile(r"@sha256:[0-9a-f]{64}$")
# Podman 4.9.3 quadlets have no Memory= key and reject an unknown [Container] key
# (https://docs.podman.io/en/v4.9.3/markdown/podman-systemd.unit.5.html; Memory= exists only in
# later podman), so the cap is the unit's [Service] MemoryMax= or --memory= in [Container] PodmanArgs=.
CAP_KEYS = {"Service": {"MemoryMax"}}


def quadlets() -> list[Path]:
    return sorted(ROOT.glob("containers/quadlet/*.container"))


def parse(path: Path) -> dict[str, list[tuple[str, str]]]:
    """Section name to its (key, value) lines. Quadlets repeat keys, so no configparser."""
    sections: dict[str, list[tuple[str, str]]] = {}
    current = None
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            sections.setdefault(current, [])
        elif current is not None and "=" in line:
            key, _, value = line.partition("=")
            sections[current].append((key.strip(), value.strip()))
    return sections


def values(sections: dict[str, list[tuple[str, str]]], section: str, key: str) -> list[str]:
    return [value for k, value in sections.get(section, []) if k == key]


def test_quadlets_are_found() -> None:
    assert quadlets(), "no containers/quadlet/*.container files found"


@pytest.mark.parametrize("path", quadlets(), ids=lambda path: path.name)
def test_has_restart_policy(path: Path) -> None:
    restart = values(parse(path), "Service", "Restart")
    assert restart and restart[-1] in {"on-failure", "always"}, f"{path.name}: [Service] needs Restart=on-failure or always"


@pytest.mark.parametrize("path", quadlets(), ids=lambda path: path.name)
def test_has_memory_cap(path: Path) -> None:
    sections = parse(path)
    caps = [
        value
        for section, keys in CAP_KEYS.items()
        for key in keys
        for value in values(sections, section, key)
        if value.lower() not in {"", "infinity", "0"}
    ]
    explicit_podman = [v for v in values(sections, "Container", "PodmanArgs") if re.search(r"--memory[= ]", v)]
    assert caps or explicit_podman, f"{path.name}: needs [Service] MemoryMax= (or [Container] PodmanArgs=--memory=)"


@pytest.mark.parametrize("path", quadlets(), ids=lambda path: path.name)
def test_image_is_pinned_by_digest(path: Path) -> None:
    images = values(parse(path), "Container", "Image")
    assert len(images) == 1, f"{path.name}: expected one [Container] Image= line"
    assert DIGEST.search(images[0]), f"{path.name}: Image={images[0]} must end in @sha256:<64 hex>"


SIZE = re.compile(r"(\d+)\s*([KMGTPE]?)", re.IGNORECASE)


def size_bytes(value: str) -> int:
    """A systemd size (5G, 5120m, 512) in bytes, so equal caps in different units compare equal."""
    match = SIZE.fullmatch(value.strip())
    assert match, f"not a systemd size: {value}"
    return int(match[1]) * 1024 ** " KMGTPE".index(match[2].upper())


def test_proxy_cap_equals_its_slice() -> None:
    unit = values(parse(ROOT / "containers/quadlet/fleet-litellm-proxy.container"), "Service", "MemoryMax")
    slice_cap = values(parse(ROOT / "systemd/app-litellm.slice"), "Slice", "MemoryMax")
    assert unit and slice_cap and size_bytes(unit[0]) == size_bytes(slice_cap[0]), (
        f"fleet-litellm-proxy [Service] MemoryMax={unit} must equal app-litellm.slice [Slice] MemoryMax={slice_cap}, "
        "because the unit cap is only made visible, not made tighter"
    )


def _walk_tasks(task_list: list[dict]) -> Iterator[dict]:
    for task in task_list:
        yield task
        for key in ("block", "rescue", "always"):
            yield from _walk_tasks(task.get(key) or [])


def _command_text(task: dict) -> str:
    return " ".join(
        json.dumps(task[key]) for key in ("ansible.builtin.command", "ansible.builtin.shell", "command", "shell") if key in task
    )


def test_the_update_run_moves_an_image_exactly_when_a_quadlet_asks_for_it() -> None:
    labelled = [
        path.name
        for path in quadlets()
        if any(value.strip() for value in values(parse(path), "Container", "AutoUpdate"))
    ]
    play = yaml.safe_load((ROOT / "ansible/update.yml").read_text())
    steps = [
        task
        for run in play
        for key in ("pre_tasks", "tasks", "post_tasks", "handlers")
        for task in _walk_tasks(run.get(key) or [])
    ]
    assert not [
        task
        for task in steps
        if set(task) & {"include_tasks", "import_tasks", "include_role", "import_role", "roles"}
    ], (
        "ansible/update.yml pulls tasks from another file, so this walk cannot see every step: "
        "keep the update steps in this file, or teach the test to follow the include"
    )
    moves = [
        task.get("name", "unnamed")
        for task in steps
        if "auto-update" in (command := _command_text(task)) and "--dry-run" not in command
    ]
    assert labelled == moves, (
        f"quadlets with any AutoUpdate value: {labelled or 'none'}, "
        f"tasks in ansible/update.yml that run podman auto-update: {moves or 'none'}, "
        "because podman reads that label from the container and a run with no labelled quadlet "
        "moves nothing (fleet-ops#9257)"
    )
