"""The litellm release every router test must run on, read from the proxy image.

containers/quadlet/fleet-litellm-proxy@.container's Image= tag is the one place
the version is written, because a Renovate bump edits that line and nothing
else. This helper reads it, so the tests and the CI install step use the release
the proxy serves and a tag bump never goes stale against the code: no litellm
version is written here or in the four tests it backs, only in the image tag.

The drift this replaces: on 2026-10-28 the venv held litellm 1.98.0 while the
image pinned a newer release, so a router test that imported the venv's litellm
measured a release the proxy never serves (fleet-ops#10710). That venv cannot
show the stream-slot leak the newer release can (fleet-ops#10694), so the two
do not answer the same questions.

Every test_router_*.py that loads litellm calls require_pinned_litellm(__file__)
above its litellm imports, so a version-drift import error does not pre-empt the
pin message, and both a pytest run and a direct run of the file fail when the
installed version differs. tests/conftest.py calls the same check for every
router module, so a new test_router_*.py is covered even if it forgets the call.
test_router_consumer_groups.py reads the config with yq and loads no litellm, so
ROUTER_TESTS_WITHOUT_LITELLM exempts it. The CI install step gets the same
version straight from here (pip install ... "litellm==$(python
tests/router_litellm_pin.py)"). Run the rest on the pin the image tag holds:

    uvx --with "litellm==$(python tests/router_litellm_pin.py)" --with pytest==8.3.5 \\
        --with jsonschema --with httpx python -m pytest -q -p no:cacheprovider \\
        tests/test_router_*.py
"""

from __future__ import annotations

import importlib.metadata
import importlib.util
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROXY_CONTAINER = ROOT / "containers/quadlet/fleet-litellm-proxy@.container"

ROUTER_TESTS_WITHOUT_LITELLM = frozenset({"test_router_consumer_groups"})


def pinned_litellm() -> str:
    """The litellm version in the proxy image's Image= line."""
    match = re.search(
        r"^Image=ghcr\.io/berriai/litellm:v(\d+(?:\.\d+)*)@sha256:",
        PROXY_CONTAINER.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if not match:
        raise RuntimeError(
            "no 'Image=ghcr.io/berriai/litellm:v<version>@sha256:<digest>' line in "
            f"{PROXY_CONTAINER}"
        )
    return match.group(1)


def require_pinned_litellm(module_file: str) -> None:
    """Fail a router test module whose litellm is not the image's."""
    name = Path(module_file).stem
    if not name.startswith("test_router_") or name in ROUTER_TESTS_WITHOUT_LITELLM:
        return
    if importlib.util.find_spec("litellm") is None:
        return
    running = importlib.metadata.version("litellm")
    pinned = pinned_litellm()
    if running != pinned:
        raise RuntimeError(
            f"{name} runs against the proxy image's litellm {pinned}, not {running}. "
            f"Run: uvx --with litellm=={pinned} --with pytest==8.3.5 --with jsonschema "
            f"--with httpx python -m pytest -q -p no:cacheprovider tests/test_router_*.py"
        )


if __name__ == "__main__":
    # The CI install step reads the version from this one helper, never from a
    # version written in the workflow.
    print(pinned_litellm())
