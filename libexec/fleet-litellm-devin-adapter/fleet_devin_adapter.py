"""fleet-ops#6228 — LiteLLM CustomLLM bridge into the Devin/Windsurf CLI.

Why this file exists: the funded Devin seats speak a proprietary
Windsurf/Exafunction protocol (fleet-ops#4263) and expose no
OpenAI-compatible ``/v1/chat/completions`` endpoint, so LiteLLM cannot
reach them as a normal ``api_base`` deployment. The Devin CLI, however,
does expose a headless completion path::

    devin --print --prompt-file <f> --model <slug> \
          --respect-workspace-trust false --permission-mode auto

This module adapts LiteLLM chat completions to that CLI. It is loaded
inside the existing ``fleet-litellm-proxy`` organ — LiteLLM 1.98
resolves ``litellm_settings.custom_provider_map`` handlers relative to
the config file, so the deployed copy sits next to
``~/.config/fleet-ops/litellm-proxy.yaml`` as ``fleet_devin_adapter.py``
and is referenced as ``fleet_devin_adapter.devin_windsurf_llm``. No new
unit, timer, or organ (fleet-ops#1250): the proxy start wrapper already
sources ``fleet2/etc/devin.env`` (runbook §3a), so ``DEVIN_API_KEY`` is
already in the proxy environment.

Model policy (issue #6228 hard lines): only ``glm-5-2`` and
``swe-2-max`` may route. ``swe-1-7`` (retired, cap 0) and
``swe-2-high`` (parked to 2036) are refused here even if a deployment
is misconfigured — the allowlist is the last line of defence.

Health checks: LiteLLM's internal health check calls ``acompletion``
with ``metadata.tags == ["litellm-internal-health-check"]``. A real
``devin --print`` probe would burn a paid message slot every 30s and
serialize the seat against worker traffic, so probe calls run
``devin models list`` instead — a real authenticated API call (fails
on a dead key) that also verifies the requested model slug is still
listed, without consuming message quota. Everything else is a genuine
``devin --print`` round-trip.

Failure mapping uses native LiteLLM exception classes so the router's
``allowed_fails_policy``/``retry_policy`` classify them correctly:

- model not in the allowlist     → ``BadRequestError`` (config bug, loud)
- devin rate limit, long window  → ``RateLimitError`` (router cooldown +
  failover to the next rung)
- CLI timeout                    → ``litellm.Timeout``
- empty output / nonzero exit    → ``InternalServerError``
"""

from __future__ import annotations

import asyncio
import os
import re
import subprocess
import tempfile
import uuid
from typing import Any, AsyncGenerator, Generator, Iterable, Optional

import litellm
from litellm.llms.custom_llm import CustomLLM
from litellm.types.utils import (
    Choices,
    GenericStreamingChunk,
    Message,
    ModelResponse,
    Usage,
)

DEVIN_BIN = os.environ.get("FLEET_DEVIN_BIN", "/home/nish/.local/bin/devin")

# Whole-call ceiling, deliberately below router_settings.timeout (1800s)
# so the router — not this adapter — owns the outer deadline and can
# record the failure/failover cleanly.
CALL_TIMEOUT_S = int(os.environ.get("FLEET_DEVIN_BRIDGE_TIMEOUT_S", "1500"))

# Cheap health-probe ceiling: `devin models list` is a ~1-2s API call;
# 60s is generous margin for a cold node start.
PROBE_TIMEOUT_S = int(os.environ.get("FLEET_DEVIN_PROBE_TIMEOUT_S", "60"))

# Short devin rate-limit windows (the CLI prints "resets in N units")
# are waited out once in-process; windows longer than this are raised
# as RateLimitError so LiteLLM cools the deployment and fails over —
# tying a proxy worker thread to a parked seat for tens of minutes
# starves the whole intake lane.
RATE_LIMIT_WAIT_S = int(os.environ.get("FLEET_DEVIN_BRIDGE_RATE_WAIT_S", "90"))

# Issue #6228 approved slugs. swe-1-7 is retired (cap 0) and swe-2-high
# is parked to 2036 — neither may ever appear here.
_ALLOWED_MODELS = {
    m.strip()
    for m in os.environ.get("FLEET_DEVIN_ALLOWED_MODELS", "glm-5-2,swe-2-max").split(",")
    if m.strip()
}

HEALTH_CHECK_TAG = "litellm-internal-health-check"

RATE_LIMIT_RE = re.compile(
    r"reached overall message rate limit|message rate limit|"
    r"rate.?limit(ed)?\s+exceeded|too many requests|\b429\b",
    re.I,
)
# "resets in 3 minutes", "resets at 1:16 PM", "Retry-After: 30", ...
RATE_LIMIT_RESET_IN_RE = re.compile(
    r"resets?\s+in\s+(\d+)\s+(second|minute|hour|day)s?", re.I
)
RETRY_AFTER_RE = re.compile(r"retry[-_ ]?after[:\s]+(\d+)", re.I)

# The devin CLI prints this notice on stderr when --permission-mode auto
# refuses a write tool call; it is expected in a read-only completion
# bridge and must not pollute the assistant text.
_TOOL_REJECT_NOTICE = "warning: rejected a tool call that requires confirmation."

