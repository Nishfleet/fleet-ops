## Summary

bai/deepseek-v4-flash returned HTTP 400 `{"message":"credit insufficient balance: balance=0 required=7716","code":"insufficient_user_quota"}`. `is_quota_cap_error` had no `insufficient_user_quota` literal, so the death booked `error_class=unknown` → transient_fault → 300s spawn bench, and the dead free seat was re-offered every ~5 min (~12 claims/hour), burning scout/issue claims.

- `lib/seat-lib.sh` `is_quota_cap_error`: add `insufficient_user_quota` to BOTH the signal-word gate regex and the no-window hard-cap keyword list (the b.ai body carries no reset window, so it must pass the hard-cap list like `credit balance depleted` does).
- `config/seat-caps.json`: bai gets `quota_bench_default_s: 3600` with a dated `_comment_bai_quota_bench` citing the 400 body + request id (free-class precedent: xkiro=3600; hourly re-probe detects the reset without the claim burn).
- `tests/seat-lib.test.sh`: add a 9c pin — the verbatim b.ai 400 body and a bare `session-error: 400 insufficient_user_quota` must both classify quota/cap wall.

## Verification

- `bash tests/seat-lib.test.sh` — passes (new 9c pin included; `OK: 9c: b.ai 400 'insufficient_user_quota' -> quota/cap wall (fleet-ops#4831)`)
- `bash tests/seat-caps-citation.test.sh` — exit 0
- `bash tests/fleet-token-economy.test.sh` — exit 0
- before/after probe: `bash -c 'source lib/seat-lib.sh; is_quota_cap_error "" "400: {\"message\":\"credit insufficient balance: balance=0 required=7716\",\"code\":\"insufficient_user_quota\"}"'` → before (origin/main) rc=1 (unclassified), after rc=0 (classified quota/cap wall)

run-proof: tests/seat-lib.test.sh (9c pin), tests/seat-caps-citation.test.sh, tests/fleet-token-economy.test.sh — all green on claim/issue-4831 @ af02e690

research: mirrors the xai-oauth/mergegateway/pareto precedent (no-window hard-cap list + free-tier `quota_bench_default_s`); no new `bin/` files.

help-first: no new `bin/` files; edits to existing `lib/seat-lib.sh`, `config/seat-caps.json`, `tests/seat-lib.test.sh` only.

loose-ends: none

net-positive-because: the +28 lines are the classifier fix itself (one regex token in each of two gates in lib/seat-lib.sh), the test pin (9c, two assertions), and the seat-caps.json quota_bench_default_s + dated comment. Each line is load-bearing: the regex tokens close the unknown-classification hole, the test pin prevents regression, and the config value bounds the re-probe so a dead free seat stops burning ~12 claims/hour. No line is removable without reopening the fault.

Closes #4831
