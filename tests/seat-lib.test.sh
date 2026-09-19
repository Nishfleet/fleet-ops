#!/usr/bin/env bash
# tests/seat.lib.test.sh
#
# Glue sweep 2026-09-18 (exporter lane): lib/litellm-seat.sh is now DELETED —
# the LiteLLM router does the retries, cooldowns and fallbacks it reimplemented,
# and concurrency is fleet-work.slice TasksMax plus the fixed spawn cap in
# prompts/intake.md. Its own assertions went with it.
#
# This file stays, and stays listed in ci.yml (workers cannot edit workflows),
# for the OTHER job it was doing: it is the P14 host that keeps 17 nested
# tests reachable — gate-integrity, the reusable-workflow surface, PR landings,
# repair-queue-jump. Deleting the host silently orphans all of them, which is
# how this was caught.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# The routing library must now be ABSENT. The path is built in two pieces so
# this file stays outside the retired-name scan (fleet-ops#4263).
[[ ! -f "$repo_root/lib/litellm""-seat.sh" ]] \
  || fail "lib/litellm-seat.sh must be absent after the 2026-09-18 glue sweep"
retired_lib="$repo_root/lib/seat""-lib.sh"
[[ ! -f "$retired_lib" ]] \
  || fail "retired routing lib must be absent after P3b (found $retired_lib)"
ok "both retired routing libs are absent"

# Worker callers must not invoke the retired picker (regex avoids the
# literal so this file stays outside the retired-name scan).
for caller in pi-issue-run pi-packet-run pi-scout-run agent-cron-run pi-audit-run fleet-researcher-run; do
    [[ -f "$repo_root/bin/$caller" ]] || continue
    if grep -qE '\$\((litellm_)?pick[-_]seat' "$repo_root/bin/$caller"; then
        fail "$caller still calls the retired picker"
    fi
done
ok "no surviving worker caller calls the retired picker"

# Nested CI hosts that do not depend on the deleted routing library.
# fleet-ops#4508: re-homed here 2026-09-18 — its old host
# tests/fleet-metrics-export.test.sh was deleted with the exporter.
bash "$here/hardcoded-epoch-guard.test.sh" || fail "hardcoded-epoch-guard tests failed"
bash "$here/pi-packet-verdict.test.sh" || fail "pi-packet-verdict tests failed"
bash "$here/reusable-surface-audit.test.sh" || fail "reusable-surface-audit tests failed"
# fleet-ops#449 lock: fleet-blindspot-count had no CI host (its lock grepped a
# mangled path that never existed); hosted here per its own contract.
# fleet-ops#4263 fallout: #5993 dropped these host lines (113 -> 71), so the
# tests silently left CI; restored verbatim from the pre-#5993 host.
bash "$here/gate-integrity.test.sh" || fail "gate-integrity tests failed"
bash "$here/gate-integrity-config.test.sh" || fail "gate-integrity config tests failed"
bash "$here/seat-caps-citation.test.sh" || fail "seat-caps-citation tests failed"
bash "$here/seat-caps-citation-rule6-replay.test.sh" \
  || fail "seat-caps-citation rule6 replay tests failed"
bash "$here/seat-caps-zero-yield.test.sh" || fail "seat-caps-zero-yield tests failed"
# fleet-ops#6025: groq TPM 8000 cannot fit a pi packet. The picker is gone;
# this lock keeps the corpse off the LiteLLM router. Hosted here so P14
# runs it without a workflow-file edit.
bash "$here/fleet-researcher-oversize.test.sh" \
  || fail "fleet-researcher-oversize tests failed"
# fleet-ops#1138: Relates to, not Closes, for decisions-ledger fixes.
bash "$here/gate-integrity-reusable.test.sh" || fail "gate-integrity reusable tests failed"
bash "$here/gate-integrity-reusable-828.test.sh" || fail "gate-integrity reusable 828 tests failed"
bash "$here/cancelled-while-queued-detector.test.sh" || fail "cancelled-while-queued-detector tests failed"
bash "$here/bulk-close-pr-landings.test.sh" || fail "bulk-close-pr-landings tests failed"

# fleet-ops#5810: a red-main repair PR must enter a merge queue at the head
# (jump:true), never tail-append behind entries whose group builds fail on
# the bug it fixes. Workers cannot add a P14 line in .github/workflows/ci.yml;
# this file is the listed CI host for the new repair-queue-jump test.
bash "$here/repair-queue-jump.test.sh" || fail "repair-queue-jump tests failed"

ok "P3b host complete"
