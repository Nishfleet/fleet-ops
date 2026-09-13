# fleet-litellm-devin-adapter — litellm CustomLLM bridge to the Devin/Windsurf
# funded seats (fleet-ops#6228).
#
# Why this exists: the Devin seats speak ONLY the proprietary Windsurf/Exafunction
# protocol through the signed Cascade client — no OpenAI-compatible endpoint
# exists anywhere (fleet-ops#6133 wire evidence: openai/* 404 on api.devin.ai/v1,
# api.devin.ai, server.codeium.com, windsurf.com/api/v1) and litellm 1.98.0 +
# upstream ship no windsurf/devin/codeium adapter (fleet-ops#4263 verdict). The
# ONE proven client is the devin CLI, already in production on this host via the
# pi devin-provider extension. This handler is the router-side bridge: a litellm
# CustomLLM that translates /chat/completions into a `devin --print` session.
#
# Shape (issue #6228 required line): ONE handler module wired via
# litellm_settings.custom_provider_map INSIDE the existing proxy organ — no new
# unit, timer, or organ (fleet-ops#1250 deletion-first).
#
# Install (docs/litellm-postgres-setup.md §7): copy this file next to the live
# config as ~/.config/fleet-ops/fleet_devin_adapter.py and register it in the
# live config's litellm_settings.custom_provider_map. litellm's
# get_instance_fn loads a module sibling of the config file first, so no
# PYTHONPATH or unit change is needed.
#
# Safety envelope:
# - Model allowlist (FLEET_DEVIN_ALLOWED_MODELS). The never-nevers are enforced
#   mechanically: swe-1-7 (retired, cap 0) and swe-2-high (parked to 2036) are
#   not in the allowlist and can never route, whatever a caller sends.
# - Read-only agent: --permission-mode auto auto-approves read-only tools only;
#   writes/exec are rejected by the CLI in non-interactive mode (live-probed
#   2026-09-14: the tool call is rejected, the session still returns text,
#   exit 0). The call runs in a throwaway PrivateTmp scratch cwd, never $HOME.
# - No secret ever moves: the CLI inherits DEVIN_API_KEY from the proxy process
#   env (the start wrapper already sources ~/fleet2/etc/devin.env).
# - A devin message rate limit with a short reset window is waited out once
#   (same philosophy as the pi devin-provider rate-limit resume); a long window
#   raises 429 so the router cools the deployment down and fails over.

import asyncio
import os
import re
import shutil
import subprocess
import tempfile
import uuid
from typing import Any, AsyncIterator, Iterator, List, Optional

from litellm.llms.custom_llm import CustomLLM, CustomLLMError
from litellm.types.utils import (
    Choices,
    GenericStreamingChunk,
    Message,
    ModelResponse,
    Usage,
)

DEVIN_BIN = os.environ.get("FLEET_DEVIN_BIN", "/home/nish/.local/bin/devin")
# Router timeout is 1800s; the bridge must give up first so the router's retry
# policy still has room to fail over to the next rung.
CALL_TIMEOUT_S = int(os.environ.get("FLEET_DEVIN_BRIDGE_TIMEOUT_S", "1500"))
# Devin message-limit handling: wait out short windows once, 429 the rest.
RATE_LIMIT_WAIT_S = int(os.environ.get("FLEET_DEVIN_BRIDGE_RATE_WAIT_S", "90"))
# The never-nevers (fleet-ops#6228): swe-1-7 retired (cap 0), swe-2-high parked
# to 2036. glm-5-2 healthy; swe-2-max re-benched 2026-09-14 (see PR).
ALLOWED_MODELS = frozenset(
    m.strip()
    for m in os.environ.get("FLEET_DEVIN_ALLOWED_MODELS", "glm-5-2,swe-2-max").split(",")
    if m.strip()
)
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
# Same message class the pi devin-provider resumes on (rate-limit.ts).
RATE_LIMIT_RE = re.compile(r"reached overall message rate limit|message rate limit", re.I)
RATE_LIMIT_RESET_RE = re.compile(r"resets?\s+in\s+(\d+)\s+(second|minute|hour|day)s?", re.I)
# The CLI prints this exact warning into stdout when the model reaches for a
# non-read-only tool in non-interactive mode; strip it from the returned text.
TOOL_REJECT_WARNING = "warning: rejected a tool call that requires confirmation."


