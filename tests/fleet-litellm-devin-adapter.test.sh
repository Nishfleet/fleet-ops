#!/usr/bin/env bash
# fleet-ops#6228 — LiteLLM CustomLLM Devin/Windsurf adapter.
# Hermetic: stub litellm modules on sys.path + a fake `devin` binary, so
# no real CLI call and no litellm install are needed. Plus repo-shape
# pins: config registration, PYTHONPATH, sibling-install runbook, no new unit.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
adapter="$repo_root/libexec/fleet-litellm-devin-adapter/fleet_devin_adapter.py"
cfg="$repo_root/config/litellm-proxy.yaml"
unit="$repo_root/systemd/fleet-litellm-proxy.service"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$adapter" ]] || fail "adapter missing: $adapter"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

scratch="$(mktemp -d -t devin-adapter-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- fake devin CLI -------------------------------------------------------
# Behaviour selected by $FAKE_DEVIN_MODE; argv appended to $FAKE_DEVIN_LOG.
cat > "$scratch/devin" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${FAKE_DEVIN_LOG:?}"
mode="${FAKE_DEVIN_MODE:-ok}"
if [[ "$1" == "models" ]]; then
    echo "Current: auto"
    echo "${FAKE_MODELS:-  glm-5-2   GLM-5.2
  swe-2-max  SWE-2 Max}"
    exit 0
fi
model="unknown"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) model="$2"; shift 2;;
        --prompt-file) prompt="$2"; shift 2;;
        *) shift;;
    esac
done
case "$mode" in
    ok)
        printf 'STUB-REPLY model=%s\n' "$model"
        [[ -f "${prompt:-/dev/null}" ]] && head -c 400 "$prompt"
        ;;
    empty)      : ;;
    write)      touch "$PWD/WRITE-MARKER"; echo "wrote";;
    fail)       echo "boom" >&2; exit 3;;
    rl-short)
        n="$(( $(cat "${FAKE_DEVIN_COUNT:?}" 2>/dev/null || echo 0) + 1 ))"
        echo "$n" > "$FAKE_DEVIN_COUNT"
        if [[ "$n" -eq 1 ]]; then
            echo "reached overall message rate limit — resets in 2 seconds" >&2
            exit 1
        fi
        echo "REPLY-AFTER-RETRY";;
    rl-long)
        echo "reached overall message rate limit — resets in 3 hours" >&2
        exit 1;;
    rl-clock)
        echo "reached overall message rate limit — resets at 1:16 PM" >&2
        exit 1;;
    timeout)    sleep 5; echo late;;
    *)          echo "unknown mode $mode" >&2; exit 9;;
esac
EOF
chmod +x "$scratch/devin"
touch "$scratch/devin.log" "$scratch/count"

# --- 1. hermetic python suite --------------------------------------------
FAKE_DEVIN_LOG="$scratch/devin.log" \
FAKE_DEVIN_COUNT="$scratch/count" \
FLEET_DEVIN_BIN="$scratch/devin" \
FLEET_DEVIN_BRIDGE_TIMEOUT_S=3 \
FLEET_DEVIN_PROBE_TIMEOUT_S=3 \
FLEET_DEVIN_ALLOWED_MODELS="glm-5-2,swe-2-max" \
DEVIN_API_KEY=stub-key \
ADAPTER="$adapter" \
python3 - <<'PY' || fail "adapter unit checks"
import asyncio, importlib.util, os, sys, types
from types import SimpleNamespace

# --- stub litellm before importing the adapter ---
class LLMError(Exception):
    def __init__(self, message=None, model=None, llm_provider=None, **kw):
        super().__init__(message)
        self.message, self.model, self.llm_provider = message, model, llm_provider

litellm = types.ModuleType("litellm")
for n in ("RateLimitError", "InternalServerError", "BadRequestError", "Timeout"):
    setattr(litellm, n, type(n, (LLMError,), {}))

custom_llm = types.ModuleType("litellm.llms.custom_llm")
custom_llm.CustomLLM = type("CustomLLM", (), {})
custom_llm.CustomLLMError = type("CustomLLMError", (Exception,), {})
llms = types.ModuleType("litellm.llms"); llms.custom_llm = custom_llm
types_mod = types.ModuleType("litellm.types")
utils_mod = types.ModuleType("litellm.types.utils")
class ModelResponse:
    def __init__(self):
        self.id = None; self.model = None; self.choices = []
        self.usage = None; self._hidden_params = {}