_UNIT_SECONDS = {"second": 1, "minute": 60, "hour": 3600, "day": 86400}


class DevinWindsurfLLM(CustomLLM):
    """Translate LiteLLM chat completions into headless devin CLI calls."""

    # ---- LiteLLM entry points -------------------------------------------

    def completion(self, *args, **kwargs) -> ModelResponse:
        model = kwargs.get("model", "")
        messages = kwargs.get("messages", [])
        litellm_params = kwargs.get("litellm_params") or {}
        model_response = kwargs.get("model_response")
        return self._complete(model, messages, litellm_params, model_response)

    async def acompletion(self, *args, **kwargs) -> ModelResponse:
        model = kwargs.get("model", "")
        messages = kwargs.get("messages", [])
        litellm_params = kwargs.get("litellm_params") or {}
        model_response = kwargs.get("model_response")
        return await asyncio.to_thread(
            self._complete, model, messages, litellm_params, model_response
        )

    def streaming(self, *args, **kwargs) -> Generator[GenericStreamingChunk, None, None]:
        # One-shot CLI: buffer the full reply and emit a single finished
        # chunk. Incremental token streaming is not available from
        # `devin --print`.
        resp = self.completion(*args, **kwargs)
        yield self._chunk_from_response(resp)

    async def astreaming(
        self, *args, **kwargs
    ) -> AsyncGenerator[GenericStreamingChunk, None]:
        resp = await self.acompletion(*args, **kwargs)
        yield self._chunk_from_response(resp)

    # ---- internals -------------------------------------------------------

    def _complete(
        self,
        model: str,
        messages: Iterable[dict],
        litellm_params: dict,
        model_response: Optional[ModelResponse],
    ) -> ModelResponse:
        slug = self._slug(model)
        if _is_health_probe(litellm_params):
            text = self._health_probe(slug)
        else:
            text = self._chat_call(slug, _flatten(messages))
        return self._response(model, slug, text, model_response)

    def _slug(self, model: str) -> str:
        slug = model.split("/", 1)[1] if model.startswith("devin/") else model
        if slug not in _ALLOWED_MODELS:
            raise litellm.BadRequestError(
                message=(
                    f"devin model {slug!r} is not in the fleet allowlist "
                    f"({sorted(_ALLOWED_MODELS)}); swe-1-7 is retired and "
                    "swe-2-high is parked to 2036 (fleet-ops#6228)"
                ),
                model=model,
                llm_provider="devin",
            )
        return slug

    def _health_probe(self, slug: str) -> str:
        """Authenticated upstream check without spending a message slot."""
        rc, out, err = _run_devin(
            [DEVIN_BIN, "models", "list"], timeout=PROBE_TIMEOUT_S, cwd=None
        )
        if rc != 0:
            raise _cli_error(slug, rc, out, err, context="models list")
        if not re.search(rf"(?m)^\s*{re.escape(slug)}\b", out):
            raise litellm.InternalServerError(
                message=(
                    f"devin model {slug!r} not present in `devin models list` "
                    "output — seat cannot serve this deployment"
                ),
                llm_provider="devin",
                model=slug,
            )
        return "ok"

    def _chat_call(self, slug: str, prompt: str) -> str:
        argv = [
            DEVIN_BIN,
            "--print",
            "--prompt-file",
            None,  # placeholder, filled with the scratch path
            "--model",
            slug,
            "--respect-workspace-trust",
            "false",
            "--permission-mode",
            "auto",
        ]
        attempts = 2  # one retry, only for a short rate-limit window
        for attempt in range(attempts):
            with tempfile.TemporaryDirectory(
                prefix="devin-bridge-"
            ) as scratch:
                prompt_path = os.path.join(scratch, "prompt.txt")
                with open(prompt_path, "w", encoding="utf-8") as fh:
                    fh.write(prompt)
                argv[3] = prompt_path
                try:
                    rc, out, err = _run_devin(
                        argv, timeout=CALL_TIMEOUT_S, cwd=scratch
                    )
                except litellm.Timeout:
                    raise
                except Exception as exc:  # subprocess-level failure
                    raise litellm.InternalServerError(
                        message=f"devin CLI invocation failed: {exc}",
                        llm_provider="devin",
                        model=slug,
                    )
            wait_s = _rate_limit_wait_s(out + "\n" + err)
            if wait_s is not None:
                if wait_s <= RATE_LIMIT_WAIT_S and attempt == 0:
                    _sleep(wait_s)
                    continue
                raise _rate_limit_error(slug, out + "\n" + err, wait_s)
            if rc == 0 and _clean(out):
                return _clean(out)
            # nonzero exit or empty output: fail fast, the router's
            # retry/failover policy owns what happens next
            raise _cli_error(slug, rc, out, err, context="--print")
        raise litellm.InternalServerError(  # unreachable, defensive
            message="devin bridge exhausted attempts",
            llm_provider="devin",
            model=slug,
        )

    # ---- response shaping -------------------------------------------------

    def _response(
        self,
        model: str,
        slug: str,
        text: str,
        model_response: Optional[ModelResponse],
    ) -> ModelResponse:
        resp = model_response if model_response is not None else ModelResponse()
        resp.id = f"chatcmpl-devin-{uuid.uuid4().hex[:24]}"
        resp.model = model
        resp.choices = [
            Choices(
                index=0,
                message=Message(role="assistant", content=text),
                finish_reason="stop",
            )
        ]
        in_toks = 0  # prompt tokens are not reported by the CLI
        out_toks = max(1, len(text) // 4)
        resp.usage = Usage(
            prompt_tokens=in_toks,
            completion_tokens=out_toks,
            total_tokens=in_toks + out_toks,
        )
        resp._hidden_params["custom_llm_provider"] = "devin"
        resp._hidden_params["devin_model"] = slug
        return resp

    def _chunk_from_response(self, resp: ModelResponse) -> GenericStreamingChunk:
        text = resp.choices[0].message.content or ""
        usage = getattr(resp, "usage", None)
        # GenericStreamingChunk.usage is a ChatCompletionUsageBlock dict —
        # LiteLLM's streaming_handler does Usage(**chunk["usage"]), so a
        # Usage object here TypeErrors and 500s every stream (fleet-ops#6866).
        if usage is not None and not isinstance(usage, dict):
            dump = getattr(usage, "model_dump", None)
            usage = dump() if callable(dump) else vars(usage)
        return GenericStreamingChunk(
            text=text,
            is_finished=True,
            finish_reason="stop",
            usage=usage,
            index=0,
            tool_use=None,
        )


def _is_health_probe(litellm_params: dict) -> bool:
    tags = ((litellm_params.get("metadata") or {}).get("tags")) or []
    return HEALTH_CHECK_TAG in tags


def _flatten(messages: Iterable[dict]) -> str:
    """Flatten chat messages into a single devin prompt.

    Each call is a fresh `devin --print` session, so prior turns are
    replayed inline with role headers — same transcript shape pi sends
    to its own devin provider.
    """
    parts = []
    for msg in messages:
        role = msg.get("role", "user")
        content = msg.get("content", "")
        if isinstance(content, list):
            # multimodal blocks: keep text parts only (devin is text)
            content = "\n".join(
                p.get("text", "")
                for p in content
                if isinstance(p, dict) and p.get("type") == "text"
            )
        content = (content or "").strip()
        if not content:
            continue
        parts.append(f"## {role.capitalize()}\n{content}")
    return "\n\n".join(parts)


def _clean(text: str) -> str:
    lines = [
        ln for ln in text.splitlines() if _TOOL_REJECT_NOTICE not in ln
    ]
    return "\n".join(lines).strip()


def _run_devin(argv: list, timeout: int, cwd: Optional[str]):
    try:
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=cwd,
        )
        return proc.returncode, proc.stdout or "", proc.stderr or ""
    except subprocess.TimeoutExpired:
        raise litellm.Timeout(
            message=f"devin CLI exceeded {timeout}s deadline",
            model=argv[argv.index("--model") + 1] if "--model" in argv else "devin",
            llm_provider="devin",
        )
    except FileNotFoundError:
        raise litellm.InternalServerError(
            message=f"devin binary not found at {argv[0]}",
            llm_provider="devin",
            model="devin",
        )


