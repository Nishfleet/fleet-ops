#!/usr/bin/env bash
# Glue sweep 2026-09-18: the slo-budget and the two money-boundary drills
# were removed from this host — lib/slo_budget.py, config/slo-definitions.json
# and bin/money-boundary-raise were deleted with the metrics exporter, and the
# money guard is now a LiteLLM key budget + the severity=nish alert route.
# This file stays because its OTHER job is load-bearing: it is the P14 host
# Also dropped 2026-09-18: the host lines for
# fleet-alert-detached-deadman-command-path.test.sh and spawn-guard.test.sh.
# Both test files were deleted by the rail lane's cut (d4a42ced6) which
# replaced 1,283 lines of glue with stock gh tokens, prompt templates,
# --exclude-tools and two systemd properties. A host line pointing at a
# deleted file aborts this whole host, taking 9 live drills down with it.
# that keeps 11 nested drills reachable from ci.yml.
# tests/rule-enforcement.test.sh
#
# Glue sweep 2026-09-18 (final pass, cluster rule-enforcement, Jev p=0.86):
# the rule-coverage matrix itself is deleted — config/rule-enforcement.json
# and lib/rule-enforcement.py are gone, Pi reads the rule files natively and
# the canonical standing-rules text lives in docs/. What is left here is the
# CI host: this file is listed in ci.yml, and the drills below are invoked
# from it because the worker App cannot push .github/workflows/**.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# fleet-ops#1245: GEO/AEO parked-tactics + brand-gate canary. Hosted
# BEFORE the live vault join for the same reason as #1178.

# fleet-ops#234: escalate-senior intake path (senior panel). Nested host so
# the worker token does not need a workflow edit (fleet-ops#566).
ok "rule-enforcement: pi-escalation-audit drill"

# fleet-ops#906: D1 prod migration correction — prompt gate requires the
# senior process from the final 2026-08-27 process amendment.
bash "$here/fleet-d1-migration-senior-process.test.sh" || fail "d1 migration senior process drill failed"
ok "rule-enforcement: d1 migration senior process drill"

# fleet-ops#907: D1 prod migration vacation grant is enforced by the worker
# prompt D1 schema rule and this CI drill.
bash "$here/fleet-d1-prod-migration-grant.test.sh" || fail "d1-prod-migration-grant drill failed"
ok "rule-enforcement: d1-prod-migration-grant drill"

# fleet-ops#908: D1 prod migration execution rule (process amendment) is
# enforced by the worker prompt senior process gate and this CI drill.
bash "$here/fleet-d1-prod-migration-process.test.sh" || fail "d1-prod-migration-process drill failed"
ok "rule-enforcement: d1-prod-migration-process drill" 

# ============================================================================
# Glue sweep 2026-09-18: the fleet-escalation-canary auto-file/observe-to-close
# drill that lived here was removed with the escalation tower (the canary, the
# global 10-escalate.conf drop-ins and the STOP-REASON pipeline are deleted).
# The matrix validate/join assertions above and the per-gate drills below are
# unchanged.
# ============================================================================

# fleet-ops#519: run the no-agent-names gate drill as part of the
# rule-enforcement suite so it is exercised in CI without a workflow edit.

# fleet-ops#926: hosted-runner rev-range class gate. Nested host so the
# worker token does not need a workflow edit.
bash "$here/ci-hosted-paths.test.sh" || fail "ci-hosted-paths class gate failed"
ok "rule-enforcement: ci-hosted-paths class gate"

# fleet-ops#1265: paved-road vault capture. Nested host so P14 covers it
# without a workflow edit (worker tokens cannot push .github/workflows/**).


# fleet-ops#545: CommandCode MiniMax M3 fail-closed catalog canary. Nested
# host so the worker token does not need to edit .github/workflows/**.

# fleet-ops#541: weekly continuous-research sweep. Nested host so the
# worker token does not need to edit .github/workflows/**.

# fleet-ops#1146: Weekly Fleet Review (WFR) — blind 6-lens senior research
# + conference, output capped at 5 specced actions. Nested host so this
# token does not need a workflow edit.

# fleet-ops#1151: weekly baseline-delta strangeness pre-pass (WFR input).
# Nested host so this token does not need a workflow edit.

