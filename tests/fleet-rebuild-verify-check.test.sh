#!/usr/bin/env bash
# tests/fleet-rebuild-verify-check.test.sh
#
# fleet-ops#3191: a PR touching the bare-metal rebuild manifest, the
# unit-masking config, or the rebuild scripts/runbook/test must carry a
# VERIFY line. This test runs the REAL checker in
# bin/fleet-rebuild-verify-check (not a copy of its predicate).
#
# Phase A: worker.md carries the rule.
# Phase B: run-proof: marker accept/reject on a manifest edit.
# Phase C: Verification: run-cue accept/reject on a manifest edit.
# Phase D: drill — fixture PR editing the manifest with no proof is REJECTED.
# Phase E: a PR that does not touch a rebuild/masking path is SKIP (exit 0).
# Phase F: every declared trigger path fires on a modify (M), not just add.
# Phase G: the #3141 shape — a manifest edit + a real systemctl cue ACCEPTS.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-rebuild-verify-check"
worker="$repo_root/prompts/worker.md"
manifest="$repo_root/config/bare-metal-rebuild-manifest.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "missing or not executable: $bin"
[[ -f "$worker" ]] || fail "missing: $worker"
[[ -f "$manifest" ]] || fail "missing: $manifest"

scratch="$(mktemp -d -t rebuild-verify.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# ============================================================================
# Phase A: worker prompt carries the criterion
# ============================================================================
grep -F -- 'fleet-rebuild-verify-check' "$worker" >/dev/null \
    || fail "worker.md must instruct running bin/fleet-rebuild-verify-check"
grep -qi -- 'rebuild/masking\|rebuild or masking\|unit masking or rebuild' "$worker" \
    || fail "worker.md must name the rebuild/masking path class"
ok "A: worker.md carries the rebuild-verify criterion"

# ============================================================================
# Helpers
# ============================================================================
check() {
    local body="$1" status="$2"
    printf '%s\n' "$body" >"$scratch/body.md"
    printf '%s\n' "$status" >"$scratch/ns.txt"
    "$bin" --body "$scratch/body.md" --name-status "$scratch/ns.txt"
}

manifest_ns=$'M\tconfig/bare-metal-rebuild-manifest.json'

# ============================================================================
# Phase B: run-proof: marker
# ============================================================================
body=$'## Summary\n- removed wait-online from masked_units\nrun-proof: systemctl is-enabled systemd-networkd-wait-online.service -> enabled-runtime\n'
if check "$body" "$manifest_ns" >/dev/null; then
    ok "B1: run-proof: systemctl accepted"
else
    fail "B1: run-proof: systemctl must accept"
fi

body=$'## Summary\n- changed\nrun-proof:\n'
if check "$body" "$manifest_ns" >/dev/null 2>&1; then
    fail "B2: empty run-proof: value must reject"
fi
ok "B2: empty run-proof: value rejected"

body=$'## Summary\n- I changed some things\n## Test plan\n- [x] one\n'
if check "$body" "$manifest_ns" >/dev/null 2>&1; then
    fail "B3: markerless body must reject when a rebuild/masking path is touched"
fi
ok "B3: markerless body rejected for manifest edit"

# ============================================================================
# Phase C: Verification: detector
# ============================================================================
body=$'## Summary\n- changed\n\n## Verification:\n- `systemctl is-enabled systemd-networkd-wait-online.service` returned `enabled-runtime` (not masked).\n'
if check "$body" "$manifest_ns" >/dev/null; then
    ok "C1: Verification: + systemctl accepted"
else
    fail "C1: Verification: with systemctl cue must accept"
fi

body=$'## Summary\n- changed\n\n## Verification:\n- I did the thing.\n'
if check "$body" "$manifest_ns" >/dev/null 2>&1; then
    fail "C2: Verification: with no run-cue must reject"
fi
ok "C2: Verification: without run-cue rejected"

body=$'## Summary\n- changed\n\n## Verification\n- journalctl -u systemd-networkd-wait-online.service --since "5 min ago" — no errors.\n'
if check "$body" "$manifest_ns" >/dev/null; then
    ok "C3: heading form (no colon) + journalctl accepted"
else
    fail "C3: heading form (no colon) with journalctl cue must accept"
fi

# ============================================================================
# Phase D: drill — fixture PR editing the manifest with no proof
# ============================================================================
fixture='## Summary
- Reverts the wait-online mask and guards it out of masked_units.

## Test plan
- [x] `jq .config/bare-metal-rebuild-manifest.json`

Closes #0'
if check "$fixture" "$manifest_ns" >/dev/null 2>&1; then
    fail "D: drill fixture (manifest edit + no proof) MUST be rejected — gate is broken"
fi
ok "D: drill fixture (manifest edit with no proof) correctly rejected"

# ============================================================================
# Phase E: no rebuild/masking path -> SKIP
# ============================================================================
out="$(check "$fixture" $'M\tbin/fleet-heartbeat-tier1')"
printf '%s\n' "$out" | grep -q '^SKIP:' \
    || fail "E1: bin-only edit must SKIP, got: $out"
ok "E1: bin-only edit is SKIP"

out="$(check "$fixture" $'A\tsystemd/foo.timer')"
printf '%s\n' "$out" | grep -q '^SKIP:' \
    || fail "E2: a new timer (no rebuild path) must SKIP here, got: $out"
ok "E2: new-timer-only edit is SKIP (prove-one-run-check owns that class)"

out="$(check "$fixture" $'M\tREADME.md')"
printf '%s\n' "$out" | grep -q '^SKIP:' \
    || fail "E3: README edit must SKIP, got: $out"
ok "E3: README edit is SKIP"

# ============================================================================
# Phase F: every declared trigger path fires on a modify (M)
# ============================================================================
for path in \
    'config/bare-metal-rebuild-manifest.json' \
    'bin/fleet-bare-metal-rebuild' \
    'bin/fleet-bare-metal-rebuild-drill' \
    'lib/bare-metal-masked-units.sh' \
    'docs/bare-metal-rebuild.md' \
    'tests/fleet-bare-metal-rebuild.test.sh'
do
    if check "$fixture" "M	$path" >/dev/null 2>&1; then
        fail "F: $path must reject with no proof"
    fi
    ok "F: $path edit with no proof rejected"
done

# A delete of a rebuild path also fires (touching includes removal).
if check "$fixture" $'D\tlib/bare-metal-masked-units.sh' >/dev/null 2>&1; then
    fail "F2: delete of a rebuild path must reject with no proof"
fi
ok "F2: delete of a rebuild path with no proof rejected"

# A rename into a rebuild path fires on the new path.
if check "$fixture" $'R100\tlib/old.sh\tlib/bare-metal-masked-units.sh' >/dev/null 2>&1; then
    fail "F3: rename into a rebuild path must reject with no proof"
fi
ok "F3: rename into a rebuild path with no proof rejected"

# ============================================================================
# Phase G: the #3141 shape — manifest edit + a real systemctl cue ACCEPTS
# ============================================================================
body3141='## Summary
- Revert the wait-online mask and guard it out of masked_units.

## Verification
- `systemctl is-enabled systemd-networkd-wait-online.service` -> `enabled-runtime` (not masked).
- `jq -r ".masked_units.units[].name" config/bare-metal-rebuild-manifest.json` lists only `openipmi.service` (wait-online absent).

Closes #0'
if check "$body3141" "$manifest_ns" >/dev/null; then
    ok "G: #3141 shape (manifest edit + live systemctl/jq cue) accepted"
else
    fail "G: #3141 shape with a real run cue must accept"
fi

echo "all phases passed"
