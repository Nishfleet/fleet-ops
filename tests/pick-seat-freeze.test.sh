#!/usr/bin/env bash
# tests/pick-seat-freeze.test.sh
#
# fleet-ops#4263 spec line "required: freeze first": the P3b deletion PR
# retires lib/seat-lib.sh and every pick_seat caller. The first attempt
# (PR #4422) died because main kept gaining NEW CI-pinned pick_seat callers
# while the PR sat conflicting for three days. This gate freezes the caller
# set for the life of that deletion PR:
#
#   * any file under bin/ lib/ tests/ that NEWLY matches the retired-routing
#     signature fails P14;
#   * any manifest file whose match count grows past its frozen value fails;
#   * deletions are allowed — the deletion PR shrinks this manifest to the
#     post-deletion residual set (done: the 248-entry pre-deletion caller map
#     is now the 67-entry list of files whose only remaining mentions are
#     prose/fixture ram_gb_per_worker references, plus this tombstone).
#
# The signature covers the names spec termination requires gone: pick_seat,
# seat-lib, ram_governor_cap, active_ram_charge, ram_gb_per_worker.
#
# This file must never match its own pattern, so the signature is written
# with a bracket class (seat-li[b], pick_sea[t], ...) and this file is
# excluded from the scan by name.
#
# Hosted by tests/ci-standards-audit.test.sh (workers cannot push
# .github/workflows/**), pinned by tests/p14-test-listing-gate.test.sh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

cd "$repo_root"

SELF="tests/pick-seat-freeze.test.sh"
# The retired-routing signature. Bracket classes keep this file from matching
# itself; they match the same strings at grep time.
PAT='pick_sea[t]|seat-li[b]|ram_governor_ca[p]|active_ram_charg[e]|ram_gb_per_worke[r]'

declare -A frozen
while IFS=: read -r f c; do
    [[ -n "$f" ]] || continue
    frozen["$f"]="$c"
done <<'MANIFEST'
bin/fleet-heartbeat-tier1:4
bin/fleet-restore-drill:1
bin/fleet-vibes-canary:1
bin/ram-measure:1
tests/agent-cron-writes-refused.test.sh:1
tests/blocked-reconcile.test.sh:1
tests/devin-config-trust.test.sh:1
tests/devin-writes-rejected.test.sh:1
tests/fleet-heartbeat-low-water-mark.test.sh:2
tests/fleet-metrics-export.test.sh:4
tests/fleet-ops-3310-infra-death-class-switch.test.sh:1
tests/fleet-restore-drill.test.sh:2
tests/fleet-review-arm-check.test.sh:1
tests/fleet-seat-recovery-units.test.sh:4
tests/fleet-vibes-canary.test.sh:14
tests/fleet-work-slice-tasksmax.test.sh:7
tests/keystone-routing.test.sh:1
tests/openrouter-free-retired-corpse.test.sh:1
tests/pick-seat-freeze.test.sh:28
tests/pi-issue-park-resurrection.test.sh:1
tests/pi-issue-run-app-identity.test.sh:1
tests/pi-issue-run-cwd-anchor.test.sh:1
tests/pi-issue-run-debug-playbook-gate.test.sh:1
tests/pi-issue-run-defensive-mkdir.test.sh:1
tests/pi-issue-run-empty-success.test.sh:1
tests/pi-issue-run-fast-death-class.test.sh:1
tests/pi-issue-run-hang-stall-bench.test.sh:1
tests/pi-issue-run-hang-window-scale.test.sh:1
tests/pi-issue-run-journal-instrumentation.test.sh:1
tests/pi-issue-run-mid-session-bench.test.sh:1
tests/pi-issue-run-noop-bench.test.sh:1
tests/pi-issue-run-per-seat-timeout.test.sh:2
tests/pi-issue-run-resume-on-provider-death.test.sh:1
tests/pi-issue-run-session-error-feed.test.sh:1
tests/pi-issue-run-tried-reset.test.sh:1
tests/pi-worker-execstart-live.test.sh:1
tests/quality-routing.test.sh:1
tests/ram-metric-compare.test.sh:18
tests/repair-rung.test.sh:1
tests/repo-privacy-guard.test.sh:1
tests/seat-empty-run-bench-sticks.test.sh:1
tests/seat-empty-run-ceiling-3727.test.sh:1
tests/seat-empty-run-ceiling-default.test.sh:1
tests/seat-empty-run-clobber-park.test.sh:1
tests/seat-empty-run-count-persists-new-issue.test.sh:1
tests/seat-empty-run-intermittent-count.test.sh:1
tests/seat-empty-run-park-persists.test.sh:1
tests/seat-failure-ceiling.test.sh:1
tests/seat-floor-failopen.test.sh:1
tests/seat-lib-aimd.test.sh:13
tests/seat-lib-dispatch.test.sh:2
tests/seat-lib-free-daily-budget.test.sh:2
tests/seat-lib-prefer-class-empty.test.sh:1
tests/seat-lib-product-only-spend-cap.test.sh:1
tests/seat-lib-provider-daily-budget.test.sh:1
tests/seat-lib-retire.test.sh:1
tests/seat-lib-yield-order.test.sh:4
tests/seat-noop-escalation.test.sh:1
tests/seat-quota-corpse.test.sh:1
tests/seat-registry-liveness.test.sh:1
tests/seat-spawn-bench-ceiling-false-healthy.test.sh:1
tests/seat-spawn-bench-clobber.test.sh:1
tests/seat-spawn-corpse.test.sh:1
tests/seat-wall-cap.test.sh:1
tests/senior-review-routing.test.sh:1
tests/token-economy-routing.test.sh:1
tests/worker-memory-dropin.test.sh:13
MANIFEST