utils_mod.ModelResponse = ModelResponse
utils_mod.Choices = lambda **kw: SimpleNamespace(**kw)
utils_mod.Message = lambda **kw: SimpleNamespace(**kw)
utils_mod.Usage = lambda **kw: SimpleNamespace(**kw)
utils_mod.GenericStreamingChunk = dict
litellm.llms = llms; litellm.types = types_mod; types_mod.utils = utils_mod
sys.modules.update({
    "litellm": litellm, "litellm.llms": llms,
    "litellm.llms.custom_llm": custom_llm,
    "litellm.types": types_mod, "litellm.types.utils": utils_mod,
})

spec = importlib.util.spec_from_file_location(
    "fleet_devin_adapter", os.environ["ADAPTER"])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
h = mod.devin_windsurf_llm

LOG = os.environ["FAKE_DEVIN_LOG"]
def log_lines():
    return [l for l in open(LOG).read().splitlines() if l.strip()]
def reset_log():
    open(LOG, "w").close()

def expect(exc, fn, label):
    try:
        fn()
    except exc:
        return
    except Exception as e:
        raise AssertionError(f"{label}: wanted {exc.__name__}, got {type(e).__name__}: {e}")
    raise AssertionError(f"{label}: wanted {exc.__name__}, call succeeded")

msgs = [{"role": "user", "content": "say hi"}]
probe_lp = {"metadata": {"tags": ["litellm-internal-health-check"]}}

def scratch_dirs():
    return {d for d in os.listdir("/tmp") if d.startswith("devin-bridge-")}
BASE_SCRATCH = scratch_dirs()  # stale dirs from prior runs are ignored

# allowlist: approved slugs pass, forbidden slugs raise BadRequestError
# FLEET_DEVIN_ALLOWED_MODELS is set in the environment with glm-5-2; the
# adapter must ignore it and still refuse the retired slug.
expect(litellm.BadRequestError, lambda: h._slug("devin/glm-5-2"), "retired-glm-5-2")
assert h._slug("devin/swe-2-max") == "swe-2-max"
expect(litellm.BadRequestError, lambda: h._slug("devin/swe-1-7"), "swe-1-7")
expect(litellm.BadRequestError, lambda: h._slug("devin/swe-2-high"), "swe-2-high")
expect(litellm.BadRequestError, lambda: h._slug("devin/gpt-5"), "unknown")

# happy path: real --print call, response shape
os.environ["FAKE_DEVIN_MODE"] = "ok"
reset_log()
r = h.completion(model="devin/swe-2-max", messages=msgs, litellm_params={})
argv = log_lines()[0]
for want in ("--print", "--prompt-file", "--model swe-2-max",
             "--respect-workspace-trust false", "--permission-mode auto"):
    assert want in argv, f"argv missing {want}: {argv}"
assert r.model == "devin/swe-2-max"
assert r.id.startswith("chatcmpl-devin-")
assert r.choices[0].message.content.startswith("STUB-REPLY model=swe-2-max")
assert "## User" in r.choices[0].message.content  # prompt flattened + echoed
assert r.usage.total_tokens > 0
assert r._hidden_params["custom_llm_provider"] == "devin"

# scratch cwd is a throwaway dir, cleaned after the call
leaked = scratch_dirs() - BASE_SCRATCH
assert not leaked, f"leaked scratch dirs: {leaked}"

# empty output is a failure, not a silent empty message
os.environ["FAKE_DEVIN_MODE"] = "empty"
expect(litellm.InternalServerError,
       lambda: h.completion(model="devin/swe-2-max", messages=msgs,
                            litellm_params={}), "empty")

# nonzero exit (non-rate-limit) → InternalServerError with tail
os.environ["FAKE_DEVIN_MODE"] = "fail"
expect(litellm.InternalServerError,
       lambda: h.completion(model="devin/swe-2-max", messages=msgs,
                            litellm_params={}), "fail")

# short rate-limit window: one in-process retry, then success
os.environ["FAKE_DEVIN_MODE"] = "rl-short"
open(os.environ["FAKE_DEVIN_COUNT"], "w").close()
reset_log()
r = h.completion(model="devin/swe-2-max", messages=msgs, litellm_params={})
assert "REPLY-AFTER-RETRY" in r.choices[0].message.content
assert len(log_lines()) == 2, f"expected exactly 2 devin calls, got {log_lines()}"

# long window: no wait, RateLimitError for router cooldown+failover
os.environ["FAKE_DEVIN_MODE"] = "rl-long"
reset_log()
expect(litellm.RateLimitError,
       lambda: h.completion(model="devin/swe-2-max", messages=msgs,
                            litellm_params={}), "rl-long")
