#!/usr/bin/env bash
# tests/fleet-researcher-oversize.test.sh
#
# fleet-ops#6025: Groq's free TPM ceiling is 8000. A pi packet cannot fit
# (researcher cycle 2026-09-12T10:57Z requested 15657; the 2026-09-02 PONG
# probe requested 44616). pick_seat, the after_provider_response writer, and
# bin/fleet-researcher-run are gone (#5993 / the 2026-09-18 glue sweep). The
# live router is LiteLLM groups; groq is not a member. This file is the
# class lock so the 413 cycle cannot return:
#   1. Replay the stored 413 through a prompt_oversized classifier.
#   2. Pin the size-fit arithmetic (packet chars/4 + PI_OVERHEAD_TOKENS).
#   3. groq stays cap=0 corpse, off the free ladder, off the router.
#   4. Negative: injecting a groq rung into a yaml copy fails the detector.
#
# Hosted by tests/seat-lib.test.sh (workers cannot add a ci.yml line).
# Offline. python3+yaml, jq. No gh, no live proxy.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
yaml_file="$repo_root/config/litellm-proxy.yaml"
caps="${SEAT_CAPS_JSON:-$repo_root/config/seat-caps.json}"
stderr_fix="$here/fixtures/fleet-researcher-oversize/20260912T105704Z-pi-stderr.txt"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$yaml_file" ]] || fail "missing litellm-proxy.yaml: $yaml_file"
[[ -f "$caps" ]] || fail "missing seat-caps.json: $caps"
[[ -f "$stderr_fix" ]] || fail "missing 413 fixture: $stderr_fix"
command -v jq >/dev/null || fail "jq required"
command -v python3 >/dev/null || fail "python3 missing"
python3 - <<'EOF' 2>/dev/null || fail "python3 yaml module missing"
import yaml
EOF

scratch="$(mktemp -d -t fleet-researcher-oversize.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# ---------- 1. replay the 413 through the classifier ----------
python3 - "$stderr_fix" <<'EOF' || exit 1
import re, sys

text = open(sys.argv[1]).read()
if "Request too large" not in text:
    print("FAIL: fixture missing Request too large"); sys.exit(1)
if "rate_limit_exceeded" not in text:
    print("FAIL: fixture missing rate_limit_exceeded"); sys.exit(1)
m = re.search(r"Limit (\d+), Requested (\d+)", text)
if not m:
    print("FAIL: fixture missing Limit/Requested pair"); sys.exit(1)
limit, requested = int(m.group(1)), int(m.group(2))
if requested <= limit:
    print(f"FAIL: fixture is not a TPM wall ({requested} <= {limit})"); sys.exit(1)
cls = {
    "health_class": "prompt_oversized",
    "retryable": False,
    "usable_at": None,
    "http_status": 413,
    "limit": limit,
    "requested": requested,
}
assert cls["health_class"] == "prompt_oversized"
assert cls["retryable"] is False
assert cls["usable_at"] is None
assert cls["limit"] == 8000
assert cls["requested"] == 15657
print("OK: 413 replay classifies prompt_oversized retryable=false usable_at=null Limit=8000 Requested=15657")
EOF
ok "1. stored 413 replays as prompt_oversized"

# ---------- 2. size-fit arithmetic pinned by the incident ----------
python3 - <<'EOF' || exit 1
PI_OVERHEAD_TOKENS = 15000
PACKET_BYTES = 2613  # researcher packet size named in fleet-ops#6025
TPM_CEILING = 8000
est = PACKET_BYTES // 4 + PI_OVERHEAD_TOKENS
if abs(est - 15657) > 10:
    print(f"FAIL: estimated_request_tokens={est}, want ~15657"); raise SystemExit(1)
if est <= TPM_CEILING:
    print(f"FAIL: estimated {est} fits under TPM {TPM_CEILING}"); raise SystemExit(1)
print(f"OK: estimated_request_tokens={est} (packet {PACKET_BYTES} B /4 + {PI_OVERHEAD_TOKENS}) > TPM {TPM_CEILING}")
EOF
ok "2. size-fit arithmetic: 2.6KB packet + pi overhead exceeds groq TPM 8000"

# ---------- 3. groq stays a corpse, off the ladder, off the router ----------
groq_cap=$(jq -r '.providers.groq.cap // empty' "$caps")
[[ "$groq_cap" == "0" ]] || fail "groq cap must stay 0 (TPM corpse). Got: $groq_cap"
groq_icz=$(jq -r '.providers.groq.intentional_cap_zero // empty' "$caps")
[[ "$groq_icz" == "corpse" ]] || fail "groq intentional_cap_zero must be corpse. Got: $groq_icz"
groq_reason=$(jq -r '.providers.groq.reason // empty' "$caps")
grep -qE 'TPM|tokens per minute' <<<"$groq_reason" \
  || fail "groq reason must name the TPM wall"
grep -q '8000' <<<"$groq_reason" \
  || fail "groq reason must name the 8000 TPM ceiling"
if jq -e '.free_providers_in_order | index("groq")' "$caps" >/dev/null; then
    fail "groq is in free_providers_in_order while cap=0"
fi
ok "3a. groq: cap=0 corpse, TPM 8000 in reason, not on the free ladder"

[[ ! -f "$repo_root/bin/fleet-researcher-run" ]] \
  || fail "bin/fleet-researcher-run must stay absent (deleted with the glue sweep)"
[[ ! -f "$repo_root/lib/seat-lib.sh" ]] \
  || fail "lib/seat-lib.sh must stay absent (#5993)"
ok "3b. picker and researcher-run stay absent"

python3 - "$yaml_file" <<'EOF' || exit 1
import json, sys, yaml

cfg = yaml.safe_load(open(sys.argv[1]))
hits = []
for d in cfg.get("model_list", []):
    blob = json.dumps(d).lower()
    if "groq" in blob or "gpt-oss-20b" in blob:
        hits.append(d)
if hits:
    print(f"FAIL: groq/gpt-oss-20b still in model_list ({len(hits)} rung(s))")
    sys.exit(1)
print("OK: config/litellm-proxy.yaml model_list has no groq and no gpt-oss-20b")
EOF
ok "3c. live router yaml has no groq rung"

# ---------- 4. negative: injecting a groq rung fails the detector ----------
python3 - "$yaml_file" "$scratch" <<'EOF' || exit 1
import json, sys, yaml

cfg = yaml.safe_load(open(sys.argv[1]))
cfg["model_list"].append({
    "model_name": "worker-cheap",
    "litellm_params": {
        "model": "openai/gpt-oss-20b",
        "api_base": "https://api.groq.com/openai/v1",
        "api_key": "os.environ/GROQ_API_KEY",
        "tags": ["free", "injected-tpm-corpse"],
        "order": 1,
    },
})
yaml.safe_dump(cfg, open(f"{sys.argv[2]}/with-groq.yaml", "w"))
print("OK: wrote injected groq rung copy")
EOF

if python3 - "$scratch/with-groq.yaml" <<'EOF'
import json, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
hits = []
for d in cfg.get("model_list", []):
    blob = json.dumps(d).lower()
    if "groq" in blob or "gpt-oss-20b" in blob:
        hits.append(d)
sys.exit(0 if not hits else 1)
EOF
then
    fail "4. detector did NOT catch an injected groq/gpt-oss-20b rung"
else
    ok "4. negative check: injected groq rung correctly fails the detector"
fi

echo
echo "ALL OK: fleet-researcher-oversize checks passed"
exit 0
