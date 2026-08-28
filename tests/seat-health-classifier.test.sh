#!/usr/bin/env bash
# tests/seat-health-classifier.test.sh
#
# fleet-ops#1466: closure condition for the seat-health.ts 200/empty-body
# false-healthy gap. The out-of-repo extension at
# ~/.pi/agent/extensions/seat-health.ts (or FLEET_SEAT_HEALTH_TS) marks an
# HTTP-200 response with an empty body as `health_class: "healthy"`, and
# `classifyCliOutput("", 0)` as `health_class: "healthy"`. A seat returning
# `rc=0` with no diagnosis block is HTTP-healthy but functionally dead for an
# agentic packet (the tools=0 / no-tools class). The in-repo dispatcher fix
# (bin/stop-escalation-dispatch, fleet-ops#1354 / PR #1467) benches on
# `rc=0`/no-block so the loop is bounded, but the per-seat ledger still
# records the seat as `healthy` because the classifier never learns.
#
# This test is the closure condition. It imports the live extension, calls
# the two classifier functions with the inputs the issue's test plan names,
# and asserts the results. Today the test fails (the gap is open); once the
# classifier is fixed in seat-health.ts, the test passes and #1466 is
# closeable. The PR body for the fix is the close PR; this test is the
# evidence.
#
# Environment seams:
#   FLEET_SEAT_HEALTH_TS    absolute path to seat-health.ts. Default:
#                           $HOME/.pi/agent/extensions/seat-health.ts
#   FLEET_SEAT_HEALTH_NODE  node binary. Default: node (must be >= 22.6
#                           for --experimental-strip-types)
#
# CI safety: if the extension is not installed, the test skips (exit 0 with
# a SKIP line). The gap is the issue, not the test; the test only makes
# sense where the extension is wired. Hosted by tests/ci-standards-audit
# (already in P14) so it runs in CI as a no-op and on the VPS as the
# real closure check.

set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
skip() { echo "SKIP: $*"; exit 0; }

EXT_PATH="${FLEET_SEAT_HEALTH_TS:-$HOME/.pi/agent/extensions/seat-health.ts}"
if [[ ! -f "$EXT_PATH" ]]; then
    skip "seat-health.ts not installed at $EXT_PATH — install the extension to run this gate (fleet-ops#1466)"
fi

NODE_BIN="${FLEET_SEAT_HEALTH_NODE:-node}"
if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
    fail "node missing ($NODE_BIN); need >= 22.6 for --experimental-strip-types"
fi

# Confirm node is new enough. 22.6 ships --experimental-strip-types. Parse
# major.minor and bail loudly if older, instead of letting node emit a usage
# error that masquerades as a test failure.
node_major=$("$NODE_BIN" -e 'console.log(Number.parseInt(process.versions.node.split(".")[0], 10))')
node_minor=$("$NODE_BIN" -e 'console.log(Number.parseInt(process.versions.node.split(".")[1], 10))')
if [[ "$node_major" -lt 22 ]] || { [[ "$node_major" -eq 22 ]] && [[ "$node_minor" -lt 6 ]]; }; then
    fail "node $node_major.$node_minor is too old; need >= 22.6 for --experimental-strip-types (fleet-ops#1466)"
fi

