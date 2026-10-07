"""fleet-ops#9375: the router's own retries must not keep re-sending a mid-session prompt
on a different seat.

Mechanism, on the pinned litellm (v1.98.0 in `containers/quadlet/fleet-litellm-proxy.container`
from `PIP_INDEX=https://pypi.org/simple litellm==1.98.0`):

* `optional_pre_call_checks: [session_affinity]` pins a session id to the first row the router
  picks (`router_utils/pre_call_checks/deployment_affinity_check.py`, `_claim_pin`, first
  writer wins). The proxy sends that id on every call
  (`x-litellm-session-id=$FLEET_TASK_ID`, `config/pi-models.json`).
* A 429, or any 5XX, puts that row in cooldown (`cooldown_handlers._is_cooldown_required`
  returns True for 429 and for every status it does not name, which is the 5XX branch) after
  `allowed_fails: 1` failures for `cooldown_time: 60` seconds.
* The affinity filter then logs "pinned deployment=... not found in healthy_deployments" and
  returns every row of the group, so a router-level retry re-shuffles and re-sends the whole
  prompt on another seat. `_time_to_sleep_before_retry` returns 0 while any healthy row is
  left, so that retry is immediate and has no backoff.
* The pin does not move (`_claim_pin` only writes on a first writer), so the session returns to
  the pinned row as soon as its 60 s cool-down lapses.

`router_settings.retry_policy` therefore sets how many times ONE failed call re-sends the whole
prompt on another seat. The values this file checks are the working lever behind
fleet-ops#9375: `AuthenticationErrorRetries: 0` (a 401 cannot become a 200 on a retry, so
every attempt was a full prompt sent for nothing) and one retry each for the transient classes,
so a mid-session failure hands off to Pi's own retry instead (`~/.pi/agent/settings.json`,
`retry.maxRetries: 6`, `retry.baseDelayMs: 10000`), which keeps the session id and so keeps the
session on the seat the previous call warmed.

Run the config gate with any python3 (needs pyyaml). The drill part needs the pinned litellm
and is the evidence run:

    /home/nish/.local/venvs/litellm/bin/python tests/test_retry_policy_no_cross_seat.py

The drill drives a real Router over a local stand-in provider, so the cooldown, the affinity
filter, the shuffle and the retry loop are LiteLLM's own code, not a mock of it. It is a
manual drill in the style of `tests/test_router_order2_overflow.py`: nothing in CI runs it
yet, no new runner is added (`.semgrep/no-glue.yml` bans new scripts and script dirs).

One honesty note this drill pins down: on v1.98.0
`router_utils/get_retry_from_policy.py` matches only AuthenticationError, Timeout,
RateLimitError, ContentPolicyViolationError and BadRequestError. A 5XX takes the
`InternalServerError` branch, the function returns None, and `num_retries: 0` applies - so
`InternalServerErrorRetries` in this file's config is inert on this version (the drill asserts
1 attempt for it) and only carries intent for a future pin-up.
"""

from __future__ import annotations

import asyncio
import json
import http.server
import socketserver
import subprocess
import sys
import threading
from http.client import HTTPConnection
from pathlib import Path
from typing import Any

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG = REPO_ROOT / "config" / "litellm-proxy.yaml"

# The model group both drill rows share, and the seat the session is pinned to.
GROUP = "worker-capable"
PINNED_ROW = "pinned-row"
PEER_ROW = "spare-row"

# One call in the same session, per error class, when both rows are failing. These are the
# prompt re-sends one failed call costs the caller and the providers.
BOTH_ROWS_FAIL = {
    401: "AuthenticationErrorRetries",
    429: "RateLimitErrorRetries",
    500: "InternalServerErrorRetries",
}

# `InternalServerErrorRetries` is inert on litellm v1.98.0 (see the module docstring), so the
# 5XX row costs one attempt no matter what the config says, and the gate on that key is the
# config value itself, not the attempt count.
ATTEMPTS_EXPECTED = {401: 1, 429: 2, 500: 1}


