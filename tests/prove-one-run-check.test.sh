#!/usr/bin/env bash
# tests/prove-one-run-check.test.sh
#
# fleet-ops#378: any PR shipping a new unit/timer/workflow must link proof
# of one real end-to-end run. This test runs the REAL checker in
# bin/prove-one-run-check (not a copy of its predicate).
#
# Phase A: worker.md carries the rule (authors include run-proof).
# Phase B: run-proof: marker accept/reject.
# Phase C: Verification: run-cue accept/reject.
# Phase D: drill — fixture PR adding a timer with no run-proof is REJECTED.
# Phase E: a PR that does not add machinery is SKIP (exit 0).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/prove-one-run-check"
worker="$repo_root/prompts/worker.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "missing or not executable: $bin"
[[ -f "$worker" ]] || fail "missing: $worker"

scratch="$(mktemp -d -t prove-one-run.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# ============================================================================
# Phase A: worker prompt carries the criterion
# ============================================================================
grep -F -- 'run-proof:' "$worker" >/dev/null \
    || fail "worker.md must require a run-proof: line for new units/timers/workflows"
grep -qE "Armed without ran|armed without ran" "$worker" \
    || fail "worker.md must name the 'armed without ran' reject"
ok "A: worker.md carries the prove-one-run criterion"

# ============================================================================
# Helpers
# ============================================================================
check() {
    local body="$1" status="$2"
    printf '%s\n' "$body" >"$scratch/body.md"
    printf '%s\n' "$status" >"$scratch/ns.txt"
    "$bin" --body "$scratch/body.md" --name-status "$scratch/ns.txt"
}

timer_ns=$'A\tsystemd/foo.timer'

# ============================================================================
# Phase B: run-proof: marker
# ============================================================================
body=$'## Summary\n- changed\nrun-proof: journal "fleet-blind-audit.service" lines below\n'
if check "$body" "$timer_ns" >/dev/null; then
    ok "B1: run-proof: journal accepted"
else
    fail "B1: run-proof: journal must accept"
fi

body=$'## Summary\n- changed\nrun-proof: url https://github.com/Nishfleet/fleet-ops/actions/runs/12345\n'
if check "$body" "$timer_ns" >/dev/null; then
    ok "B2: run-proof: url accepted"
else
    fail "B2: run-proof: url must accept"
fi

body=$'## Summary\n- changed\nrun-proof:\n'
if check "$body" "$timer_ns" >/dev/null 2>&1; then
    fail "B3: empty run-proof: value must reject"
fi
ok "B3: empty run-proof: value rejected"

body=$'## Summary\n- I changed some things\n## Test plan\n- [x] one\n'
if check "$body" "$timer_ns" >/dev/null 2>&1; then
    fail "B4: markerless body must reject when new machinery is present"
fi
ok "B4: markerless body rejected for new timer"

# ============================================================================
# Phase C: Verification: detector
# ============================================================================
body=$'## Summary\n- changed\n\n## Verification:\n- journalctl -u fleet-heartbeat.service --since "5 min ago" — no errors.\n'
if check "$body" "$timer_ns" >/dev/null; then
    ok "C1: Verification: + journalctl accepted"
else
    fail "C1: Verification: with journalctl cue must accept"
fi

body=$'## Summary\n- changed\n\nVerification: `systemctl --user is-active fleet-blind-audit.timer` returned `active`.\n'
if check "$body" "$timer_ns" >/dev/null; then
    ok "C2: inline Verification: + systemctl accepted"
else
    fail "C2: inline Verification: with systemctl cue must accept"
fi

body=$'## Summary\n- changed\n\n## Verification:\n- I did the thing.\n'
if check "$body" "$timer_ns" >/dev/null 2>&1; then
    fail "C3: Verification: with no run-cue must reject"
fi
ok "C3: Verification: without run-cue rejected"

body=$'## Summary\n- changed\n\n## Verification\n- journalctl -u fleet-heartbeat.service --since "5 min ago" — no errors.\n'
if check "$body" "$timer_ns" >/dev/null; then
    ok "C4: heading form (no colon) + journalctl accepted (fleet-ops#728)"
else
    fail "C4: heading form (no colon) with journalctl cue must accept"
fi

body=$'## Summary\n- changed\n\n## Verification\n- I did the thing.\n'
if check "$body" "$timer_ns" >/dev/null 2>&1; then
    fail "C5: heading form (no colon) without run-cue must reject"
fi
ok "C5: heading form (no colon) without run-cue rejected"

# ============================================================================
# Phase D: drill — fixture PR adding a timer with no run-proof
# ============================================================================
fixture='## Summary
- Adds a new timer at systemd/foo.timer

## Test plan
- [x] `systemd-analyze verify systemd/foo.timer`

Closes #0'
if check "$fixture" "$timer_ns" >/dev/null 2>&1; then
    fail "D: drill fixture (timer+no run-proof) MUST be rejected — gate is broken"
fi
ok "D: drill fixture (timer with no run-proof) correctly rejected"

# workflow add with no proof also rejects
if check "$fixture" $'A\t.github/workflows/new.yml' >/dev/null 2>&1; then
    fail "D2: new workflow with no run-proof must reject"
fi
ok "D2: new workflow with no run-proof rejected"

# ============================================================================
# Phase E: no new machinery -> SKIP (docs-only or existing-file edit)
# ============================================================================
out="$(check "$fixture" $'M\tsystemd/fleet-blind-audit.timer' )"
printf '%s\n' "$out" | grep -q '^SKIP:' \
    || fail "E1: modifying an existing timer must SKIP (not a new unit), got: $out"
ok "E1: existing-timer edit is SKIP (gate is for NEW machinery)"

out="$(check "$fixture" $'M\tbin/fleet-heartbeat-tier1' )"
printf '%s\n' "$out" | grep -q '^SKIP:' \
    || fail "E2: bin-only edit must SKIP, got: $out"
ok "E2: bin-only edit is SKIP"

out="$(check "$fixture" $'A\tsystemd/foo.service.d/10-x.conf' )"
printf '%s\n' "$out" | grep -q '^SKIP:' \
    || fail "E3: drop-in is not a new unit, got: $out"
ok "E3: drop-in add is SKIP"

echo "all phases passed"
