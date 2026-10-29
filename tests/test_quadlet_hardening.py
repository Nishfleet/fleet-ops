"""Every quadlet has a restart policy, a memory cap, a digest-pinned image and no registry auto-update on that pin."""

import re
from pathlib import Path

import pytest

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


def image_tag(image: str) -> str | None:
    """The tag of an image reference, or None when it carries none. A digest is not a tag."""
    name = image.split("@", 1)[0].rsplit("/", 1)[-1]
    _, separator, tag = name.partition(":")
    return tag if separator else None


def is_pinned(image: str) -> bool:
    """A digest, or a tag other than latest, changes only when a PR changes it."""
    return bool(DIGEST.search(image)) or image_tag(image) not in {None, "latest"}


def carries_registry_autoupdate(autoupdate: list[str]) -> bool:
    return any("registry" in [part.strip() for part in value.split(",")] for value in autoupdate)


def autoupdate_violation(image: str, autoupdate: list[str]) -> str | None:
    registry = carries_registry_autoupdate(autoupdate)
    pinned = is_pinned(image)
    if pinned and registry:
        return (
            f"Image={image} is pinned (a tag other than latest, or a digest), so it must not carry "
            "AutoUpdate=registry: podman auto-update would move an image that changes only by PR"
        )
    if not pinned and not registry:
        return (
            f"Image={image} is a floating tag, so it needs AutoUpdate=registry: "
            "podman auto-update is the only thing that moves it"
        )
    return None


@pytest.mark.parametrize("path", quadlets(), ids=lambda path: path.name)
def test_autoupdate_matches_the_image_pin(path: Path) -> None:
    sections = parse(path)
    images = values(sections, "Container", "Image")
    assert len(images) == 1, f"{path.name}: expected one [Container] Image= line"
    violation = autoupdate_violation(images[0], values(sections, "Container", "AutoUpdate"))
    assert violation is None, f"{path.name}: {violation}"


DIGEST_SUFFIX = "@sha256:" + "0" * 64


@pytest.mark.parametrize(
    ("image", "autoupdate", "want"),
    [
        pytest.param("docker.io/library/postgres:16" + DIGEST_SUFFIX, ["registry"], "pinned", id="digest-and-registry"),
        pytest.param(
            "docker.io/library/postgres:16" + DIGEST_SUFFIX, ["local,registry"], "pinned", id="digest-and-registry-list"
        ),
        pytest.param("docker.io/library/postgres:16" + DIGEST_SUFFIX, [], None, id="digest-without-autoupdate"),
        pytest.param("ghcr.io/berriai/litellm:v1.105.0", ["registry"], "pinned", id="version-tag-and-registry"),
        pytest.param("ghcr.io/berriai/litellm:v1.105.0", [], None, id="version-tag-without-autoupdate"),
        pytest.param("docker.io/library/postgres:16", ["registry"], "pinned", id="tag-16-and-registry"),
        pytest.param(
            "ghcr.io/viren070/aiostreams:latest" + DIGEST_SUFFIX,
            ["registry"],
            "pinned",
            id="latest-digest-and-registry",
        ),
        pytest.param("ghcr.io/viren070/aiostreams:latest", [], "floating", id="latest-without-autoupdate"),
        pytest.param("ghcr.io/viren070/aiostreams:latest", ["local"], "floating", id="latest-with-local-only"),
        pytest.param("ghcr.io/viren070/aiostreams:latest", ["registry"], None, id="latest-with-registry"),
        pytest.param("ghcr.io/viren070/aiostreams", [], "floating", id="untagged-without-autoupdate"),
        pytest.param("ghcr.io/viren070/aiostreams", ["registry"], None, id="untagged-with-registry"),
        pytest.param(
            "registry.example.com:5000/fleet/proxy:latest",
            [],
            "floating",
            id="registry-port-floating-without-registry",
        ),
        pytest.param("registry.example.com:5000/fleet/proxy:16", [], None, id="registry-port-version-tag"),
    ],
)
def test_autoupdate_detector(image: str, autoupdate: list[str], want: str | None) -> None:
    violation = autoupdate_violation(image, autoupdate)
    if want is None:
        assert violation is None, violation
    else:
        assert violation is not None and want in violation, violation


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
