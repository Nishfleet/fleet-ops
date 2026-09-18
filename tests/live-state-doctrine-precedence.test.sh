#!/usr/bin/env bash
# tests/live-state-doctrine-precedence.test.sh
#
# fleet-ops#5748: the "how to check whether the fleet is live" procedure
# existed twice — a 2-step "Authoritative check, in order" in the Pi
# canonical (docs/pi-agents.md) and a 5-step generated
# idle-fleet-alarm block (docs/standing-rules.md, rendered into
# ~/.claude/CLAUDE.md) — with already-diverged procedures and NO recorded
# precedence. An agent following the shorter list skipped the failed-units
# sweep and the seat-health recency check.
#
# Gate (fleet-ops#366 mechanical-fix): the Pi canonical must
#   1. declare the 5-step idle-fleet-alarm procedure canonical and
#      winning on drift, pointing at its single edit point, and
#   2. carry the findings-grade steps 3-5 (failed units, seat-health
#      recency, uptime/throughput) rather than trailing the old 2-step
#      block with no extension, and
#   3. the standing-rules canonical must still carry the 5-step section
#      (FLEET-PAUSED first — fleet-ops#5717) that the pointer names.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
pi_canonical="$repo_root/docs/pi-agents.md"
sr_canonical="$repo_root/docs/standing-rules.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -f "$pi_canonical" ]] || fail "missing $pi_canonical"
[[ -f "$sr_canonical" ]] || fail "missing $sr_canonical"

# (1) Precedence recorded: Pi canonical defers to the idle-fleet-alarm block.
grep -q "idle-fleet-alarm" "$pi_canonical" \
  || fail "pi canonical does not name the idle-fleet-alarm block (no precedence recorded)"
grep -q "fleet-ops#5748" "$pi_canonical" \
  || fail "pi canonical does not record the #5748 consolidation"
grep -q "~/.claude/CLAUDE.md" "$pi_canonical" \
  || fail "pi canonical does not point at the canonical edit point (.claude/CLAUDE.md)"
grep -q "WINS" "$pi_canonical" \
  || fail "pi canonical does not state which list wins on drift"

# The old 2-step-only heading must not come back: the quick minimum is
# labelled as a minimum, and the canonical/complete wording is present.
grep -qi "quick minimum" "$pi_canonical" \
  || fail "pi canonical lost the 'quick minimum' framing for the 2-step list"
grep -q "The 5-step fleet live-state check is canonical" "$pi_canonical" \
  || fail "pi canonical no longer declares the 5-step check canonical"

# (2) Steps 3-5 findings-grade duties live in the Pi canonical too, so a
# reader of the Pi surface alone does not skip them.
grep -q "list-units --state=failed" "$pi_canonical" \
  || fail "pi canonical omits the failed-units sweep (step 3)"
# Step 4 became the LiteLLM router's own state on 2026-09-18: seat-health.ts
# (the pi-seat-health.json writer) was deleted in the glue sweep, so the file
# is frozen. Prometheus already scrapes the proxy (config/prometheus.yml
# job_name: litellm), so the gauge is the live source.
grep -q "litellm_deployment_state" "$pi_canonical" \
  || fail "pi canonical omits the LiteLLM seat-state check (step 4)"
grep -q "uptime" "$pi_canonical" \
  || fail "pi canonical omits the uptime/throughput step (step 5)"

# (3) The standing-rules canonical still owns the 5-step section the
# pointer names, with FLEET-PAUSED first (fleet-ops#5717).
grep -q "SECTION: idle-fleet-alarm" "$sr_canonical" \
  || fail "standing-rules canonical lost the idle-fleet-alarm section"
first_step=$(grep -A30 "SECTION: idle-fleet-alarm" "$sr_canonical" | grep -m1 "^1\." || true)
grep -q "FLEET-PAUSED" <<<"$first_step" \
  || fail "idle-fleet-alarm step 1 is no longer the FLEET-PAUSED sentinel (fleet-ops#5717)"
grep -q "SECTION: idle-fleet-alarm" "$pi_canonical" -r 2>/dev/null || true
grep -q "SECTION: idle-fleet-alarm" "$pi_canonical" \
  || fail "pi canonical pointer does not name the SECTION: idle-fleet-alarm anchor"

echo "PASS: live-state doctrine precedence gate"
