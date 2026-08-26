#!/usr/bin/env bash
# tests/research-before-build-check.test.sh
#
# fleet-ops#517: any PR shipping a new bin/ file must name a last-30-days
# research pass and the existing options that lost (or were adopted).
# This test runs the REAL checker in bin/research-before-build-check
# (not a copy of its predicate).
#
# Phase A: worker.md carries the rule (authors include research:).
# Phase B: research: marker accept/reject.
# Phase C: live-search + compared markers required.
# Phase D: drill — fixture PR adding bin/foo with no research: is REJECTED.
# Phase E: a PR that does not add a new bin/ file is SKIP (exit 0).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/research-before-build-check"
worker="$repo_root/prompts/worker.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "missing or not executable: $bin"
[[ -f "$worker" ]] || fail "missing: $worker"

scratch="$(mktemp -d -t research-before-build.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# ============================================================================
# Phase A: worker prompt carries the criterion
# ============================================================================
grep -F -- 'research:' "$worker" >/dev/null \
    || fail "worker.md must require a research: line for new bin/ files"
grep -F -- 'research-before-build-check' "$worker" >/dev/null \
    || fail "worker.md must tell authors to run bin/research-before-build-check"
grep -qE "Hand-building what already exists|hand-building what an existing tool already does" "$worker" \
    || fail "worker.md must name the hand-building reject"
ok "A: worker.md carries the research-before-build criterion"

# ============================================================================
# Helpers
# ============================================================================
check() {
    local body="$1" status="$2"
    printf '%s\n' "$body" >"$scratch/body.md"
    printf '%s\n' "$status" >"$scratch/ns.txt"
    "$bin" --body "$scratch/body.md" --name-status "$scratch/ns.txt"
}

bin_ns=$'A\tbin/foo'

# ============================================================================
# Phase B: research: marker
# ============================================================================
body=$'## Summary\n- changed\nresearch: last30days compared GNU parallel; lost because no seat-aware dispatch\n'
if check "$body" "$bin_ns" >/dev/null; then
    ok "B1: last30days + compared accepted"
else
    fail "B1: last30days + compared must accept"
fi

body=$'## Summary\n- changed\nresearch:\n'
if check "$body" "$bin_ns" >/dev/null 2>&1; then
    fail "B2: empty research: value must reject"
fi
ok "B2: empty research: value rejected"

body=$'## Summary\n- I changed some things\n## Test plan\n- [x] one\n'
if check "$body" "$bin_ns" >/dev/null 2>&1; then
    fail "B3: markerless body must reject when a new bin/ file is present"
fi
ok "B3: markerless body rejected for new bin/ file"

# ============================================================================
# Phase C: live-search + compared markers
# ============================================================================
body=$'## Summary\n- changed\nresearch: official docs compared stow; adopted GNU stow for the install path\n'
if check "$body" "$bin_ns" >/dev/null; then
    ok "C1: official docs + adopted accepted"
else
    fail "C1: official docs + adopted must accept"
fi

body=$'## Summary\n- changed\nresearch: live search checked xargs -P; rejected, no RAM governor\n'
if check "$body" "$bin_ns" >/dev/null; then
    ok "C2: live search + checked/rejected accepted"
else
    fail "C2: live search + checked must accept"
fi

body=$'## Summary\n- changed\nresearch: last30days nothing else\n'
if check "$body" "$bin_ns" >/dev/null 2>&1; then
    fail "C3: last30days without compared/checked/adopted/rejected must reject"
fi
ok "C3: live-search without alternatives marker rejected"

body=$'## Summary\n- changed\nresearch: compared GNU parallel; lost on seats\n'
if check "$body" "$bin_ns" >/dev/null 2>&1; then
    fail "C4: compared without a live-search marker must reject"
fi
ok "C4: alternatives without live-search marker rejected"

body=$'## Summary\n- changed\nresearch: n/a\n'
if check "$body" "$bin_ns" >/dev/null 2>&1; then
    fail "C5: research: n/a must reject"
fi
ok "C5: research: n/a rejected"

# ============================================================================
# Phase D: drill — fixture PR adding bin/foo with no research:
# ============================================================================
fixture='## Summary
- Adds a new tool at bin/foo

## Test plan
- [x] `bash tests/foo.test.sh`

Closes #0'
if check "$fixture" "$bin_ns" >/dev/null 2>&1; then
    fail "D: drill fixture (new bin/ + no research:) MUST be rejected — gate is broken"
fi
ok "D: drill fixture (new bin/ with no research:) correctly rejected"

# ============================================================================
# Phase E: no new bin/ file -> SKIP
# ============================================================================
out="$(check "$fixture" $'M\tbin/fleet-heartbeat-tier1' )"
printf '%s\n' "$out" | grep -q '^SKIP:' \
    || fail "E1: modifying an existing bin/ file must SKIP, got: $out"
ok "E1: existing-bin edit is SKIP (gate is for NEW bin/ files)"

out="$(check "$fixture" $'A\tsystemd/foo.timer' )"
printf '%s\n' "$out" | grep -q '^SKIP:' \
    || fail "E2: new timer without a new bin/ file must SKIP, got: $out"
ok "E2: timer-only add is SKIP"

out="$(check "$fixture" $'R100\tbin/old\tbin/new' )"
printf '%s\n' "$out" | grep -q '^SKIP:' \
    || fail "E3: rename inside bin/ is not a new build, got: $out"
ok "E3: bin/ rename is SKIP"

echo "all phases passed"