((${#frozen[@]} >= 30)) || fail "residual manifest looks truncated (${#frozen[@]} entries)"

# (a) No NEW file may match the retired-routing signature.
new_hits=0
while IFS= read -r f; do
    [[ "$f" == "$SELF" ]] && continue
    if [[ -z "${frozen[$f]:-}" ]]; then
        echo "FAIL: new retired-routing match in $f — pick_seat caller set is frozen while fleet-ops#4263 deletion is open" >&2
        new_hits=1
    fi
done < <(grep -rlE "$PAT" bin lib tests 2>/dev/null | sort)
(( new_hits == 0 )) || fail "new retired-routing matches found (see above)"

# fleet-ops#4263 accept: once the deletion lands, the retired routing
# library file is gone and no caller remains. (This file is the tombstone
# test — the only file still allowed to carry the retired picker/lib names;
# other manifest entries are prose-only ram_gb_per_worker references.)
[[ ! -f "$repo_root/lib/seat-lib.sh" ]] \
    || fail "lib/seat-lib.sh must be absent after the P3b deletion"
if grep -rqE '\$\(pick_seat|(^|[[:space:]])pick_seat\(' bin lib 2>/dev/null; then
    fail "a pick_seat caller remains under bin/ or lib/"
fi
if grep -rqE 'ram_governor_cap|active_ram_charge' bin lib 2>/dev/null; then
    fail "a RAM-governor caller remains under bin/ or lib/"
fi

# (b) No manifest file may GROW its match count. Shrinking is allowed —
# that is the deletion doing its job.
grown=0
for f in "${!frozen[@]}"; do
    [[ -f "$f" ]] || continue
    n=$(grep -oE "$PAT" "$f" 2>/dev/null | wc -l)
    n=${n//[^0-9]/}
    if (( n > ${frozen[$f]:-0} )); then
        echo "FAIL: $f grew retired-routing matches ${frozen[$f]} -> $n — no new pick_seat callers while fleet-ops#4263 deletion is open" >&2
        grown=1
    fi
done
(( grown == 0 )) || fail "manifest files grew retired-routing matches (see above)"

ok "pick_seat caller set frozen: ${#frozen[@]} files, no new matches, no growth"
