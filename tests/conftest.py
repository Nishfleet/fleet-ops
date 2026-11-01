"""Apply the router litellm pin check to every test_router_* module under pytest.

tests/router_litellm_pin.py holds the check and the reason (fleet-ops#10710).
The test modules call it above their litellm imports so a direct run is covered
too, and this fixture covers a new test_router_*.py that forgets the call.
"""

from __future__ import annotations

import pytest

from router_litellm_pin import require_pinned_litellm


@pytest.fixture(autouse=True, scope="module")
def _router_litellm_is_pinned(request):
    module_file = getattr(request.module, "__file__", None)
    if module_file is not None:
        require_pinned_litellm(module_file)