def _model_slug(model: str) -> str:
    """devin/<slug> -> <slug>; reject anything outside the allowlist."""
    slug = model.split("/", 1)[1] if "/" in model else model
    if not SLUG_RE.match(slug):
        raise CustomLLMError(status_code=400, message=f"devin adapter: bad model slug {model!r}")
    if slug not in ALLOWED_MODELS:
        raise CustomLLMError(
            status_code=400,
            message=f"devin adapter: model {slug!r} is not allowlisted "
            f"(allowed: {sorted(ALLOWED_MODELS)}); never swe-1-7/swe-2-high (fleet-ops#6228)",
        )
    return slug


def _flatten_messages(messages: List[dict]) -> str:
    """Flatten a chat-completion conversation into the one-shot agent prompt.

    Mirrors the proven pi devin-provider shape (system prompt + conversation as
    the packet) but keeps the full history with role markers so multi-turn
    agent loops stay coherent.
    """
    parts: List[str] = []
    for msg in messages or []:
        if not isinstance(msg, dict):
            continue
        role = str(msg.get("role") or "user")
        content = msg.get("content")
        text_parts: List[str] = []
        if isinstance(content, str):
            text_parts.append(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    t = block.get("text")
                    if isinstance(t, str):
                        text_parts.append(t)
        body = "\n".join(p for p in text_parts if p)
        if not body.strip():
            continue
        if role == "system":
            parts.append(body)
        else:
            parts.append(f"[{role}]\n{body}")
    return "\n\n".join(parts).strip()


def _parse_reset_seconds(text: str) -> Optional[int]:
    m = RATE_LIMIT_RESET_RE.search(text)
    if not m:
        return None
    n = int(m.group(1))
    unit = m.group(2).lower()
    mult = {"second": 1, "minute": 60, "hour": 3600, "day": 86400}[unit]
    return n * mult if n > 0 else None


def _clean_output(stdout: str) -> str:
    lines = [
        ln for ln in stdout.splitlines() if not ln.lstrip().startswith(TOOL_REJECT_WARNING)
    ]
    return "\n".join(lines).strip()


def _run_devin_once(slug: str, prompt: str) -> str:
    if shutil.which(DEVIN_BIN) is None and not os.path.exists(DEVIN_BIN):
        raise CustomLLMError(status_code=500, message=f"devin adapter: {DEVIN_BIN} not found")
    if not os.environ.get("DEVIN_API_KEY"):
        raise CustomLLMError(
            status_code=500,
            message="devin adapter: DEVIN_API_KEY missing from the proxy process env "
            "(the start wrapper sources ~/fleet2/etc/devin.env)",
        )
    workdir = tempfile.mkdtemp(prefix="fleet-devin-bridge-")
    prompt_file = os.path.join(workdir, "prompt.md")
    with open(prompt_file, "w", encoding="utf-8") as fh:
        fh.write(prompt)
    args = [
        DEVIN_BIN,
        "--print",
        "--prompt-file",
        prompt_file,
        "--model",
        slug,
        "--respect-workspace-trust",
        "false",
        # Read-only tools only: writes/exec are rejected by the CLI in
        # non-interactive mode (live-probed 2026-09-14, see module docstring).
        "--permission-mode",
        "auto",
    ]
    try:
        proc = subprocess.run(
            args,
            cwd=workdir,
            env=os.environ.copy(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=CALL_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired as exc:
        raise CustomLLMError(
            status_code=504,
            message=f"devin adapter: devin --print exceeded {CALL_TIMEOUT_S}s on {slug}",
        ) from exc
    except OSError as exc:
        raise CustomLLMError(status_code=500, message=f"devin adapter: spawn failed: {exc}") from exc
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    stdout = proc.stdout.decode("utf-8", errors="replace")
    stderr = proc.stderr.decode("utf-8", errors="replace")
    if proc.returncode != 0:
        combined = f"{stderr}\n{stdout}".strip()
        if RATE_LIMIT_RE.search(combined):
            reset_s = _parse_reset_seconds(combined)
            raise CustomLLMError(
                status_code=429,
                message=f"devin adapter: message rate limit on {slug}"
                + (f", resets in {reset_s}s" if reset_s else ""),
            )
        raise CustomLLMError(
            status_code=500,
            message=f"devin adapter: devin --print exited {proc.returncode} on {slug}: "
            + combined[:500],
        )
    text = _clean_output(stdout)
    if not text:
        raise CustomLLMError(
            status_code=502,
            message=f"devin adapter: empty response from devin --print on {slug}",
        )
    return text


def _estimate_tokens(text: str) -> int:
    return max(1, len(text) // 4) if text else 0


def _completion_core(
    model: str,
    messages: List[dict],
    model_response: ModelResponse,
) -> ModelResponse:
    slug = _model_slug(model)
    prompt = _flatten_messages(messages)
    if not prompt:
        raise CustomLLMError(status_code=400, message="devin adapter: empty prompt")
    try:
        text = _run_devin_once(slug, prompt)
    except CustomLLMError as exc:
        # A short devin message-limit window is a pause, not a death: wait it
        # out once (pi devin-provider philosophy), then give up loudly.
        if exc.status_code == 429:
            reset_s = _parse_reset_seconds(str(exc.message))
            if reset_s is not None and reset_s <= RATE_LIMIT_WAIT_S:
                import time

                time.sleep(reset_s + 5)
                text = _run_devin_once(slug, prompt)
            else:
                raise
        else:
            raise
    model_response.model = model
    model_response.id = f"chatcmpl-{uuid.uuid4().hex}"
    model_response.choices = [
        Choices(
            message=Message(content=text, role="assistant"),
            finish_reason="stop",
            index=0,
        )
    ]
    prompt_tokens = _estimate_tokens(prompt)
    completion_tokens = _estimate_tokens(text)
    model_response.usage = Usage(
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        total_tokens=prompt_tokens + completion_tokens,
    )
    return model_response


class DevinWindsurfLLM(CustomLLM):
    """litellm CustomLLM bridge: /chat/completions -> devin --print session."""

    def completion(self, model: str, messages: List[dict], **kwargs: Any) -> ModelResponse:
        return _completion_core(
            model,
            messages,
            kwargs.get("model_response") or ModelResponse(),
        )

    async def acompletion(self, model: str, messages: List[dict], **kwargs: Any) -> ModelResponse:
        return await asyncio.to_thread(
            _completion_core,
            model,
            messages,
            kwargs.get("model_response") or ModelResponse(),
        )

    def streaming(
        self, model: str, messages: List[dict], **kwargs: Any
    ) -> Iterator[GenericStreamingChunk]:
        response = self.completion(model, messages, **kwargs)
        yield from self._single_chunk_stream(model, response)

    async def astreaming(
        self, model: str, messages: List[dict], **kwargs: Any
    ) -> AsyncIterator[GenericStreamingChunk]:
        response = await self.acompletion(model, messages, **kwargs)
        for chunk in self._single_chunk_stream(model, response):
            yield chunk

    @staticmethod
    def _single_chunk_stream(model: str, response: ModelResponse) -> Iterator[GenericStreamingChunk]:
        text = ""
        if response.choices:
            content = response.choices[0].message.content
            text = content if isinstance(content, str) else ""
        chunk: GenericStreamingChunk = {
            "text": text,
            "is_finished": True,
            "finish_reason": "stop",
            "usage": {
                "prompt_tokens": response.usage.prompt_tokens if response.usage else 0,
                "completion_tokens": response.usage.completion_tokens if response.usage else 0,
                "total_tokens": response.usage.total_tokens if response.usage else 0,
            },
            "index": 0,
            "tool_calls": None,
        }
        yield chunk


# Registered in the live config via litellm_settings.custom_provider_map:
#   - provider: devin
#     custom_handler: fleet_devin_adapter.devin_windsurf_llm
devin_windsurf_llm = DevinWindsurfLLM()
