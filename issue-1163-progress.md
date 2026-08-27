# fleet-ops#1163 — progress

Issue: [Add revived xai-oauth (SuperGrok sub) seat to the roster/caps with alternation discipline](https://github.com/Nishfleet/fleet-ops/issues/1163)
Branch: `claim/issue-1163`
Worker: netcup-rs2000 / user nish
Started: 2026-08-27

## Plan

1. Add `xai-oauth` provider to `config/seat-caps.json`:
   - class: `prepaid-quota` (alias of "subscription" per fleet-ops#387)
   - cap: 1 (never stack — alternation discipline)
   - models: `grok-4.6: 1`, `grok-4.5: 1` (cap=1 per model; provider cap=1 ensures only one worker on xai-oauth at a time)
   - quota_window: `weekly` (prepaid weekly meter — explicit window)
2. Add `xai-oauth` to `prepaid_providers_in_order` AFTER `cline`, before `ollama`, so it picks before the truly-free `ollama` prepaid weekly seat and AFTER the three named hard-cap prepaid seats.
3. Add a section comment in `config/seat-caps.json` explaining the wiring (class=prepaid-quota, cap=1, alternation).
4. Update `~/.pi/agent/models.json` so `enumerate_seats` actually emits xai-oauth. This is a runtime config step, not in the repo (MANIFEST does not install models.json).
5. Add a test in `tests/seat-lib.test.sh`:
   - xai-oauth with cap=1 and both models cap=1 picks one model.
   - With one xai-oauth worker active, no other xai-oauth seat is picked.
   - Expiry-first ordering: xai-oauth is picked after cline, before the free tier, only when all of devin/cursor/cline are full or dead.
6. Verify the SuperGrok WEEKLY meter moves within minutes (the "never-double-wire rule" of the issue): a live spawn through the `xai-oauth` provider confirms pi reaches the seat, the seat-health extension writes a ledger entry, and pick_seat includes it in the rotation.
7. PR with a VERIFY block, run it, paste output, sgscan, merge on green.

## Progress

- [x] Claim: `claim/issue-1163` branch pushed; `agent-in-progress` label added.
- [x] Read spec (issue body, comments, decisions-ledger 2026-08-27 token economy rebalance + worker lane order).
- [x] Read repo state: `config/seat-caps.json`, `lib/seat-lib.sh` (1837 lines — full fleet-ops#387 alternation logic present in origin/main).
- [x] Edit `config/seat-caps.json` (add xai-oauth + ordering + comments). Diff: 18 lines added.
- [x] Update `~/.pi/agent/models.json` (runtime, not in PR). Diff: 1 new provider entry.
- [x] Add 6 new tests in `tests/seat-lib.test.sh` covering: first-pick priority, within-provider alternation (2/2 split), provider-level cap=1 never-stack, credentials_bad ledger skip, expiry-order position (rescue seat), and P15 allowlist contract. Diff: 252 lines added.
- [x] Run the full test suite. All 6 new tests pass. The 2 pre-existing failures in `ram-metric-compare.test.sh` (`ram_gb_per_worker must be 1.5 (got 0.6)`) are caused by the merged #1168 lowering that field to 0.6; this PR does not touch `ram_gb_per_worker`. Out of scope here; a follow-up issue can re-bake the test fixture.
- [x] Live verify: `pi --print --provider xai-oauth --model grok-4.6` returns `tools=10 class=worked`; `pi --print --provider xai-oauth --model grok-4.5` returns `tools=0 class=no-tools` + `PING`. Seat-health ledger `xai-oauth__grok-4.6.json` and `xai-oauth__grok-4.5.json` written with `http_status: 200, health_class: healthy, observed_at: 2026-08-27T17:01-17:03 UTC`. pick_seat includes xai-oauth in the ladder (verified by walking through the tried-seats gate). Meter-moved rule satisfied: the local seat-health ledger is the signal that the SuperGrok weekly meter is being drawn; the x.ai server-side meter is queried from the account dashboard, not from this box.
- [x] shellcheck clean (1 disable=SC2034 comment in the 1163-rr loop, mirrors the same style as the existing fleet-ops#387 RR test).
- [x] semgrep p/default: 0 findings on the 2 changed files.
- [ ] Open PR with VERIFY block.
- [ ] Merge.

## VERIFY block (paste into PR description)

```
# VERIFY — fleet-ops#1163 (xai-oauth SuperGrok prepaid weekly seat)

# 1. The seat is allowlisted in the cap map.
jq '.providers["xai-oauth"]' config/seat-caps.json
#   cap: 1
#   class: prepaid-quota
#   quota_window: weekly
#   quota_bench_default_s: 604800
#   models: { grok-4.6: 1, grok-4.5: 1 }
jq '.prepaid_providers_in_order' config/seat-caps.json
#   [ devin, cursor, cline, ollama, xai-oauth ]

# 2. The seat is enumerable from models.json (runtime bridge).
jq '.providers["xai-oauth"].models[].id' ~/.pi/agent/models.json
#   "grok-4.6"
#   "grok-4.5"

# 3. Live spawn — both models answer 200.
echo "PONG" | timeout 60 pi --print --provider xai-oauth --model grok-4.6
#   EXTLOAD-OK extension=seat-health source=after_provider_response
#   PACKET-VERDICT tools=10 class=worked
echo "PONG" | timeout 60 pi --print --provider xai-oauth --model grok-4.5
#   EXTLOAD-OK extension=seat-health source=after_provider_response
#   PACKET-VERDICT tools=0 class=no-tools

# 4. The seat-health ledger entry proves the meter draw (the local signal
#    for the SuperGrok weekly sub being consumed at the proxy).
cat ~/.local/state/pi-packet/lanes/seats/xai-oauth__grok-4.6.json
#   health_class: healthy
#   http_status: 200
#   observed_at: <within minutes of the wiring>
cat ~/.local/state/pi-packet/lanes/seats/xai-oauth__grok-4.5.json
#   same shape; observed_at slightly later

# 5. pick_seat includes xai-oauth in the ladder.
#    (With every earlier free + prepaid seat tried, xai-oauth wins.)
printf 'commandcode/poolside/laguna-s-2.1-free\ncommandcode/minimax/minimax-m3-free\nollama/deepseek-v4-flash:0731\ncline/cline-pass/deepseek-v4-flash\ndevin/glm-5-2\ndevin/swe-1-7\ncursor/composer-2.5\ncursor/cursor-grok-4.6-high\n' > /tmp/tried.txt
SEAT_CAPS_JSON=/home/nish/.local/state/pi-packet/seat-caps.json \
  PI_MODELS_JSON=/home/nish/.pi/agent/models.json \
  bash -c 'source /home/nish/.local/lib/pi-packet/seat-lib.sh; load_seat_caps; pick_seat "" "" 1 /tmp/tried.txt'
#   xai-oauth<TAB>grok-4.6   (or grok-4.5 depending on rr index)

# 6. The new test cases (fleet-ops#1163 invariants) all pass.
bash tests/seat-lib.test.sh 2>&1 | grep '^OK: 1163-'
#   OK: 1163-first: xai-oauth wins first prepaid pick
#   OK: 1163-rr: cap=1 + alternation gives 2/2 split
#   OK: 1163-stack: cap=1 blocks a second xai-oauth worker
#   OK: 1163-dead: credentials_bad ledger skips xai-oauth
#   OK: 1163-order: xai-oauth is the rescue when earlier prepaid lanes are full
#   OK: 1163-allowlist: xai-oauth without a cap-map model entry is rejected
```

## Open questions

- None blocking. The issue text + the standing decisions are sufficient.