def _sleep(seconds: float) -> None:
    import time

    time.sleep(seconds)


def _rate_limit_wait_s(text: str) -> Optional[int]:
    if not RATE_LIMIT_RE.search(text):
        return None
    m = RATE_LIMIT_RESET_IN_RE.search(text)
    if m:
        return int(m.group(1)) * _UNIT_SECONDS.get(m.group(2).lower(), 60)
    m = RETRY_AFTER_RE.search(text)
    if m:
        return int(m.group(1))
    # rate-limit wording with no parseable wait: treat as long so the
    # router cools the deployment instead of blocking a proxy worker
    return RATE_LIMIT_WAIT_S + 1


def _rate_limit_error(slug: str, output: str, wait_s: int) -> litellm.RateLimitError:
    tail = "\n".join(output.strip().splitlines()[-8:])[:800]
    return litellm.RateLimitError(
        message=(
            f"devin rate limit for {slug}: resets in ~{wait_s}s "
            f"(> {RATE_LIMIT_WAIT_S}s in-process wait budget). {tail}"
        ),
        llm_provider="devin",
        model=slug,
    )


def _cli_error(slug: str, rc: int, out: str, err: str, context: str) -> Exception:
    tail = "\n".join((err.strip() + "\n" + out.strip()).splitlines()[-10:])[:1200]
    if rc == 0 and not _clean(out):
        return litellm.InternalServerError(
            message=f"devin {context} returned empty output for {slug}",
            llm_provider="devin",
            model=slug,
        )
    return litellm.InternalServerError(
        message=f"devin {context} exited {rc} for {slug}: {tail}",
        llm_provider="devin",
        model=slug,
    )


# LiteLLM resolves this symbol from custom_provider_map.
devin_windsurf_llm = DevinWindsurfLLM()
