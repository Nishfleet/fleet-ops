"""Every quadlet but the two excluded ones has a restart policy, a memory cap and a digest-pinned image."""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {"fleet-litellm-proxy.container", "fleet-grafana.container"}
DIGEST = re.compile(r"@sha256:[0-9a-f]{64}$")
# Podman 4.9.3 has no Memory= key for quadlets, so the cap is the unit's MemoryMax=; the
# [Container] spellings are accepted for a later podman.
CAP_KEYS = {"Service": {"MemoryMax"}, "Container": {"Memory"}}


def quadlets() -> list[Path]:
    return [path for path in sorted(ROOT.glob("containers/quadlet/*.container")) if path.name not in EXCLUDED]


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
    assert quadlets(), "no containers/quadlet/*.container files found besides the excluded ones"


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
    explicit_podman = [v for v in values(sections, "Container", "PodmanArgs") if v.startswith(("--memory=", "--memory "))]
    assert caps or explicit_podman, f"{path.name}: needs [Service] MemoryMax= (or [Container] Memory=)"


@pytest.mark.parametrize("path", quadlets(), ids=lambda path: path.name)
def test_image_is_pinned_by_digest(path: Path) -> None:
    images = values(parse(path), "Container", "Image")
    assert len(images) == 1, f"{path.name}: expected one [Container] Image= line"
    assert DIGEST.search(images[0]), f"{path.name}: Image={images[0]} must end in @sha256:<64 hex>"
