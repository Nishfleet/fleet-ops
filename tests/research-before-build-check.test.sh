#!/usr/bin/env bash
# tests/research-before-build-check.test.sh
#
# fleet-ops#517: any PR shipping a new bin/ file must name a last-30-days
# research pass and the existing options that lost (or were adopted).
# fleet-ops#534: the same PR must name which existing tool --help (or
# man / official docs) was read and why it does not already do this.
# This test runs the REAL checker in bin/research-before-build-check
# (not a copy of its predicate).
#
# Phase A: worker.md carries both rules (authors include research: and
#          help-first:).
# Phase B: research: marker accept/reject.
# Phase C: live-search + compared markers required.
# Phase D: drill — fixture PR adding bin/foo with no research: is REJECTED.
# Phase E: a PR that does not add a new bin/ file is SKIP (exit 0).
# Phase F: help-first: marker accept/reject (fleet-ops#534).

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
# Phase A: worker prompt carries both criteria
# ============================================================================
grep -F -- 'research:' "$worker" >/dev/null \
    || fail "worker.md must require a research: line for new bin/ files"
grep -F -- 'help-first:' "$worker" >/dev/null \
    || fail "worker.md must require a help-first: line for new bin/ files"
grep -F -- 'research-before-build-check' "$worker" >/dev/null \
    || fail "worker.md must tell authors to run bin/research-before-build-check"
grep -qE "Hand-building what already exists|hand-building what an existing tool already does" "$worker" \
    || fail "worker.md must name the hand-building reject"
grep -qE "Skipping \`--help\`|Skipping --help" "$worker" \
    || fail "worker.md must name the skipped --help reject"
ok "A: worker.md carries the research-before-build and help-first criteria"

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
help_ok='help-first: ran parallel --help; no seat-aware dispatch flag'
research_ok='research: last30days compared GNU parallel; lost because no seat-aware dispatch'

# ============================================================================
# Phase B: research: marker
# ============================================================================
body=$'## Summary\n- changed\n'"$research_ok"$'\n'"$help_ok"$'\n'
if check "$body" "$bin_ns" >/dev/null; then
    ok "B1: last30days + compared + help-first accepted"
else
    fail "B1: last30days + compared + help-first must accept"
fi

body=$'## Summary\n- changed\nresearch:\n'"$help_ok"$'\n'
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
body=$'## Summary\n- changed\nresearch: official docs compared stow; adopted GNU stow for the install path\nhelp-first: ran stow --help; missing a fleet-scoped RAM governor\n'
if check "$body" "$bin_ns" >/dev/null; then
    ok "C1: official docs + adopted + help-first accepted"
else
    fail "C1: official docs + adopted + help-first must accept"
fi

body=$'## Summary\n- changed\nresearch: live search checked xargs -P; rejected, no RAM governor\nhelp-first: ran xargs --help; no RAM governor flag\n'
if check "$body" "$bin_ns" >/dev/null; then
    ok "C2: live search + checked/rejected + help-first accepted"
else
    fail "C2: live search + checked must accept"
fi

body=$'## Summary\n- changed\nresearch: last30days nothing else\n'"$help_ok"$'\n'
if check "$body" "$bin_ns" >/dev/null 2>&1; then
    fail "C3: last30days without compared/checked/adopted/rejected must reject"
fi
ok "C3: live-search without alternatives marker rejected"

body=$'## Summary\n- changed\nresearch: compared GNU parallel; lost on seats\n'"$help_ok"$'\n'
if check "$body" "$bin_ns" >/dev/null 2>&1; then
    fail "C4: compared without a live-search marker must reject"
fi
ok "C4: alternatives without live-search marker rejected"

body=$'## Summary\n- changed\nresearch: n/a\n'"$help_ok"$'\n'
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

# ============================================================================
# Phase F: help-first: (fleet-ops#534)
# ============================================================================
body=$'## Summary\n- changed\n'"$research_ok"$'\n'
if check "$body" "$bin_ns" >/dev/null 2>&1; then
    fail "F1: research: without help-first: must reject"
fi
ok "F1: missing help-first: rejected"

body=$'## Summary\n- changed\n'"$research_ok"$'\nhelp-first:\n'
if check "$body" "$bin_ns" >/dev/null 2>&1; then
    fail "F2: empty help-first: value must reject"
fi
ok "F2: empty help-first: value rejected"

body=$'## Summary\n- changed\n'"$research_ok"$'\nhelp-first: I thought about restic; no flag jumped out\n'
if check "$body" "$bin_ns" >/dev/null 2>&1; then
    fail "F3: help-first: without --help / man / official docs must reject"
fi
ok "F3: help-first: without STEP 0 marker rejected"

body=$'## Summary\n- changed\n'"$research_ok"$'\nhelp-first: ran restic forget --help\n'
if check "$body" "$bin_ns" >/dev/null 2>&1; then
    fail "F4: help-first: with --help but no why-unusable marker must reject"
fi
ok "F4: help-first: without why-unusable marker rejected"

body=$'## Summary\n- changed\n'"$research_ok"$'\nhelp-first: ran man restic-forget; missing a fleet-scoped prune window\n'
if check "$body" "$bin_ns" >/dev/null; then
    ok "F5: man + missing accepted"
else
    fail "F5: man + missing must accept"
fi

body=$'## Summary\n- changed\n'"$research_ok"$'\nhelp-first: read official docs for systemd Restart=; cannot cap by seat without a governor\n'
if check "$body" "$bin_ns" >/dev/null; then
    ok "F6: official docs + cannot accepted"
else
    fail "F6: official docs + cannot must accept"
fi

research_only_fixture='## Summary
- Adds a new tool at bin/foo

research: last30days compared GNU parallel; lost because no seat-aware dispatch

## Test plan
- [x] `bash tests/foo.test.sh`

Closes #0'
if check "$research_only_fixture" "$bin_ns" >/dev/null 2>&1; then
    fail "F7: drill fixture (new bin/ + research: + no help-first:) MUST be rejected — help-first gate is broken"
fi
ok "F7: drill fixture (new bin/ with research: but no help-first:) correctly rejected"

echo "all phases passed"
