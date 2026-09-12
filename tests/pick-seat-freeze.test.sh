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
#   * deletions are allowed — the deletion PR shrinks this manifest to just
#     the tombstone test.
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
bin/agent-cron-run:13
bin/blocked-reconcile:8
bin/fleet-aimd-meter-canary:8
bin/fleet-blind-audit:7
bin/fleet-claim:4
bin/fleet-entitled-wired-canary:2
bin/fleet-escalation-canary:9
bin/fleet-escalation-drain:1
bin/fleet-free-roster-canary:1
bin/fleet-gap-closure-conference:5
bin/fleet-heartbeat-low-water-mark:10
bin/fleet-heartbeat-tier1:8
bin/fleet-heartbeat-undersaturation:9
bin/fleet-prepaid-util-canary:9
bin/fleet-researcher-run:5
bin/fleet-restore-drill:10
bin/fleet-review-arm-check:4
bin/fleet-rulebook-redteam:4
bin/fleet-seat-comeback-release:21
bin/fleet-seat-live-validate:4
bin/fleet-seat-recovery:16
bin/fleet-vibes-canary:11
bin/money-boundary-raise:2
bin/pi-audit-run:12
bin/pi-intake-repair-run:7
bin/pi-issue-failed-reap:5
bin/pi-issue-run:40
bin/pi-issue-start:3
bin/pi-packet-run:8
bin/pi-scout-run:10
bin/pi-transport-check:1
bin/pi-transport-self-heal:2
bin/ram-measure:2
bin/ram-metric-compare:1
bin/stop-escalation-dispatch:13
lib/cursor-api-bucket.sh:2
lib/failed-command-flagged.py:1
lib/fleet-deploy-quality.py:1
lib/guard_shared_file_collision.py:4
lib/manual-seam-lens.py:1
lib/pi-intake-tick.sh:39
lib/quality-routing.py:2
lib/seat-lib.sh:152
lib/work-supply.sh:1
tests/agent-cron-empty-stdout.test.sh:3
tests/agent-cron-fable-check-litellm-routing.test.sh:36
tests/agent-cron-failure-reason.test.sh:6
tests/agent-cron-packet-size.test.sh:2
tests/agent-cron-prompt-e2big-guard.test.sh:14
tests/agent-cron-seat-rotation.test.sh:10
tests/agent-cron-workdir-guard.test.sh:3
tests/agent-cron-writes-refused.test.sh:15
tests/aimd-meter-canary.test.sh:9
tests/alert-repair-class-park-skip.test.sh:1
tests/alert-repair-detached-recursion-skip.test.sh:1
tests/alert-repair-flagship-seat.test.sh:2
tests/alert-repair-seat-walled.test.sh:1
tests/audition-lane.test.sh:23
tests/blocked-reconcile.test.sh:4
tests/cancelled-while-queued-detector.test.sh:3
tests/ci-standards-audit.test.sh:3
tests/console-shipped-spot-revert.test.sh:3
tests/detached-deliverable-preflight.test.sh:1
tests/devin-config-trust.test.sh:7
tests/devin-writes-rejected.test.sh:11
tests/entitled-wired-canary.test.sh:2
tests/escalation-coverage-canary.test.sh:3
tests/fixtures/merge-trample-gate/worktree-gap-1228.json:2
tests/fleet-blind-audit-carryover.test.sh:5
tests/fleet-blind-audit-filing-batch.test.sh:3
tests/fleet-blind-audit.test.sh:8
tests/fleet-blindspot-count.test.sh:3
tests/fleet-claim.test.sh:19
tests/fleet-debug-playbook.test.sh:2
tests/fleet-decisions-ledger.test.sh:6
tests/fleet-exec-review-canary.test.sh:1
tests/fleet-failed-command-cat-stale-fleet-ops.test.sh:5
tests/fleet-failed-command-clone-race-cd.test.sh:5
tests/fleet-failed-command-clone-ssh-publickey.test.sh:5
tests/fleet-failed-command-compound-ls-permission-denied.test.sh:4
tests/fleet-failed-command-dedup-open-list.test.sh:1
tests/fleet-failed-command-detector-bin-exit.test.sh:5
tests/fleet-failed-command-edit-array-unmatch.test.sh:4
tests/fleet-failed-command-edit-schema-validation.test.sh:15
tests/fleet-failed-command-edit-unmatch.test.sh:6
tests/fleet-failed-command-empty-tool-name.test.sh:5
tests/fleet-failed-command-flagged.test.sh:4
tests/fleet-failed-command-gh-api-403-integration.test.sh:4
tests/fleet-failed-command-gh-issue-view-body.test.sh:4
tests/fleet-failed-command-gh-issue-view-unknown-field.test.sh:5
tests/fleet-failed-command-gh-json-graphql-recovery.test.sh:5
tests/fleet-failed-command-gh-pr-json-piped-python-load.test.sh:5
tests/fleet-failed-command-gh-pr-list-invalid-sort.test.sh:5
tests/fleet-failed-command-gh-pr-view-merged.test.sh:5
tests/fleet-failed-command-git-cherry-pick-empty.test.sh:4
tests/fleet-failed-command-ledger-dedup.test.sh:4
tests/fleet-failed-command-no-agent-names-reject.test.sh:4
tests/fleet-failed-command-observe-duplicate-1003.test.sh:4
tests/fleet-failed-command-observe-duplicate-enoent.test.sh:8
tests/fleet-failed-command-observe-duplicate-git-branch-force.test.sh:8
tests/fleet-failed-command-observe-duplicate-open.test.sh:8
tests/fleet-failed-command-observe-duplicate-python-traceback.test.sh:4
tests/fleet-failed-command-pem-deserialize.test.sh:5
tests/fleet-failed-command-ps-empty-selection.test.sh:5
tests/fleet-failed-command-python-module-not-found-hyphen.test.sh:5
tests/fleet-failed-command-python-traceback.test.sh:5
tests/fleet-failed-command-read-eisdir.test.sh:5
tests/fleet-failed-command-read-enoent-archived-packet.test.sh:5
tests/fleet-failed-command-read-enoent-skip-todos.test.sh:5
tests/fleet-failed-command-read-enoent-stale-rg.test.sh:5
tests/fleet-failed-command-read-enoent-thinking.test.sh:5
tests/fleet-failed-command-todo-schema-validation.test.sh:5
tests/fleet-failed-command-typo-est-sh.test.sh:5
tests/fleet-findings-queued.test.sh:2
tests/fleet-free-roster-canary.test.sh:2
tests/fleet-gap-closure-conference-senior-seat.test.sh:1
tests/fleet-gap-closure-loop.test.sh:9
tests/fleet-heartbeat-alarm-rc-decoupling.test.sh:5
tests/fleet-heartbeat-low-water-mark.test.sh:9
tests/fleet-heartbeat-rc-propagation.test.sh:4
tests/fleet-heartbeat-red-pr-repair.test.sh:1
tests/fleet-heartbeat-throughput-split.test.sh:2
tests/fleet-heartbeat-undersaturation.test.sh:2
tests/fleet-interventions-eliminated.test.sh:2
tests/fleet-metrics-export.test.sh:10
tests/fleet-ops-2772-claim-loop-gate.test.sh:1
tests/fleet-ops-3310-infra-death-class-switch.test.sh:21
tests/fleet-red-main-suspicion.test.sh:1
tests/fleet-restore-drill.test.sh:2
tests/fleet-review-arm-check.test.sh:2
tests/fleet-rulebook-redteam.test.sh:3
tests/fleet-seat-comeback-release.test.sh:15
tests/fleet-seat-live-validate.test.sh:1
tests/fleet-seat-recovery.test.sh:8
tests/fleet-seat-recovery-units.test.sh:6
tests/fleet-self-maintenance-split.test.sh:1
tests/fleet-token-economy.test.sh:15
tests/fleet-unjustified-wait.test.sh:1
tests/fleet-usd-spend.test.sh:2
tests/fleet-vibes-canary.test.sh:14
tests/fleet-worker-prompt-gh-pr-view-unknown-field.test.sh:5
tests/fleet-work-slice-tasksmax.test.sh:7
tests/gate-integrity-config.test.sh:4
tests/gate-integrity-reusable-828.test.sh:4
tests/gate-integrity-reusable.test.sh:4
tests/gate-integrity.test.sh:4
tests/guard-shared-file-collision.test.sh:8
tests/intake-repos-path-resolution.test.sh:11
tests/keystone-routing.test.sh:8
tests/manual-seam-lens.test.sh:4
tests/openrouter-free-retired-corpse.test.sh:3
tests/p14-test-listing-gate.test.sh:12
tests/pi-audit-run-product-repo-reality.test.sh:3
tests/pi-audit-run-question.test.sh:1
tests/pi-audit-run.test.sh:16
tests/pi-intake-app-budget.test.sh:2
tests/pi-intake-gh-rate-limit.test.sh:3
tests/pi-intake-repair-run.test.sh:8
tests/pi-intake-tick-difficulty-from-issue.test.sh:2
tests/pi-intake-tick-scout-low-water.test.sh:2
tests/pi-intake-tick-scout-on-empty.test.sh:2
tests/pi-intake-tick-seat-gate.test.sh:9
tests/pi-intake-tick-self-maint-cap.test.sh:12
tests/pi-intake-tick-spawn-stagger.test.sh:7
tests/pi-intake-topup.test.sh:2
tests/pi-issue-failed-reap.test.sh:6
tests/pi-issue-park-resurrection.test.sh:2
tests/pi-issue-run-app-identity.test.sh:2
tests/pi-issue-run-cwd-anchor.test.sh:2
tests/pi-issue-run-debug-playbook-gate.test.sh:2
tests/pi-issue-run-defensive-mkdir.test.sh:9
tests/pi-issue-run-empty-success.test.sh:2
tests/pi-issue-run-failure-reason.test.sh:5
tests/pi-issue-run-fast-death-class.test.sh:3
tests/pi-issue-run-hang-stall-bench.test.sh:10
tests/pi-issue-run-hang-window-scale.test.sh:6
tests/pi-issue-run-journal-instrumentation.test.sh:5
tests/pi-issue-run-mid-session-bench.test.sh:13
tests/pi-issue-run-noop-bench.test.sh:22
tests/pi-issue-run-per-seat-timeout.test.sh:7
tests/pi-issue-run-resume-on-provider-death.test.sh:2
tests/pi-issue-run-session-error-feed.test.sh:2
tests/pi-issue-run-tried-reset.test.sh:6
tests/pi-packet-run.test.sh:6
tests/pi-packet-verdict.test.sh:6
tests/pi-scout-packet-assembly.test.sh:5
tests/pi-scout-seat-rotation.test.sh:8
tests/pi-seat-source-litellm.test.sh:36
tests/pi-worker-execstart-live.test.sh:8
tests/quality-research-weekly.test.sh:2
tests/quality-routing.test.sh:10
tests/ram-measure.test.sh:5
tests/ram-metric-compare.test.sh:21
tests/repair-rotation.test.sh:26
tests/repair-rung-disarm.test.sh:6
tests/repair-rung.test.sh:17
tests/repo-privacy-guard.test.sh:10
tests/reusable-surface-audit.test.sh:4
tests/role-quality-gates.test.sh:2
tests/scout-futility.test.sh:4
tests/scout-prompt-difficulty.test.sh:6
tests/seat-caps-citation-rule6-replay.test.sh:3
tests/seat-caps-citation.test.sh:3
tests/seat-caps-zero-yield.test.sh:1
tests/seat-credentials-bad-replay.test.sh:13
tests/seat-empty-run-bench-sticks.test.sh:30
tests/seat-empty-run-ceiling-3727.test.sh:2
tests/seat-empty-run-ceiling-default.test.sh:2
tests/seat-empty-run-clobber-park.test.sh:2
tests/seat-empty-run-comeback-probe.test.sh:1
tests/seat-empty-run-count-persists-new-issue.test.sh:16
tests/seat-empty-run-intermittent-count.test.sh:2
tests/seat-empty-run-park-persists.test.sh:2
tests/seat-failure-ceiling.test.sh:2
tests/seat-floor-failopen.test.sh:7
tests/seat-health-ledger-noop-write.test.sh:3
tests/seat-health-quarantine.test.sh:1
tests/seat-lib-aimd.test.sh:31
tests/seat-lib-cursor-usd-today.test.sh:5
tests/seat-lib-degraded.test.sh:21
tests/seat-lib-dispatch.test.sh:9
tests/seat-lib-free-daily-budget.test.sh:13
tests/seat-lib-org-reserve.test.sh:9
tests/seat-lib-prefer-class-empty.test.sh:9
tests/seat-lib-product-only-spend-cap.test.sh:10
tests/seat-lib-provider-daily-budget.test.sh:14
tests/seat-lib-ramp-staleness.test.sh:3
tests/seat-lib-retire.test.sh:15
tests/seat-lib.test.sh:226
tests/seat-lib-yield-order.test.sh:16
tests/seat-noop-escalation.test.sh:2
tests/seat-phantom-out-suffix.test.sh:2
tests/seat-quota-corpse.test.sh:3
tests/seat-registry-liveness.test.sh:12
tests/seat-spawn-bench-ceiling-false-healthy.test.sh:2
tests/seat-spawn-bench-clobber.test.sh:2
tests/seat-spawn-corpse.test.sh:3
tests/seat-wall-cap.test.sh:3
tests/seat-wall-reset-horizon.test.sh:3
tests/senior-review-routing.test.sh:11
tests/siterep-deploy-rollback-rc-propagation.test.sh:4
tests/stop-escalation-dispatch.test.sh:11
tests/subagent-extload.test.sh:2
tests/token-economy-routing.test.sh:7
tests/watch-log-rotation.test.sh:5
tests/weekly-fleet-review.test.sh:2
tests/worker-memory-dropin.test.sh:18
MANIFEST

((${#frozen[@]} > 200)) || fail "frozen manifest looks truncated (${#frozen[@]} entries)"

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

# (b) No manifest file may GROW its match count. Shrinking is allowed —
# that is the deletion doing its job.
grown=0
for f in "${!frozen[@]}"; do
    [[ -f "$f" ]] || continue
    n=$(grep -oE "$PAT" "$f" 2>/dev/null | wc -l)
    n=${n//[^0-9]/}
    if (( n > frozen[$f] )); then
        echo "FAIL: $f grew retired-routing matches ${frozen[$f]} -> $n — no new pick_seat callers while fleet-ops#4263 deletion is open" >&2
        grown=1
    fi
done
(( grown == 0 )) || fail "manifest files grew retired-routing matches (see above)"

ok "pick_seat caller set frozen: ${#frozen[@]} files, no new matches, no growth"
