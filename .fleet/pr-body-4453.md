## Summary

Land Pareto Inference (Pareto Pass, $3/week, $20/day) as a prepaid worker seat.

- `config/pi-models.json`: provider `paretoinference`, base `https://api.paretoinference.com/v1`, OpenAI chat-completions, key via `!cut -d= -f2 /home/nish/fleet2/etc/paretoinference.env`. Workers `deepseek/deepseek-v4-flash` and `z-ai/glm-5.3-flash`; `z-ai/glm-5.3` registered then capped 0. `compat.maxTokensField=max_tokens` (the API 400s if both `max_tokens` and `max_completion_tokens` are sent). `reasoning_effort: low`, `maxTokens` 8192.
- `config/seat-caps.json`: cap 4, `max_probe_ceiling` 8 (AIMD +1 on clean, hold after the first concurrency 429), class `prepaid-quota`, `daily_budget_usd` 20, `daily_stop_usd` 19.50, `quota_bench_default_s` 900. First in `prepaid_providers_in_order` (daily allowance expires; unused $ is lost).
- `config/entitled-seats.json`: prepaid-quota, daily window, docs cited.
- Spend meter on the existing prepaid-usage counter (`usd_today`): token-derived because live `usage.cost` is 0.0 on the Pass. Stop offering the seat at $19.50. First 429-after-budget and first 200-after-reset logged in that same file. 429 never writes `seat_dead`.
- `bin/pi-issue-run`: `--no-context-files --thinking low` on this provider (context is the cost; no AGENTS.md dump).

Docs: https://docs.paretoinference.com/ https://docs.paretoinference.com/api-reference.md https://docs.paretoinference.com/errors.md https://docs.paretoinference.com/pareto-pass.md

Closes #4453

## Verification

```
$ bash tests/seat-lib-provider-daily-budget.test.sh
ALL OK: fleet-ops#4453 provider daily-budget spend meter replay drill
EXIT: 0

$ bash tests/entitled-wired-canary.test.sh
OK: scenario6: production entitled-seats.json matches seat-caps.json
EXIT: 0

$ bash tests/seat-caps-citation.test.sh
OK: paretoinference: cap carries a dated reason with a measurement (rule 1)
OK: paretoinference/z-ai/glm-5.3: cap=0 object with intentional_cap_zero + dated reason
EXIT: 0

$ jq '.providers.paretoinference | {cap,class,daily_budget_usd,models}' config/seat-caps.json
cap 4, class prepaid-quota, daily_budget_usd 20, glm-5.3 cap 0

$ curl -sS -o /tmp/pareto-models.json -w "http=%{http_code}\n" https://api.paretoinference.com/v1/models
http=200
deepseek/deepseek-v4-flash
z-ai/glm-5.3
z-ai/glm-5.3-flash

$ chat completions deepseek/deepseek-v4-flash max_tokens=16 reasoning_effort=low
http 200
content PONG
prompt_tokens 10
completion_tokens 34
cached_tokens 0
cost 0.0
```

run-proof: tests/seat-lib-provider-daily-budget.test.sh ALL OK; live GET /models http=200; live chat http=200 PONG prompt_tokens=10 cost=0.0 (token-derived meter required); sgscan --base origin/main: no new findings; tests/pi-issue-run-hang-stall-bench.test.sh OK.

research: https://docs.paretoinference.com/ (base URL, OpenAI chat-completions, Bearer); https://docs.paretoinference.com/api-reference.md (max_tokens XOR max_completion_tokens, store:true → 400, reasoning_effort, GET /models unauthenticated); https://docs.paretoinference.com/errors.md (401 bad key, 429 quota OR concurrency, key rotation does not reset the allowance); https://docs.paretoinference.com/pareto-pass.md ($3/week, $20/day credits, rate card).

help-first: `pi --help` lists `--no-context-files` (trimmed prefix, no AGENTS.md) and `--thinking <level>`; no `--max-turns` exists. `prove-one-run-check --help`, `research-before-build-check --help`, `fleet-exec-review-canary --help`, `sgscan --help`, `fleet-organ-heartbeat-check gate --help`.

net-positive-because: one new prepaid worker seat plus the token-derived daily spend meter on the existing prepaid-usage counter; glm-5.3 is cap 0; no new units or timers.

organ-heartbeat: lib/seat-lib.sh not-an-organ: existing seat picker, not a new unit. bin/pi-issue-run not-an-organ: existing worker wrapper, extra argv only for this provider.

loose-ends: session-call-ceiling-40: pi has no --max-turns, so a hard 40-call kill is mechanism-impossible without a new watcher; hang-watchdog remains. observe-to-close: `grep -c 'SUCCESS on paretoinference/' ~/.local/state/pi-issues/*.err` after deploy; post the first-20-sessions prompt_tokens/call median on #4453. A full pi-issue SUCCESS cannot run until install.sh copies pi-models.json onto the live agent.

## Test plan

- [x] Replay drill: below stop offered, at stop benched, usd_today written, other-provider/yesterday ignored, 429-after-budget flagged, 25×429 does not corpse
- [x] Live accept jq: cap 4 / daily_budget_usd 20 / glm-5.3:0 / first prepaid
- [x] Live Pareto GET /models + one chat completion (PONG, cost 0.0)
- [ ] After merge: fleet draws the seat; 10 SUCCESS lines within 24h; usd_today never exceeds 20.00