assert len(log_lines()) == 1, "long window must not retry in-process"

# unparseable clock-style reset → treated as long window
os.environ["FAKE_DEVIN_MODE"] = "rl-clock"
expect(litellm.RateLimitError,
       lambda: h.completion(model="devin/swe-2-max", messages=msgs,
                            litellm_params={}), "rl-clock")

# CLI timeout → litellm.Timeout (FLEET_DEVIN_BRIDGE_TIMEOUT_S=3, stub sleeps 5)
os.environ["FAKE_DEVIN_MODE"] = "timeout"
expect(litellm.Timeout,
       lambda: h.completion(model="devin/swe-2-max", messages=msgs,
                            litellm_params={}), "timeout")

# health probe: `models list` auth check, no --print, no message burned
os.environ["FAKE_DEVIN_MODE"] = "ok"
reset_log()
r = h.completion(model="devin/swe-2-max", messages=[{"role": "user", "content": "test"}],
                 litellm_params=probe_lp)
calls = log_lines()
assert calls and calls[0].startswith("models list"), f"probe ran {calls}"
assert all("--print" not in c for c in calls), "probe must not burn a message"
assert r.choices[0].message.content == "ok"

# probe fails loudly when the slug is not listed upstream
os.environ["FAKE_MODELS"] = "  glm-5-2   GLM-5.2"
expect(litellm.InternalServerError,
       lambda: h.completion(model="devin/swe-2-max", messages=msgs,
                            litellm_params=probe_lp), "probe-slug-missing")
del os.environ["FAKE_MODELS"]

# async paths
os.environ["FAKE_DEVIN_MODE"] = "ok"
r = asyncio.run(h.acompletion(model="devin/swe-2-max", messages=msgs,
                              litellm_params={}))
assert r.choices[0].message.content.startswith("STUB-REPLY")

async def drain():
    chunks = [c async for c in h.astreaming(model="devin/swe-2-max",
                                          messages=msgs, litellm_params={})]
    return chunks
chunks = asyncio.run(drain())
assert len(chunks) == 1 and chunks[0]["is_finished"] is True
assert chunks[0]["finish_reason"] == "stop"
assert "STUB-REPLY" in chunks[0]["text"]
# fleet-ops#6866: GenericStreamingChunk.usage must be a dict —
# LiteLLM streaming_handler does Usage(**chunk["usage"]) and a Usage
# object there TypeError-500s every proxied stream.
assert isinstance(chunks[0]["usage"], dict), \
    f"chunk usage must be a ChatCompletionUsageBlock dict, got {type(chunks[0]['usage'])}"
assert chunks[0]["usage"]["total_tokens"] > 0

chunks = list(h.streaming(model="devin/swe-2-max", messages=msgs,
                          litellm_params={}))
assert len(chunks) == 1 and chunks[0]["is_finished"] is True
assert isinstance(chunks[0]["usage"], dict), \
    "sync stream chunk usage must also be a dict"

# _flatten: roles labelled, multimodal text extracted, empties dropped
flat = mod._flatten([
    {"role": "system", "content": "sys"},
    {"role": "user", "content": [{"type": "text", "text": "u1"},
                                 {"type": "image", "data": "x"}]},
    {"role": "assistant", "content": "  "},
    {"role": "tool", "content": "t1"},
])
assert "## System" in flat and "## User" in flat and "## Tool" in flat
assert "u1" in flat and "## Assistant" not in flat

# _rate_limit_wait_s parsing (real devin CLI message shapes)
assert mod._rate_limit_wait_s(
    "reached overall message rate limit — resets in 3 minutes") == 180
assert mod._rate_limit_wait_s("HTTP 429 Too Many Requests. Retry-After: 30") == 30
assert mod._rate_limit_wait_s(
    "reached overall message rate limit — resets at 1:16 PM") > 0
assert mod._rate_limit_wait_s("all good") is None

# secret safety: DEVIN_API_KEY value must never reach error text/output
os.environ["FAKE_DEVIN_MODE"] = "fail"
try:
    h.completion(model="devin/swe-2-max", messages=msgs, litellm_params={})
except litellm.InternalServerError as e:
    assert "stub-key" not in str(e), "secret leaked into error"

print("python unit checks ok")
PY
ok "1: adapter unit checks (allowlist, shapes, probe, retry, timeout, stream, flatten, no-secret)"

