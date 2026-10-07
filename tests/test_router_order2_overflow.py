"""fleet-ops#9365: a cache-false worker row at order 2 still receives traffic
when every order-1 row in its group is in cooldown.

Runs against the pinned LiteLLM v1.98.0 Router with the proxy's production
router settings (cooldown_time 60, allowed_fails 1, num_retries 0,
simple-shuffle). Two failure modes could remove an order-1 row from the
shuffle:

- cooldown: the row is filtered out by _filter_cooldown_deployments
  (litellm/router.py, async_get_healthy_deployments) before
  _get_order_filtered_deployments (litellm/utils.py) picks the lowest order
  that still has healthy rows - so once both order-1 rows cool, the order-2
  row is the pick.
- max_parallel_requests: NOT a routing filter on v1.98.0 - it is a
  per-deployment semaphore (litellm/router.py), so an order-1 row at its cap
  queues the call instead of deflecting it. Cooldown is therefore the only
  routing-level overflow trigger, and the one this test exercises.
"""
import asyncio

import litellm
from litellm import Router
from litellm.router_utils.cooldown_handlers import _set_cooldown_deployments


def _row(mid, order, cache):
    return {
        "model_name": "worker-capable",
        "litellm_params": {
            "model": f"openai/{mid}",
            "api_base": "http://127.0.0.1:1",
            "api_key": "k",
            "order": order,
        },
        "model_info": {
            "id": mid,
            # carried so the fixture matches the production shape: a worker-group
            # row whose verdict is false sits at order 2 (fleet-ops#9365).
            "supports_prompt_caching": cache,
            "cache_proof": f"probe recorded for {mid} (fleet-ops#9365)",
        },
    }


def _router():
    return Router(
        model_list=[
            _row("cache-true-a", 1, True),
            _row("cache-true-b", 1, True),
            _row("cache-false-overflow", 2, False),
        ],
        cooldown_time=60,
        allowed_fails=1,
        num_retries=0,
        routing_strategy="simple-shuffle",
    )


def _cool(router, deployment_id):
    """Raise one 429 against a row through LiteLLM's own cooldown handler.

    _set_cooldown_deployments applies the router's allowed_fails threshold, so one
    call does not necessarily park the row; see the caller's double call.
    """
    exc = litellm.RateLimitError(message="429 rate limited", model="worker-capable", llm_provider="openai")
    return _set_cooldown_deployments(
        litellm_router_instance=router,
        original_exception=exc,
        exception_status=429,
        deployment=deployment_id,
        time_to_cooldown=60,
    )


async def _pick(router):
    d = await router.async_get_available_deployment(model="worker-capable", request_kwargs={})
    return d["model_info"]["id"], d["litellm_params"]["order"]


def test_order1_rows_win_while_healthy():
    router = _router()
    dep_id, order = asyncio.run(_pick(router))
    assert order == 1 and dep_id.startswith("cache-true-"), (dep_id, order)


async def _cool_then_pick():
    router = _router()
    dep_id, order = await _pick(router)
    assert order == 1
    for mid in ("cache-true-a", "cache-true-b"):
        _cool(router, mid)
        _cool(router, mid)  # allowed_fails=1: the first 429 only counts, the second cools
    return await _pick(router)


def test_order2_row_serves_after_order1_cooldowns():
    dep_id, order = asyncio.run(_cool_then_pick())
    assert (dep_id, order) == ("cache-false-overflow", 2), (dep_id, order)


if __name__ == "__main__":
    test_order1_rows_win_while_healthy()
    print("PASS order-1 rows win while healthy")
    test_order2_row_serves_after_order1_cooldowns()
    print("PASS order-2 row serves after order-1 cooldowns")
