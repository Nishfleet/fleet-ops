## seat: land runinfra + zenmux paid worker seats in repo config; install.sh merges unknown provider rows

Closes #4205

### What changed

1. **`config/seat-caps.json`** — land `runinfra` provider row: cap 4, class `prepaid-quota`, `quota_bench_default_s` 86400 (24h), model `deepseek-v4-flash` cap 4, and a `_comment_runinfra` note that RunInfra HTTP 402 is a **balance wall** (Nish-only top-up), never a transient fault. Added `runinfra` to `prepaid_providers_in_order`.

   Scope-add (Nish 2026-09-07 'ollama cloud and the rest', issue comment): also land `zenmux/deepseek/deepseek-v4-flash` as a metered worker seat, cap 2. It answers SEAT-OK live but was absent from the seat-caps models allowlist, so `fleet-seat-comeback-release` logged it as 'absent from seat-caps models but real key' every tick and `pick_seat` never picked it. Meter check (fleet-ops#42: never wire a slug that can bill credits without a meter check): ZenMux is credit-based ($5 flat wallet; /models API returns no per-token pricing, confirmed 2026-08-29 fleet-ops#384), so `daily_spend_cap_usd` is NOT set — Pi `usage.cost` cannot track per-token spend with no pricing, so that meter would be inert and misleading. The meter IS the wallet balance: HTTP 402 when the $5 is exhausted is a balance wall (same 402-as-balance-wall shape as runinfra in this same issue), benched by the provider `quota_bench_default_s=3600` — never a transient fault to retry. The $5 wallet is the hard bound on spend; cap=2 limits concurrency. No `max_probe_ceiling` -> cap pinned at 2 (no upward AIMD probe on a paid seat). Not `product_only`: Nish declared it a worker seat (serves all enrolled repos). Metered class keeps it in the last-resort bucket after free + prepaid. The old `_comment_1442` line that held the paid lane out under #42 is updated to point at the new model reason.

2. **`config/entitled-seats.json`** — add the `runinfra` seat (class `prepaid-quota`, worker-only, 402 = balance wall) so the entitled-wired canary stays green. zenmux was already entitled (metered); adding a model to its allowlist does not change the provider-level entitlement.

3. **`install.sh`** — name the writer that regenerates the live state file and make it merge instead of drop. The writer is `install.sh`'s `file_install` copy branch: it overwrites `~/.local/state/pi-packet/seat-caps.json` from `config/seat-caps.json` on every deploy (regular file COPY, fleet-ops#2910). A hand-added provider row in the live file was silently dropped by that overwrite — the exact bug that lost the runinfra row twice today. New `seat_caps_merge_unknown_providers` merges any provider the repo does NOT declare from the live file into the repo copy before installing, so a hand-wired seat survives a deploy. The repo stays the source of truth for every provider it declares. This only ADDS rows the repo lacks — it never lowers a cap — so it is compatible with the #371 cap-downgrade guard. A targeted `# shellcheck disable=SC2128` marks a false positive: the heredoc in the new helper corrupts shellcheck 0.11's array-tracking for the rest of `process_entry`, so it misreports the plain string `local src=$1` as an array (the same `$src` is used in a `case` at global scope on line 777 with no warning).

4. **`tests/fleet-ops-deploy.test.sh`** — scenario 12h proves the merge: a live state file carrying an unknown provider (`runinfra`) survives an install whose repo config does not declare it, while a repo-declared provider keeps the repo version.

5. **`tests/fleet-token-economy.test.sh`** — update the prepaid-order assertion to include `runinfra` (`ollama devin cline cursor xai-oauth runinfra`). `bin/fleet-prepaid-util-canary` requires every `prepaid-quota` provider to be in `prepaid_providers_in_order`, so the list MUST carry runinfra; the old hardcoded assertion was the blocker.

### Verification

- `shellcheck -x install.sh` → EXIT 0 (SC2128 false-positive suppressed with a dated comment).
- `bash tests/fleet-ops-deploy.test.sh` → EXIT 0 (scenario 12h passes: `OK: scenario12h: install.sh merges unknown provider rows from the live state file (fleet-ops#4205)`).
- `bash tests/fleet-token-economy.test.sh` → EXIT 0 (prepaid order `ollama devin cline cursor xai-oauth runinfra`).
- `bash tests/entitled-wired-canary.test.sh` → EXIT 0 (scenario 6: production entitled-seats.json matches seat-caps.json).
- `bash tests/fleet-prepaid-util-canary.test.sh` → EXIT 0 (scenario 13: production seat-caps passes the prepaid ladder gate).
- `bash tests/seat-lib.test.sh`, `tests/seat-lib-yield-order.test.sh`, `tests/seat-lib-dispatch.test.sh`, `tests/seat-lib-aimd.test.sh`, `tests/seat-floor-failopen.test.sh`, `tests/fleet-free-roster-canary.test.sh`, `tests/paid-flash-canary.test.sh`, `tests/fleet-seat-comeback-release.test.sh`, `tests/seat-health-seat-dead.test.sh`, `tests/audition-lane.test.sh`, `tests/manifest-shape.test.sh`, `tests/seat-lib-org-reserve.test.sh` → EXIT 0.
- `bin/sgscan` → no new security findings. EXIT 0.
- `bin/fleet-no-agent-names-check --commit-range origin/main..HEAD` → `OK: no agent attribution detected`.
- `bin/fleet-token-efficiency-check --name-status <range>` → `OK: no token-efficiency anti-patterns`.
- Live seat-lib trace (production config, `PI_SEAT_LIB_CHECK_TRANSPORT=0`): `runinfra cap=4 class=prepaid-quota`, `runinfra/deepseek-v4-flash model_cap=4`; `zenmux cap=2 class=metered`, `zenmux/deepseek/deepseek-v4-flash model_cap=2`.

run-proof: `shellcheck -x install.sh`, `bash tests/fleet-ops-deploy.test.sh` (scenario 12h), `bash tests/fleet-token-economy.test.sh`, `bash tests/entitled-wired-canary.test.sh`, `bash tests/fleet-prepaid-util-canary.test.sh`, `bin/sgscan`, `bin/fleet-no-agent-names-check`, `bin/fleet-token-efficiency-check` — all green above.

net-positive-because: wires two worker seats (runinfra prepaid cap 4; zenmux paid metered cap 2) into the seat-caps + entitled inventory and fixes the deploy-time drop of hand-added provider rows; the added lines are config + one merge helper + test edits, not new machinery.

loose-ends: none for this PR. Out-of-scope finding (filed separately): `fable-fleet-check-opus.timer` is a live VPS user timer with no MANIFEST entry and no repo timer file on origin/main — `tests/timer-manifest.test.sh` flags it on the VPS (CI has no live fleet timers so it passes there); not caused by this diff.

Post-deploy proof (observe after merge): the next deploy installs runinfra into the live state file; `pick_seat` trace shows `runinfra/deepseek-v4-flash` usable with `model_cap=4`; `zenmux/deepseek/deepseek-v4-flash` is now in the allowlist so comeback-release stops logging it as 'absent from seat-caps models but real key'; a worker session landing on either reports its cost in session usage.

research: no new `bin/` files added (config + existing install.sh + test edits only); no rebuild/masking diff; install.sh is not a fleet organ (not in config/fleet-organs.json), so no organ-heartbeat rule is required.
help-first: n/a (no new `bin/` file).