# fleet-ops#1236: weekly AEO visibility probe. Nested host so this token
# does not need a workflow edit.

# fleet-ops#544: VPS→Mac Tailscale lockdown canary. Same nested-CI host so
# this token does not need a workflow edit.

# fleet-ops#524: per-repo verification harness canary. Nested host so the
# worker token does not need to edit .github/workflows/**.

# fleet-ops#545: paid-flash watcher. Named in led-worker-lane-refresh
# proof fields, hosted here so the worker token does not need a workflow
# edit (fleet-ops#660 — fleet-free-roster-canary was already wired by
# #800 under fleet-ops#634).

# fleet-ops#5586: reserved-classes precedence — the vault list is the single
# source of truth and every surface defers to it. Text-only guard; the
# renderer it used to check was deleted in the 2026-09-18 glue sweep.
bash "$here/reserved-classes-precedence.test.sh" || fail "reserved-classes precedence drill failed"
ok "rule-enforcement: reserved-classes precedence drill"

# fleet-ops#5644: retired-host gate. The live rulebook surfaces must never
# scope the VPS write-autonomy / credential-parity postures to the retired
# 'hostinger-kvm4' host; nested host so the worker token does not need to
# edit .github/workflows/** (same class-prevention as the drift gate above).
bash "$here/rulebook-host-drift.test.sh" || fail "rulebook retired-host drill failed"
ok "rule-enforcement: rulebook retired-host drill"


# fleet-ops#????: siterep live canary pin wrapper. Nested host so the worker
# token does not need a workflow edit.

ok "rule-enforcement: hosted drills complete"

# fleet-ops#2089: install.sh must self-heal enabled-but-inactive timers
# (the staleness canary sat dead: enabled, NextElapse=infinity, never
# scheduled). Nested host so the worker token does not edit
# .github/workflows/**.
ok "rule-enforcement: install enabled-but-inactive timer self-heal drill"

# fleet-ops#1307: install.sh --system must reload prometheus after a changed
# config/fleet_rules.yml (ExecReload is kill -HUP; a merged alert rule
# otherwise sits on disk) and prove every group is in GET /api/v1/rules.
# Nested host so the worker token does not edit .github/workflows/**.
ok "rule-enforcement: install prometheus rules-reload drill"

# fleet-ops#4223: a non-fatal config REFUSE must not abort install.sh; later
# MANIFEST entries (e.g. a non-canonical unit symlink) must still be repaired.
# Nested host so the worker token does not edit .github/workflows/**.
ok "rule-enforcement: install refuse-continues drill (fleet-ops#4223)"

# fleet-ops#516: sr-max-speed hunter. CI lists this file, not
# fleet-max-speed.test.sh (workers cannot edit .github/workflows).
# fleet-ops#527: monthly rulebook red-team + rollback-backup gate. Same
# CI constraint (worker token cannot add a P14 line in ci.yml).

# fleet-ops#538: "never decide by vibes — always measure" canary. Same
# nested-CI host so the worker token does not need a workflow edit.

# fleet-ops#532: skills-native canary (sr-skills-native). Same nested-CI
# host so the worker token does not need a workflow edit.

# fleet-ops#1396: .git/info/exclude 'bin/**' silently dropped new bin
# executables from commits. Nested host so the worker token does not need
# a workflow edit.
bash "$here/fleet-bin-exclude-canary.test.sh" || fail "bin-exclude canary drill failed"
ok "rule-enforcement: bin-exclude canary drill"

# silent-drop sweep 2026-09-11: no findings-cap token or 'gh issue ... || true'
# drop in bin/lib without allowlist + ledger row. Nested host so the worker
# token does not need a workflow edit (fleet-ops#566).
bash "$here/silent-drop-canary.test.sh" || fail "silent-drop canary drill failed"
ok "rule-enforcement: silent-drop canary drill"

# fleet-ops#2151: tailscaled localapi socket-reachability canary (skips
# gracefully on a runner without tailscale). Hosted here from this
# already-listed test so P14 runs it without a workflow edit.


# fleet-ops#1160: VPS reboot-survival regression — post-reboot timer must be
# system-scope and verify must recover tailscale, not just announce.
ok "rule-enforcement: vps reboot-survival regression drill"

ok "rule-enforcement: hosted drills complete"
