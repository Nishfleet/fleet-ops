import re
from pathlib import Path

import pytest

ROUTER_DIR = Path(__file__).resolve().parent
SELF = Path(__file__).resolve()
ROUTER_TESTS = sorted(
    path for path in ROUTER_DIR.glob("test_router_*.py") if path.resolve() != SELF
)

_LOADS_LITELLM = re.compile(r"^\s*(?:import litellm|from litellm)", re.MULTILINE)


@pytest.mark.parametrize("path", ROUTER_TESTS, ids=lambda path: path.name)
def test_litellm_loading_router_test_skips_instead_of_erroring(path):
    source = path.read_text(encoding="utf-8")
    if not _LOADS_LITELLM.search(source):
        pytest.skip(f"{path.name} does not load litellm")
    assert 'pytest.importorskip("litellm")' in source, (
        f'{path.name} loads litellm at module scope but has no pytest.importorskip("litellm"); it errors at collection when litellm is absent'
    )
