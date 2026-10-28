"""The litellm release every router test must run on, read from the proxy image.

The host venv and the image drift. On 2026-10-28 the venv held litellm 1.98.0
while containers/quadlet/fleet-litellm-proxy.container pinned v1.105.0, so a
router test that imported the venv's litellm measured a release the proxy never
serves (fleet-ops#10710). 1.98.0 holds no slot for a stream and cannot show the
v1.105.0 stream-slot leak (fleet-ops#10694), so the two versions do not answer
the same questions.

Every test_router_*.py that loads litellm calls require_pinned_litellm(__file__)
after its litellm imports, so a pytest run and a direct run of the file both
fail when the installed version differs. test_router_consumer_groups.py reads
the config with yq and loads no litellm, so ROUTER_TESTS_WITHOUT_LITELLM exempts
it. Run the rest on the pin:

    uvx --with litellm==1.105.0 --with pytest==8.3.5 --with jsonschema --with httpx \\
        python -m pytest -q -p no:cacheprovider tests/test_router_*.py
"""

from __future__ import annotations

import importlib.metadata
import importlib.util
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROXY_CONTAINER = ROOT / "containers/quadlet/fleet-litellm-proxy.container"

ROUTER_TESTS_WITHOUT_LITELLM = frozenset({"test_router_consumer_groups"})


def pinned_litellm() -> str:
    """The litellm version in the proxy image's Image= line."""
    match = re.search(
        r"^Image=ghcr\.io/berriai/litellm:v(\d+(?:\.\d+)*)@sha256:",
        PROXY_CONTAINER.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    assert match, f"no litellm version pinned in {PROXY_CONTAINER}"
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
    assert running == pinned, (
        f"{name} runs against the proxy image's litellm {pinned}, not {running}. "
        f"Run: uvx --with litellm=={pinned} --with pytest==8.3.5 --with jsonschema "
        f"--with httpx python -m pytest -q -p no:cacheprovider tests/test_router_*.py"
    )