# Run a node --experimental-strip-types snippet that calls a classifier
# function and returns a JSON {ok, class, error, expected} payload on the
# last line. We read the last line and let the rest surface verbatim on
# failure. The last-line JSON contract keeps the test self-contained —
# no temp files, no jq dependency on the inner payload.
#
# $1 = invariant name (for the OK line)
# $2 = function name
# $3 = function args as a JSON array (e.g. [200, ""])
# $4 = expected health_class (string)
# $5 = expected to FAIL today? "non-healthy" if 2xx+empty / empty CLI,
#      "healthy" if real content (locks the OTHER direction so a fix
#      cannot flip genuine success to transient_fault)
run_invariant() {
    local name="$1" fn="$2" args_json="$3" want_class="$4" direction="$5"
    local last
    last=$("$NODE_BIN" \
        --experimental-strip-types --no-warnings=ExperimentalWarning \
        --input-type=module -e "
import { ${fn} } from ${EXT_PATH@Q};
const want = ${want_class@Q};
const args = ${args_json};
const r = ${fn}(...args);
const result = {
    ok: r.health_class === want,
    class: r.health_class,
    expected: want,
    full: JSON.stringify(r),
};
console.log('RESULT_JSON:' + JSON.stringify(result));
" 2>&1 | tail -n1)
    # Strip the RESULT_JSON: prefix the snippet emits as the last line.
    if [[ "$last" != RESULT_JSON:* ]]; then
        fail "${name}: node output did not contain a RESULT_JSON line (got: $last)"
    fi
    local payload="${last#RESULT_JSON:}"
    local ok_flag
    ok_flag=$(node -e "const p = JSON.parse(process.argv[1]); console.log(p.ok ? 'yes' : 'no')" "$payload" 2>/dev/null || echo "no")
    if [[ "$ok_flag" != "yes" ]]; then
        local got_class expected
        got_class=$(node -e "const p = JSON.parse(process.argv[1]); console.log(p.class)" "$payload" 2>/dev/null || echo "?")
        expected=$(node -e "const p = JSON.parse(process.argv[1]); console.log(p.expected)" "$payload" 2>/dev/null || echo "?")
        local full
        full=$(node -e "const p = JSON.parse(process.argv[1]); console.log(p.full)" "$payload" 2>/dev/null || echo "?")
        fail "${name}: classifier returned health_class='${got_class}', expected '${expected}' (${direction}). full=${full}. This is the fleet-ops#1466 gap: 200+empty / empty CLI is being marked healthy."
    fi
    ok "${name} (${direction})"
}

# Invariant 1 (issue test plan): 2xx + empty body classifies as
# transient_fault (or a new empty_body mode), NOT healthy. The current
# classifier signature is `classifyHttpStatus(status)` with no body param.
# The proposed fix extends it to take an optional body. Today the extra arg
# is ignored at runtime, so 200 returns healthy (this assertion fails). Once
# the function takes the body, 200+empty returns a non-healthy class (passes).
run_invariant \
    "inv1: 2xx + empty body classifies as transient_fault" \
    "classifyHttpStatus" \
    "[200, '']" \
    "transient_fault" \
    "non-healthy direction (200+empty must NOT be healthy)"

# Invariant 2 (issue test plan): classifyCliOutput('', 0) returns
# transient_fault, not healthy. classifyCliOutput is the sibling path the
# devin/cursor CLI spawn uses; it currently collapses any rc=0 to healthy
# regardless of body length. The fix must yield a non-healthy class for
# empty text. Today returns healthy (this assertion fails).
run_invariant \
    "inv2: classifyCliOutput('', 0) returns transient_fault" \
    "classifyCliOutput" \
    '["", 0]' \
    "transient_fault" \
    "non-healthy direction (empty CLI must NOT be healthy)"

# Invariant 3 (issue test plan): 2xx + real content still classifies as
# healthy (no false positive on genuine success). Locks the OTHER direction
# so a fix that over-corrects — flipping 200 to transient_fault always —
# would be caught. The body shape is a minimal "real content" response with
# one tool_use content block.
real_body_json=$(node -e 'process.stdout.write(JSON.stringify(JSON.stringify({type:"message",model:"glm-5-2",content:[{type:"tool_use",id:"toolu_1",name:"read",input:{path:"x"}}]})))')
run_invariant \
    "inv3: 2xx + real content still classifies as healthy" \
    "classifyHttpStatus" \
    "[200, ${real_body_json}]" \
    "healthy" \
    "healthy direction (real content must stay healthy)"

ok "fleet-ops#1466 closure: 200/empty-body and empty-CLI now classify as non-healthy, real content still healthy"