def read_retry_policy(config: Path = CONFIG) -> dict[str, int]:
    """The `router_settings.retry_policy` map this proxy actually boots with."""
    proxy = yaml.safe_load(config.read_text())
    router_settings = proxy.get("router_settings") or {}
    return dict(router_settings.get("retry_policy") or {})


def test_config_gate() -> None:
    """The retry_policy this file documents must be what the yaml still says (fleet-ops#9375).

    A wider value here re-opens the cheap cross-seat retries without anyone choosing to, so
    the values are pinned rather than trusted.
    """
    retry_policy = read_retry_policy()
    assert retry_policy.get("AuthenticationErrorRetries") == 0, (
        "a 401 cannot become a 200 on a retry; every attempt re-sends the whole prompt "
        f"(got {retry_policy.get('AuthenticationErrorRetries')})"
    )
    for key in ("RateLimitErrorRetries", "InternalServerErrorRetries"):
        assert retry_policy.get(key) == 1, (
            f"{key}=2 gives one failed call two cross-seat prompt re-sends "
            f"(got {retry_policy.get(key)})"
        )
    assert retry_policy.get("TimeoutErrorRetries") == 1, (
        f"a timeout gets one same-group retry (got {retry_policy.get('TimeoutErrorRetries')})"
    )
    assert retry_policy.get("BadRequestErrorRetries") == 1, (
        f"unchanged: a bad request gets one try (got {retry_policy.get('BadRequestErrorRetries')})"
    )
    assert retry_policy.get("ContentPolicyViolationErrorRetries") == 0, (
        f"unchanged: a policy block never succeeds on a retry "
        f"(got {retry_policy.get('ContentPolicyViolationErrorRetries')})"
    )


# ---------------------------------------------------------------------------------------------
# Drill. Everything below needs the pinned litellm and only runs when it is importable.
# ---------------------------------------------------------------------------------------------


class StandInProvider(http.server.BaseHTTPRequestHandler):
    """The minimum an openai/generic endpoint needs: a chat/completions reply per row.

    `fail_plan` maps the model name (as litellm sends it after the provider prefix is
    stripped) to `(status, remaining_failures)`, so a row can be a wall or recover.
    Every POST is recorded in `attempts` and readable back over
    `GET /__drill/attempts`, so the parent process sees what the subprocess did.
    """

    protocol_version = "HTTP/1.1"
    fail_plan: dict[str, tuple[int, int]] = {}
    attempts: list[dict[str, Any]] = []

    def _reply(self, status: int, body: dict[str, Any]) -> None:
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802 - http.server API
        if self.path != "/__drill/attempts":
            self._reply(404, {"error": "not a drill endpoint"})
            return
        self._reply(200, {"attempts": StandInProvider.attempts})

    def do_POST(self) -> None:  # noqa: N802 - http.server API
        if self.path == "/__drill/reset":
            length = int(self.headers.get("Content-Length", "0"))
            plan = json.loads(self.rfile.read(length) or b"{}")
            StandInProvider.fail_plan = plan["fail_plan"]
            StandInProvider.attempts = []
            self._reply(200, {"ok": True})
            return
        if not self.path.endswith("/chat/completions"):
            self._reply(404, {"error": "not a drill endpoint"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length) or b"{}")
        model = str(request.get("model", "")).removeprefix(f"{PINNED_ROW.split('-')[0]}/")
        row = model.split("/")[-1]
        self.fail_plan.setdefault(row, (200, 0))
        status, remaining = self.fail_plan[row]
        self.attempts.append(
            {
                "row": row,
                "status": status,
                # Every attempt carries the whole prompt: this is what a cross-seat retry
                # re-sends.
                "prompt_chars": sum(len(str(m.get("content", ""))) for m in request.get("messages", [])),
            }
        )
        if remaining:
            self.fail_plan[row] = (status, remaining - 1)
            self._reply(status, {"error": {"message": f"stand-in {row} is 429ing/walled"}})
            return
        self.fail_plan[row] = (200, 0)
        self._reply(
            200,
            {
                "id": "chatcmpl-drill",
                "object": "chat.completion",
                "created": 0,
                "model": row,
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": "drill reply"},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
            },
        )

    def log_message(self, *args: Any) -> None:  # noqa: N802 - silence the drill's noise
        return


