import re
from pathlib import Path

import pytest

SELF = Path(__file__).resolve()
ROUTER_DIR = SELF.parent
ROUTER_TESTS = sorted(
    path for path in ROUTER_DIR.rglob("test_router_*.py") if path.resolve() != SELF
)

_LOADS_LITELLM = re.compile(r"^\s*(?:import litellm|from litellm)", re.MULTILINE)


@pytest.mark.parametrize(
    "path", ROUTER_TESTS, ids=lambda path: str(path.relative_to(ROUTER_DIR))
)
def test_litellm_loading_router_test_skips_instead_of_erroring(path):
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        pytest.skip(f"{path.relative_to(ROUTER_DIR)} is not readable UTF-8")
    name = path.relative_to(ROUTER_DIR)
    if not _LOADS_LITELLM.search(source):
        pytest.skip(f"{name} does not load litellm")
    assert 'pytest.importorskip("litellm")' in source, (
        f"{name} loads litellm at module scope but has no "
        'pytest.importorskip("litellm"); it errors at collection when litellm is absent'
    )