# --- 2. config registration ----------------------------------------------
python3 - "$cfg" <<'PY' || fail "2: config/litellm-proxy.yaml devin wiring"
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
cpm = (cfg.get("litellm_settings") or {}).get("custom_provider_map") or []
devin = [e for e in cpm if e.get("provider") == "devin"]
assert devin, "custom_provider_map lacks provider: devin"
assert devin[0].get("custom_handler") == "fleet_devin_adapter.devin_windsurf_llm", devin

deploys = cfg.get("model_list") or []
devin_deps = [d for d in deploys
              if str((d.get("litellm_params") or {}).get("model", "")).startswith("devin/")]
slugs = sorted({d["litellm_params"]["model"].split("/", 1)[1] for d in devin_deps})
assert slugs == ["swe-2-max"], f"only current approved devin model may route, got {slugs}"
groups = sorted({d["model_name"] for d in devin_deps})
assert groups == ["judge", "senior", "worker-private"], \
    f"devin seats belong in prose groups only (fleet-ops#7761), got {groups}"
worker_devin = [d["model_name"] for d in deploys
                if d.get("model_name") in ("worker-cheap", "worker-capable")
                and str((d.get("litellm_params") or {}).get("model", "")).startswith("devin/")]
assert not worker_devin, \
    f"devin must be absent from worker groups (fleet-ops#7761), got {worker_devin}"
ids = [d["model_info"]["id"] for d in devin_deps]
assert len(ids) == len(set(ids)), f"deployment ids must be unique: {ids}"
for d in devin_deps:
    lp = d["litellm_params"]
    assert lp.get("api_key") == "os.environ/DEVIN_API_KEY", lp
    assert "api_base" not in lp, f"{d['model_name']} CustomLLM rung must not set api_base"
    mi = d.get("model_info") or {}
    assert mi.get("mode") == "chat", f"{d['model_name']} needs model_info.mode: chat (custom provider not in litellm model map)"
    assert mi.get("id"), f"{d['model_name']} needs model_info.id for deployment pinning"
    assert "prepaid" in (lp.get("tags") or []), d
    assert (lp.get("order") or 99) <= 2, f"{d['model_name']} order must sit in the cheap tier"
for d in deploys:
    m = str((d.get("litellm_params") or {}).get("model", ""))
    for bad in ("glm-5-2", "swe-1-7", "swe-2-high"):
        assert bad not in m, f"forbidden model {bad} deployed in {d['model_name']}"
print("config wiring ok")
PY
ok "2: config/litellm-proxy.yaml registers devin handler + prose-group deployments only"

# --- 3. PYTHONPATH fallback on the existing proxy unit --------------------
[[ -f "$unit" ]] || fail "3: missing $unit"
grep -q 'libexec/fleet-litellm-devin-adapter' "$unit" \
    || fail "3: fleet-litellm-proxy.service PYTHONPATH must include the adapter dir"
grep -q 'libexec/fleet-litellm-prisma-compat' "$unit" \
    || fail "3: prisma-compat PYTHONPATH entry must stay (fleet-ops#4628)"
ok "3: proxy unit PYTHONPATH includes the adapter dir (existing organ, no new unit)"

# --- 4. runbook sibling install (MANIFEST is gone) ------------------------
doc="$repo_root/docs/litellm-postgres-setup.md"
grep -q 'fleet_devin_adapter' "$doc" \
    || fail "4: runbook must document the devin adapter install"
grep -q 'custom_provider_map' "$doc" \
    || fail "4: runbook must document custom_provider_map registration"
grep -Fq '/home/nish/.config/fleet-ops/fleet_devin_adapter.py' "$doc" \
    || fail "4: runbook must name the live sibling path LiteLLM actually loads"
grep -Fq 'ln -sfn /home/nish/workspaces/tooling/fleet-ops-deploy-clone/libexec/fleet-litellm-devin-adapter/fleet_devin_adapter.py' "$doc" \
    || fail "4: runbook must document the deploy-clone symlink (no MANIFEST)"
ok "4: runbook documents sibling symlink + custom_provider_map"

# --- 5. no new machinery (fleet-ops#1250) ------------------------------------
# systemd/devin-issue@.service already exists on main (the Pi provider
# unit). The pin is that THIS change does not add another unit/timer.
if git -C "$repo_root" diff --name-only origin/main -- systemd/ | grep -qi devin; then
    fail "5: adapter must not add a systemd unit/timer (one handler module only)"
fi
extra="$(git -C "$repo_root" ls-files 'libexec/fleet-litellm-devin-adapter/*' | grep -v '/fleet_devin_adapter\.py$' || true)"
[[ -z "$extra" ]] || fail "5: unexpected extra files under the adapter dir: $extra"
ok "5: one handler module, no new unit/timer/organ"

echo "all checks passed"
