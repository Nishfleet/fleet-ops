#!/usr/bin/env bash
# tests/litellm-gchunk-usage-patch.test.sh — fleet-ops#6863
#
# Detector + drill for the fleet patch
# patches/litellm-1.98.0-gchunk-usage-union.patch, which fixes litellm's
# generic-streaming-chunk branch doing `Usage(**usage)` on a chunk whose
# usage already arrived as a pydantic Usage/BaseModel ("Usage() argument
# after ** must be a mapping, not Usage") — the mid-stream kill that took
# down litellm/senior on 2026-09-14.
#
# Drills:
#   1. --help exits 0.
#   2. The patch applies (--dry-run) to the pinned 1.98.0 fixture — drift
#      detector: if a litellm bump changes the hunk's context, this fails
#      instead of silently running an unpatched or half-patched organ.
#   3. A real apply produces the patched shape (marker + model_dump
#      normalize; the raw `Usage(**anthropic_response_obj["usage"])` call
#      gone) and `patch -R --dry-run` round-trips it.
#   4. Live-organ check (skipped with a SKIP line when the litellm venv is
#      absent, e.g. CI): the INSTALLED streaming_handler.py carries the
#      patch marker — this is the silent-unpatch detector for rebuilds —
#      and a semantic drill drives _dispatch_provider_chunk with usage as
#      a litellm Usage, an openai CompletionUsage, a dict, and None.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
patch_file="$repo_root/patches/litellm-1.98.0-gchunk-usage-union.patch"
fixture="$here/fixtures/litellm-1.98.0-streaming_handler-gchunk.py"
venv_file="$HOME/.local/venvs/litellm/lib/python3.12/site-packages/litellm/litellm_core_utils/streaming_handler.py"
venv_py="$HOME/.local/venvs/litellm/bin/python"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
skip() { echo "SKIP: $*"; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,24p' "$0"
    exit 0
fi

command -v patch >/dev/null || fail "patch(1) not on PATH"
[[ -f "$patch_file" ]] || fail "missing $patch_file"
[[ -f "$fixture" ]]    || fail "missing $fixture"
ok "patch file + fixture present"

scratch="$(mktemp -d -t gchunk-usage-patch.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
target="$scratch/litellm/litellm_core_utils"
mkdir -p "$target"
cp "$fixture" "$target/streaming_handler.py"

# Drill 2: hunk still matches the pinned upstream shape.
patch -d "$scratch" -p1 --dry-run < "$patch_file" >/dev/null \
    || fail "patch does not apply to the 1.98.0 fixture — upstream drift; rebase or drop the patch"
ok "patch applies cleanly to the pinned 1.98.0 shape"

# Drill 3: real apply produces the intended patched shape, reversibly.
patch -d "$scratch" -p1 < "$patch_file" >/dev/null || fail "real apply failed"
grep -q '_chunk_usage = anthropic_response_obj\["usage"\]' "$target/streaming_handler.py" \
    || fail "patched fixture missing _chunk_usage marker"
grep -q '_chunk_usage.model_dump()' "$target/streaming_handler.py" \
    || fail "patched fixture missing model_dump() normalize"
grep -q 'litellm.Usage(\*\*anthropic_response_obj\["usage"\])' "$target/streaming_handler.py" \
    && fail "raw Usage(**usage) call still present after patch"
patch -d "$scratch" -p1 -R --dry-run < "$patch_file" >/dev/null \
    || fail "patch -R does not round-trip — patch is not a clean reversible delta"
ok "apply produces patched shape and reverses cleanly"

# Drill 4: live install carries the patch and behaves (host-only).
if [[ ! -f "$venv_file" ]]; then
    skip "no litellm venv at $venv_file — live-organ checks skipped"
    exit 0
fi

grep -q '_chunk_usage = anthropic_response_obj\["usage"\]' "$venv_file" \
    || fail "INSTALLED streaming_handler.py lacks the fleet-ops#6863 patch — rebuild dropped it; rerun docs/litellm-postgres-setup.md §3 patch step"
ok "installed streaming_handler.py carries the patch marker"

"$venv_py" - <<'PYEOF' || fail "semantic drill against the installed module failed"
from litellm.litellm_core_utils.streaming_handler import (
    CustomStreamWrapper, _ProviderChunkParsed)
from litellm.types.utils import (
    Usage, ModelResponseStream, StreamingChoices, Delta)
from openai.types.completion_usage import CompletionUsage

inst = object.__new__(CustomStreamWrapper)
for attr, val in dict(received_finish_reason=None, custom_llm_provider=None,
                      model="m", intermittent_finish_reason=None,
                      system_fingerprint=None, response_id=None,
                      created=None).items():
    setattr(inst, attr, val)


def mk_response():
    return ModelResponseStream(
        model="m", choices=[StreamingChoices(index=0, delta=Delta(content=""))])


def gchunk(usage):
    return {"text": "", "is_finished": True, "finish_reason": "stop",
            "usage": usage, "tool_use": None,
            "provider_specific_fields": None, "index": 0}


# The reported crash shape: usage already a litellm Usage object.
mr = mk_response()
res = inst._dispatch_provider_chunk(
    gchunk(Usage(prompt_tokens=3, completion_tokens=4, total_tokens=7)),
    mr, {"content": ""})
assert isinstance(res, _ProviderChunkParsed)
assert isinstance(mr.usage, Usage) and mr.usage.total_tokens == 7

# Other pydantic usage objects (e.g. openai CompletionUsage) normalize too.
mr = mk_response()
inst._dispatch_provider_chunk(
    gchunk(CompletionUsage(prompt_tokens=10, completion_tokens=5,
                           total_tokens=15)),
    mr, {"content": ""})
assert mr.usage.total_tokens == 15

# Plain dict usage keeps its detail fields (unchanged pre-patch behavior).
mr = mk_response()
inst._dispatch_provider_chunk(
    gchunk({"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2,
            "prompt_tokens_details": {"cached_tokens": 1}}),
    mr, {"content": ""})
assert mr.usage.total_tokens == 2
assert mr.usage.prompt_tokens_details.cached_tokens == 1

# usage=None stays unset.
mr = mk_response()
inst._dispatch_provider_chunk(gchunk(None), mr, {"content": ""})
assert getattr(mr, "usage", None) is None
print("semantic drill: Usage/CompletionUsage/dict/None all pass")
PYEOF
ok "live drill: Usage-object chunks no longer crash _dispatch_provider_chunk"
echo "ALL PASS"
