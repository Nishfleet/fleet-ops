## seat: land runinfra/deepseek-v4-flash (prepaid worker seat, cap 4) + install.sh merges unknown provider rows

Closes #4205

### What changed

1. **`config/seat-caps.json`** — land `runinfra` provider row: cap 4, class `prepaid-quota`, `quota_bench_default_s` 86400 (24h), model `deepseek-v4-flash` cap 4, and a `_comment_runinfra` note that RunInfra HTTP 402 is a **balance wall** (Nish-only top-up), never a transient fault. Added `runinfra` to `prepaid_providers_in_order`.

2. **`config/entitled-seats.json`** — add the `runinfra` seat (class `prepaid-quota`, worker-only, 402 = balance wall) so the entitled-wired canary stays green.

3. **`install.sh`** — name the writer that regenerates the live state file and make it merge instead of drop. The writer is `install.sh`'s `file_install` copy branch: it overwrites `~/.local/state/pi-packet/seat-caps.json` from `config/seat-caps.json` on every deploy (regular file COPY, fleet-ops#2910). A hand-added provider row in the live file was silently dropped by that overwrite — the exact bug that lost the runinfra row twice today. New `seat_caps_merge_unknown_providers` merges any provider the repo does NOT declare from the live file into the repo copy before installing, so a hand-wired seat survives a deploy. The repo stays the source of truth for every provider it declares. This only ADDS rows the repo lacks — it never lowers a cap — so it is compatible with the #371 cap-downgrade guard.

4. **`tests/fleet-ops-deploy.test.sh`** — scenario 12h proves the merge: a live state file carrying an unknown provider (`runinfra`) survives an install whose repo config does not declare it, while a repo-declared provider keeps the repo version.

### Verification

- `bash tests/fleet-ops-deploy.test.sh` → EXIT 0 (scenario 12h passes: `OK: scenario12h: install.sh merges unknown provider rows from the live state file (fleet-ops#4205)`).
- `bash tests/seat-lib.test.sh` → EXIT 0.
- `bash tests/entitled-wired-canary.test.sh` → EXIT 0 (scenario 6: production entitled-seats.json matches seat-caps.json).
- `bash tests/seat-lib-yield-order.test.sh`, `tests/seat-lib-dispatch.test.sh`, `tests/fleet-seat-live-validate.test.sh` → EXIT 0.
- `bin/sgscan` → `No new security findings.` EXIT 0.
- `bin/fleet-no-agent-names-check --commit-range origin/main..HEAD` → `OK: no agent attribution detected`.
- `bin/fleet-token-efficiency-check` → `OK: no token-efficiency anti-patterns`.
- Live seat-lib trace (production config): `provider_cap(runinfra)=4`, `model_cap(runinfra/deepseek-v4-flash)=4`, `class_of(runinfra)=prepaid-quota`, `model_class_of(runinfra/deepseek-v4-flash)=prepaid-quota`; `enumerate_seats` emits `runinfra deepseek-v4-flash 0 1` (capable=1, contextWindow 1M).

run-proof: `bash tests/fleet-ops-deploy.test.sh` (scenario 12h), `bash tests/seat-lib.test.sh`, `bash tests/entitled-wired-canary.test.sh`, `bin/sgscan`, `bin/fleet-no-agent-names-check`, `bin/fleet-token-efficiency-check` — all green above.

net-positive-because: wires a new prepaid worker seat (runinfra/deepseek-v4-flash, cap 4) into the seat-caps + entitled inventory and fixes the deploy-time drop of hand-added provider rows; the added lines are config + one merge helper + its test, not new machinery.

Post-deploy proof (observe after merge): the next deploy installs runinfra into the live state file; `pick_seat` trace shows `runinfra/deepseek-v4-flash` usable with `model_cap=4`; a worker session landing on it reports its RunInfra cost in session usage.

research: no new `bin/` files added (config + existing install.sh + test only); no rebuild/masking diff; install.sh is not a fleet organ (not in config/fleet-organs.json), so no organ-heartbeat rule is required.
help-first: n/a (no new `bin/` file).
