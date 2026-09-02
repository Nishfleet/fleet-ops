## Summary

Re-verification of the cline/cline-pass_minimax-m3 corpse triage filed at
2026-09-02T00:57:08Z. The seat has since self-recovered from corpse state
and is now a normal walled seat (quota_bench) waiting for the monthly
Clinepass limit to reset. No cap change, no retirement needed.

## Evidence

**Issue snapshot (2026-09-02T00:57:08Z):** health_class=corpse,
seat_dead=true, consecutive_failure_count=19, http_status=null,
failure_mode=manual_repair_corpse. No usable_at, no wall_end — would never
self-release.

**Live re-probe (2026-09-03T00:03Z):**
```
pi --print --no-session --provider cline --model cline-pass/minimax-m3 'Reply with exactly: PONG'
→ 429: {"code":"INFERENCE_CAP_ERROR","message":"You have reached your monthly Clinepass limit. The limit resets in 16d 13h, please try again later."}
PACKET-VERDICT tools=0 class=no-tools
```
This is a QUOTA CAP, not a credential fault and not a dead slug.

**Control probe (same provider, same credential):**
```
pi --print --no-session --provider cline --model z-ai/glm-5.3-flash 'Reply with exactly: PONG'
→ PONG
PACKET-VERDICT tools=0 class=no-tools
```
The cline credential is LIVE — the free sibling returns PONG (HTTP 200).

**Live ledger (lanes/seats/cline__cline-pass_minimax-m3.json):**
health_class=quota_bench, seat_dead=false, failure_mode=quota_cap,
http_status=429, consecutive_failure_count=10,
bench_until=2026-09-19T07:33:36Z, usable_at=2026-09-19T07:33:36Z.

**Fleet census at re-verification:** 0 seat_dead (all corpses cleared).
14 healthy, 5 quota_exhausted, 2 rate_limited, 1 overload_bench, 1 quota_bench.

## Root cause of the corpse clear

The corpse self-cleared: a probe reached the seat after the corpse snapshot,
got a 429 quota_cap response, and the quota_bench writer overwrote the corpse
ledger with seat_dead=false. The manual_repair_corpse failure_mode in the
issue snapshot is not in the current seat-health.ts or seat-lib.sh codebase —
it was a transient/legacy write.

The seat is a normal walled seat that will self-release when the monthly
Clinepass limit resets (~2026-09-19). The sibling cline-pass/deepseek-v4-flash
is also quota_exhausted (HTTP 402) on the same monthly limit, confirming this
is a subscription-level quota wall, not a model-specific fault.

## Stale duplicates

This same recovered corpse has 5 stale duplicate issues still open:
#2761, #2765, #2792, #2804, #2813. All reference the same cline-pass/minimax-m3
seat (and #2792/#2804/#2813 also reference opencode/mimo-v2.5-free, which has
similarly recovered to rate_limited, seat_dead=false).

## Verification

```
$ python3 -c "import json; json.load(open('config/seat-caps.json'))"; echo "exit $?"
exit 0

$ bash tests/seat-lib.test.sh 2>&1 | tail -1; echo "exit ${PIPESTATUS[0]}"
ALL OK
exit 0

$ bash tests/seat-health-classifier.test.sh 2>&1 | tail -1; echo "exit ${PIPESTATUS[0]}"
ALL OK
exit 0

$ pi --print --no-session --provider cline --model cline-pass/minimax-m3 'Reply with exactly: PONG' 2>&1 | grep -E '429|PONG|INFERENCE_CAP'
429: {"code":"INFERENCE_CAP_ERROR","message":"You have reached your monthly Clinepass limit. The limit resets in 16d 13h, please try again later."}
exit 0

$ pi --print --no-session --provider cline --model z-ai/glm-5.3-flash 'Reply with exactly: PONG' 2>&1 | grep -E 'PONG|429|error'
PONG
exit 0
```

Fleet census at re-verification: 0 seat_dead (14 healthy, 5 quota_exhausted,
2 rate_limited, 1 overload_bench, 1 quota_bench). All tests pass. rc=0.

Comment-only change to config/seat-caps.json (new _comment_minimax_m3_pass
field on the cline provider). No cap change, no code change, no new machinery.

Closes #2752