def _start_provider() -> tuple[socketserver.TCPServer, int]:
    server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), StandInProvider)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


def _row(model_name: str, port: int) -> dict[str, Any]:
    return {
        "model_name": GROUP,
        "litellm_params": {
            "model": f"openai/{model_name}",
            "api_base": f"http://127.0.0.1:{port}/v1",
            "api_key": "drill",
        },
        "model_info": {"id": model_name, "supports_prompt_caching": True},
    }


def _drill_post(port: int, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
    conn = HTTPConnection("127.0.0.1", port, timeout=30)
    try:
        if body is None:
            conn.request("POST", path)
        else:
            payload = json.dumps(body).encode()
            conn.request("POST", path, payload, {"Content-Type": "application/json"})
        resp = conn.getresponse()
        data = json.loads(resp.read())
        if resp.status != 200:
            raise RuntimeError(f"drill server {path}: {resp.status} {data}")
        return data
    finally:
        conn.close()


def _drill_get(port: int, path: str) -> dict[str, Any]:
    conn = HTTPConnection("127.0.0.1", port, timeout=30)
    try:
        conn.request("GET", path)
        resp = conn.getresponse()
        data = json.loads(resp.read())
        if resp.status != 200:
            raise RuntimeError(f"drill server {path}: {resp.status} {data}")
        return data
    finally:
        conn.close()


async def _do_call(retry_policy: dict[str, int], status: int, session_id: str, port: int) -> dict[str, Any]:
    from litellm import Router
    from litellm.router_utils.pre_call_checks.deployment_affinity_check import DeploymentAffinityCheck

    # Only used when this runs in-process: a case driven through _run_case takes its plan
    # from the server, which holds the state the subprocess cannot see.
    StandInProvider.fail_plan = {PINNED_ROW: (status, 999), PEER_ROW: (status, 999)}
    StandInProvider.attempts = []

    router = Router(
        model_list=[_row(PINNED_ROW, port), _row(PEER_ROW, port)],
        routing_strategy="simple-shuffle",
        num_retries=0,
        cooldown_time=60,
        allowed_fails=1,
        optional_pre_call_checks=["prompt_caching", "session_affinity"],
        deployment_affinity_ttl_seconds=3600,
        retry_policy=retry_policy,
    )
    pin_key = DeploymentAffinityCheck.get_session_affinity_cache_key(
        model_group=GROUP, session_id=session_id, user_key=None
    )
    await router.cache.async_set_cache(pin_key, json.dumps({"model_id": PINNED_ROW}), ttl=3600)

    outcome = "ok"
    try:
        await router.acompletion(
            model=GROUP,
            messages=[{"role": "user", "content": "drill prompt, sent in full on every attempt"}],
            metadata={"session_id": session_id},
        )
    except Exception as exc:  # surfaced, not hidden: the caller sees this
        outcome = type(exc).__name__

    return {
        "attempts": list(StandInProvider.attempts),
        "outcome": outcome,
        "pin_after": await router.cache.async_get_cache(pin_key),
    }


def _case_main(status: int, peer_fails: bool, port: int, session_id: str) -> None:
    """Run one case in a fresh process and emit the JSON report to stdout."""
    retry_policy = read_retry_policy()
    report = asyncio.run(_do_call(retry_policy, status, session_id, port))
    print(json.dumps({"status": status, "peer_fails": peer_fails, "session_id": session_id, "report": report}))


def _run_case(status: int, peer_fails: bool, port: int, session_id: str) -> dict[str, Any]:
    """Subprocess-per-case: no cross-talk between routers (global callbacks live in process).

    The parent sets the fail plan on the server and reads the attempt list back
    from the server's GET endpoint; the subprocess only drives the router.
    """
    plan = {PINNED_ROW: (status, 999), PEER_ROW: (status, 999) if peer_fails else (200, 0)}
    _drill_post(port, "/__drill/reset", {"fail_plan": plan})

    proc = subprocess.run(
        [sys.executable, __file__, "--case", str(status),
         "--peer-fails" if peer_fails else "--peer-ok", "--port", str(port), "--session-id", session_id],
        capture_output=True, text=True, timeout=60,
    )
    if proc.returncode != 0:
        print(proc.stdout, end="")
        print(proc.stderr, end="")
        raise RuntimeError(f"drill subprocess for HTTP {status} failed: {proc.returncode}")

    attempts = _drill_get(port, "/__drill/attempts")["attempts"]
    sub = json.loads(proc.stdout)["report"]
    return {"attempts": attempts, "outcome": sub["outcome"], "pin_after": sub["pin_after"]}


if __name__ == "__main__" and "--case" in sys.argv:
    args = sys.argv[1:]
    status = int(args[args.index("--case") + 1])
    peer_fails = "--peer-fails" in args
    port = int(args[args.index("--port") + 1])
    session_id = args[args.index("--session-id") + 1]
    _case_main(status, peer_fails, port, session_id)
    raise SystemExit(0)


def test_drill_attempts_equal_the_gate() -> None:
    """The attempt count of one failed call is `1 + <the value the config gate pins>`.

    litellm is only in the pinned venv on this host, so this drift stays unrun rather than
    failing for a missing dependency: `pytest.skip` equivalent.
    """
    try:
        import litellm  # noqa: F401
    except ImportError:
        print(f"[{Path(__file__).name}] SKIP drill: litellm not importable in {sys.executable}")
        return

    server, port = _start_provider()
    try:
        retry_policy = read_retry_policy()
        for status, key in BOTH_ROWS_FAIL.items():
            report = _run_case(status, peer_fails=True, port=port, session_id=f"sess-{status}-{key}")
            rows = [a["row"] for a in report["attempts"]]
            expected = ATTEMPTS_EXPECTED[status]
            print(
                f"HTTP {status} ({key}) attempts={len(rows)} rows={rows} "
                f"outcome={report['outcome']} pin_after={report['pin_after']} "
                f"prompt_chars={[a['prompt_chars'] for a in report['attempts']]}"
            )
            assert len(rows) == expected, (
                f"HTTP {status} with the shipped retry_policy took {len(rows)} attempts on "
                f"{rows}; {expected} is what {key}={retry_policy.get(key)} and the gate in this "
                "file say it should take. If the pinned litellm changed, re-derive this file."
            )
            assert rows[0] == PINNED_ROW, (
                f"HTTP {status}: the first attempt must be the pinned row, got {rows[0]}; the "
                "session pin is not being honoured, so the drill is no longer measuring the "
                "mid-session case"
            )
            assert report["pin_after"] == {"model_id": PINNED_ROW}, (
                f"HTTP {status}: the pin moved to {report['pin_after']}; the retry re-pins the "
                "session, which is a different (worse) bug than the one this file gates"
            )

        # With a healthy peer row, the retry either hands off to the peer (the hidden
        # cross-seat re-send the issue measured over real traffic) or re-picks the pinned
        # row when its cooldown has not registered yet. Both are a whole-prompt re-send;
        # only the first attempt is deterministic here.
        report = _run_case(429, peer_fails=False, port=port, session_id="sess-429-peer")
        seats = [a["row"] for a in report["attempts"]]
        print(
            f"HTTP 429, peer healthy attempts={len(seats)} rows={seats} outcome={report['outcome']} "
            f"pin_after={report['pin_after']}"
        )
        assert report["attempts"][0]["row"] == PINNED_ROW
        assert {a["prompt_chars"] for a in report["attempts"]} == {len("drill prompt, sent in full on every attempt")}, (
            f"every attempt must carry the whole prompt, got {[a['prompt_chars'] for a in report['attempts']]}"
        )
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    test_config_gate()
    print("config gate: ok")
    test_drill_attempts_equal_the_gate()
    print("drill: ok")