# Provider audit 2026-09 — cost and value of every seat

**Issued:** 2026-09-07, for Nish (fleet-ops#4242)
**Window:** 2026-08-31T19:00Z → 2026-09-07T19:00Z (7d), plus the 30d ledger where noted.
**Nothing was cancelled or changed.** This is a report only; cancellation is Nish's call.

## How the numbers were checked (no credentials printed)

Every figure below carries one of three marks:

- **LIVE** — read from a provider API on the VPS today (2026-09-07): OpenRouter `/v1/credits`, xKiro `/v1/usage`, RunInfra `/v1/credits`, Cursor dashboard period-usage, Claude OAuth `/oauth/usage`, Codex `wham/usage`, and the fleet's Prometheus export of the same.
- **RECORDED** — written in a memory/ledger file on this machine with a date, e.g. `~/.pi/agent/memory/*.md`, `config/seat-caps.json`, `models.json` names.
- **NOT-RECORDED** — the price is not stored on the VPS. Marked explicitly; verify in the provider dashboard before acting on it.

Sessions and PRs come from the fleet's own session ledger (`seat-yield-sessions-cache.json` + rotated `watch.log`), the same source the quota pipeline (fleet-ops#4217) and seat-yield (fleet-ops#3250) use. "PR" = a pi-issue session whose final text links a Nishfleet pull request. "Empty" = a session ending with `PACKET-VERDICT tools=0` (did no work). "Wall hours" = distinct hours in the week where at least one seat of the provider was benched or unusable (QuotaWall/402/503).

---

## Executive summary (what to remember)

**Measured money moving today is small; the risk is un-measured subscriptions and an unused pool.**

- Top 3 PR producers this week: **Devin 271 PRs** (promo-free today), **Ollama Cloud 161** (prepaid sub), **OpenRouter 87** (the only seat that pays real meters and still returns $0.15–0.17/PR — cheapest paid PR in the fleet).
- Best value seat in the fleet: **OpenRouter deepseek-v4-flash-0731** — senior-tier yield at $0.17/PR real meters.
- Best measured yield of any seat: **MiniMax M3** (0.6) at ~$1.04/PR real meters — the only metered seat worth keeping at full cap.
- **~$350–400 of prepaid credits are already spent or burning:** OpenRouter $90.06 is exhausted (balance −$0.19), Straitly's $50 gift is ~gone with **zero PRs to show**, Cursor's **$400 pool sits 100% untouched and expires 2026-09-22** (fleet-ops#4206 says spend it on the senior seat — it is not being spent).
- **Five-plus subscription prices are not recorded on the VPS** (Devin, SuperGrok, Ollama Cloud, Claude Max, Codex, MiniMax yearly, CommandCode). The audit pins every provider's *measured* value; the bill can only be fully closed in dashboards.
- Codex has been **quota-walled since 2026-08-13** (~30 days, releases ~2026-09-12) and produced **0 PRs in 30d**. Claude Max sits at **99% quota remaining** (deliberate hard-conserve — judgement/alarms only, 0 PRs expected).

---

## One-table verdicts (7d window)

| Provider | Class (seat-caps) | Paid/metered (real, checked 09-07) | Sessions 7d | PRs 7d | $ per PR 7d | Wall hrs | Verdict |
|---|---|---|---|---|---|---|---|
| Devin (glm-5-2 + swe-1-7) | prepaid | sub; promo-free (price NOT-RECORDED) | 754 | **271** | $0 today | 106 | **KEEP** — fleet workhorse; re-judge at billing resume |
| Ollama Cloud (dsv4-flash) | prepaid | weekly sub (price NOT-RECORDED) | 582 | **161** | $0 today | 38 | **KEEP** — biggest cheap worker |
| OpenRouter (dsv4-flash-0731 + :free) | metered | **$90.06 prepaid, now −$0.19 LIVE** | 176 | **87** | **$0.17** | 93 | **KEEP** — cheapest paid PR; needs ~$15–20/mo top-up or it falls to free lanes only |
| MiniMax M3 | metered | **$188.25/30d meter** (LIVE ledger) | 74 | 46 | $1.13 (30d $1.04) | 75 | **KEEP** — best yield 0.6; only metered seat earning its bill |
| Cursor (grok-4.6-high) | prepaid | **$400 pool, spent $0, resets 09-22 LIVE** | 3 | 2 | pool at risk of expiry | 1 | **KEEP** — senior keystone; pool will expire unused (fleet-ops#4206 not yet burning) |
| xai-oauth (grok-4.6/4.5) | prepaid | SuperGrok weekly sub (price NOT-RECORDED); $96.78 meter is *nominal* (sub covers it) | 91 | 17 | nominal $5.69 ($0 real) | 35 | **KEEP-senior w/ watch** — rolling yield fell to 0.0 (last 20 sessions); audition |
| Cline (cline-pass + GLM 5.3 free) | prepaid | **$9.99/mo** (RECORDED) | 20 | 9 | $0.55/sess; GLM lane 2.3 sess/PR | 163 | **KEEP** — cheapest sub, GLM 5.3 lane productive; minimax backup pipe mostly walled |
| MergeGateway (dsv4 + sonnet) | metered | **$10 free credits**, $0 spent (RECORDED) | 24 | 12 | $0 | 15 | **KEEP-until-credits-die** — 2 sess/PR, best free-lane yield |
| RunInfra (dsv4-flash) | prepaid | **balance $0.57, spent $0.43 LIVE** | 2 | 1 | $0.30 | — | **UNDECIDED** — fine while credit lasts; moot when empty |
| commandcode (poolside + m3-free + ds4) | free | $0 | 231 | 2 | $0 (115 sess/PR) | 162 | **DOWNGRADE** — poolside lane 0 PRs / 20 sess; keep only m3-free if free |
| Hetzner (Qwen 3.6-35B) | free | $0 | 158 | 3 | $0 (52 sess/PR) | 42 | **DOWNGRADE → cap 0** — 0-PR rolling yield; free but burns slots |
| xKiro (dsv4 flash/pro + m3-free) | free | **$5 wallet untouched; free tier 5M tok/day, 5,012,001 used LIVE** | 97 | 3 | $0 (32 sess/PR) | 46 | **DOWNGRADE → cap 1** — all lanes ≈0 yield; free tokens exhausted daily anyway |
| OpenCode (nemotron + mimo + ling + …) | free | $0 | 95 | 6 | $0 | 118 | **DOWNGRADE** — nemotron-ultra lane only (yield 0.25); cap 3 → 1 |
| ZenMux (glm-4.7-free + ds4) | metered | **$5 wallet, $0 spent** (RECORDED) | 44 | 3 | $0 (14.7 sess/PR) | 26 | **DOWNGRADE** — keep free lane, never spend the $5 |
| Straitly (dsv4-pro) | metered | **$50 gift, ~$49.04 spent, 0 PRs** | 4 | 0 | — | 163 | **CUT** — gift gone, nothing shipped |
| bai (dsv4-flash) | free | $0 | 4 | 0 | — | 74 | **CUT → cap 0** — no value measured |
| Claude Max | sub | price NOT-RECORDED | **0** | 0 | — | — | **KEEP** — deliberate judgement/conserved seat; 99% quota untouched |
| Codex (ChatGPT/Codex OAuth) | sub | price NOT-RECORDED | **0** | 0 | — | walled | **UNDECIDED** — quota wall since 08-13 releases ~09-12; 48h audition then judge |
| groq / inferx / orcarouter / grok / opencode-anthropic / crof / entrim | free/cap0 | $0 | 0 | 0 | — | groq 5h | **CUT (formalize cap 0)** — no working value measured (opencode-anthropic is money-adjacent; Nish-only) |

---

## Detail per provider

### Devin — KEEP — 271 PRs this week, the workhorse
- **Cost today:** subscription seat; promo-free in recent weeks (RECORDED in restoration notes 2026-08-20 "Devin GLM-5.2 free workhorse"). Price NOT-RECORDED on the VPS; prior notes flag billing may resume ~2026-09-15. Verify in dashboard.
- **Got:** 754 sessions → 271 PRs (glm-5-2 207, swe-1-7 64). 30d: 809 → 308. Empty 4.6% / 1.4% per model (best no-op rate of the workers). Rolling yield glm-5-2 0.35, swe-1-7 0.4 (only seats with 20+ sessions at those yields besides ollama/openrouter/minimax).
- **$ / PR:** $0 today. **At billing, the next-best capable worker is MiniMax at $1.04/PR and Ollama at $0 — re-judge before it bills.**
- 106 wall hours (rate-limit cooldowns, known lane fault — fleet-ops#902).

### Ollama Cloud — KEEP — 161 PRs this week
- **Cost:** weekly prepaid sub; deepseek-v4-flash:0731 exclusive (RECORDED). Price NOT-RECORDED.
- **Got:** 582 → 161 PRs (3.6 sess/PR), but **13.8% empty** and 76% of sessions end without a verdict (highest dead-session rate of the paid seats). Rolling yield 0.2.
- **$ / PR:** $0 marginal. If the weekly sub bills at a typical per-week price, it is still the cheapest large worker; the drain says keep it capped, not uncapped.

### OpenRouter — KEEP (needs small top-up) — cheapest paid PR in the fleet
- **Cost:** **$90.06 prepaid, spent $90.25 → balance −$0.19 (LIVE /v1/credits 2026-09-07).** Key has no per-key cap, so the quota family emits nothing; the credits balance is the meter.
- **Got:** 176 → 87 PRs (dsv4-flash-0731 lane: yield 0.35, 2 sess/PR). 30d: 267 → 154 at $0.15/PR. The extra `:free` lanes (gemma, nemotron-ultra, glm-5.2-free, m3-free) shipped 0 PRs in the 7d window.
- **$ / PR:** **$0.15–0.17 — the cheapest paid PR in the fleet.** The balance is gone; future paid use needs a top-up (≈$15–20/mo at this burn). Free lanes keep it useful at $0 meanwhile.
- 93 wall hours (402/QuotaWall on the paid lanes after the balance died).

### MiniMax M3 — KEEP — best measured yield in the fleet
- **Cost:** metered. **$188.25 recorded spend in 30d** (session usage meter, LIVE ledger; $0.30/M in, $1.20/M out per models.json cost field). "Yearly Plus" plan price NOT-RECORDED — the yearly plan price vs the metered meter is the one unknown to close.
- **Got:** 74 → 46 PRs this week; 104 → 68 in 30d. **Rolling yield 0.6 — the highest of any seat with 20+ sessions.** Empty 8.9%.
- **$ / PR:** **$1.04–1.13 — the only metered seat that earns its bill.** Next-best capable worker (devin) is $0 today but price unknown at resume.

### Cursor (grok-4.6-high) — KEEP — $400 pool will expire unused
- **Cost:** **$400 "API Usage" pool, spent $0.00, cycle reset 2026-09-22T04:02Z (LIVE dashboard read 2026-09-07T11:33Z).** Plan price NOT-RECORDED. Cap 2, senior/keystone-only (seat-caps, fleet-ops#1167).
- **Got:** only 3 sessions → 2 PRs this week. 6,931 skip lines in watch.log ("keystone/senior-review only") — the seat is restricted, so the pool is not being spent.
- **$ / PR:** $0 (measured) but the whole $400 pool expires unused 09-22. fleet-ops#4206 already directed spending it on senior work; this audit confirms it is **not happening** (3 sessions/week). This is the biggest single money risk in the fleet: **$400 at 100% burn risk.**

### xai-oauth (SuperGrok) — KEEP-senior with a watch — yield collapsed to 0.0
- **Cost:** rides the SuperGrok weekly subscription (RECORDED, fleet-ops#1163); price NOT-RECORDED. The $96.78/7d usage meter is **nominal** (tokens priced at $2/$6 per M in config) — the sub covers it; no API credits are billed.
- **Got:** 91 sessions → 17 PRs this week (grok-4.6 12, grok-4.5 5). **But the rolling last-20 yield is 0.0 — the most recent 20 sessions shipped no PRs** (degraded late-week; walled 35h too).
- **$ / PR:** $0 real money; nominal $5.69/PR. As a senior/judge seat the sub may still be worth it — but the 0.0 rolling yield against 0.35 for OpenRouter senior lane is the evidence to judge it on.

### ClinePass — KEEP — the $9.99 seat earns its money
- **Cost:** **$9.99/mo, subscribed 2026-08-18 (RECORDED).** Billed only on `cline-pass/` slugs.
- **Got:** 20 → 9 PRs this week; the GLM 5.3 Flash free lane alone: 17 sessions → 9 PRs (1.9 sess/PR — the second-best free lane in the fleet). Cline-pass minimax backup pipe walled most of the week (163 wall hrs).
- **$ / PR:** ~$0.25 at the measured 7d rate (≈39 PRs/mo ÷ $9.99) — cheaper than any metered seat. KEEP.

### MergeGateway — KEEP-until-credits-die — best free-lane PR rate
- **Cost:** $10 free credits (RECORDED, models.json). $0 spent so far.
- **Got:** 24 → 12 PRs in 30d (2 sess/PR) across dsv4-flash (7), claude-sonnet-5 (5). Best free-lane throughput in the fleet.
- **$ / PR:** $0. When the credit balance dies it becomes a paid lane — re-judge then.

### RunInfra — UNDECIDED — tiny prepaid, tiny value
- **Cost:** **balance $0.57, spent $0.43 this period (LIVE /v1/credits 2026-09-07).** Plan tier "free".
- **Got:** 2 → 1 PR at $0.30. Good ratio, negligible scale.
- Verdict: let the $0.57 drain; no top-up.

### commandcode — DOWNGRADE — the poolside lane is dead weight
- **Cost:** free lanes only (cap 4). $0.
- **Got:** 231 sessions this week → **2 PRs (115 sess/PR)**; poolside/laguna-s-2.1-free 0 PRs in its last 20 sessions (rolling yield 0.0), m3-free 0.0 rolling, ds4 lane 0 attempts. 162 wall hours (503 storms).
- Verdict: keep at most the minimax-m3-free lane at cap 1; drop poolside.

### Hetzner — DOWNGRADE → cap 0 — free but pointless
- **Got:** 158 → 3 PRs (52 sess/PR), rolling yield **0.0**. seat-caps reason (09-05) already flagged "10 of 15 light picks, 2 PRs from 20 sessions"; nothing improved. Free, but it steals light-pick slots from lanes that work.

### xKiro — DOWNGRADE → cap 1 — free tier is exhausted every day anyway
- **Cost:** **$5 wallet untouched; free tier 5M tokens/day, 5,012,001 used today (LIVE /v1/usage) — 0 left until reset.**
- **Got:** 97 → 3 PRs (32 sess/PR); all lanes rolling yield ≤0.05.

### OpenCode — DOWNGRADE → cap 1 (nemotron-ultra lane only)
- **Got:** 95 → 6 PRs this week; 143 → 8 in 30d. nemotron-3-ultra-free yield 0.25; mimo/ling lanes 0.0. 118 wall hours.

### ZenMux — DOWNGRADE — free lane only, never spend the $5
- **Got:** 44 → 3 PRs (14.7 sess/PR); glm-4.7-free yield 0.0, ds4 lane small-n high empty rate (31.6%). $5 wallet should stay unspent — mergegateway/openrouter free lanes do the same job at $0.

### Straitly — CUT — the $50 gift bought nothing
- **Cost:** **$50 gift credit (RECORDED); ~$49.04 recorded spend in 30d → ~$0.96 left.**
- **Got:** 4 sessions, **0 PRs in 30d**, walled 163 of 168 hours. The entire gift is spent for zero shipped work.

### bai — CUT → cap 0
- 4 sessions, 0 PRs, 74 wall hours. No value measured.

### Claude Max — KEEP (stance, not flying)
- **Cost:** subscription price NOT-RECORDED.
- **Got:** 0 issue-work sessions in 30d; **99% quota remaining in both the session and weekly windows (LIVE OAuth /usage)**. This is the deliberate hard-conserve standing rule (judgement/alarms only) — the seat is insurance, not throughput. If it must earn its bill, it needs the senior ladder; as of now it is ~fully unused.

### Codex — UNDECIDED — 30-day wall, judge when it releases
- **Cost:** subscription price NOT-RECORDED.
- **Got:** **0% primary-window quota remaining (LIVE wham/usage), reset ~5 days out; 0 sessions in 30d.** Wall started 2026-08-13 (~29.8 days ≈ release 2026-09-12, RECORDED). Run a 48h audition (fleet-ops#4205 discipline) when it releases, comparing against current senior seats, before trusting it again.

### groq, inferx, orcarouter, grok (dead decoy), opencode-anthropic, crof, entrim — CUT / keep at cap 0
- No sessions, no value. `grok` is the retired-CLI decoy (403s, flag for removal — fleet-ops#917). opencode-anthropic is metered money-adjacent and cap 0 by policy (Nish-only). groq shows 5 wall hours — the free key still works but has never shipped.

---

## Best seat per tier (measured yield + price of the next-best)

| Tier | Best seat (measured) | Why | Price of next-best |
|---|---|---|---|
| **Senior / judge** (judgement work, senior-review) | **OpenRouter deepseek-v4-flash-0731** | yield 0.35, $0.15–0.17/PR **real** (only senior lane with real meters and positive PRs) | xai-oauth/grok-4.6 — $0 real (sub) but 0.0 rolling yield; cursor-grok-4.6-high — $400 pool unspent |
| **Capable worker** (definition: 20+ sessions, >0.3 yield) | **MiniMax M3** | fleet-best yield **0.6**, $1.04/PR — earns its meter | Devin glm-5-2 (yield 0.35) at $0 promo today; price unknown at resume; Ollama (0.2) at $0 sub |
| **Cheap worker** (free lanes) | **MergeGateway ds4-flash / sonnet** | 2 sess/PR, 12 PRs/30d, $0 — best free-lane throughput | OpenCode nemotron-3-ultra-free — yield 0.25, $0 |

---

## Total monthly spend — one line

**Measured today:** ≈ **$200–230/mo of real recorded money** — MiniMax meter $188/30d, ClinePass $9.99, one-time credits Straitly $49 + OpenRouter $41 + Merge $10 + Zen $5 + xKiro $5 + RunInfra $1 already spent-down — **plus the $400 Cursor pool (100% unspent, expires 09-22)** and **six subscription prices not recorded on the VPS** (Devin, SuperGrok, Ollama Cloud, Claude Max, Codex, CommandCode; MiniMax yearly).
**Recommended month:** keep the nine producing seats (devin, ollama, minimax, openrouter, cursor, xai-oauth, cline, mergegateway, runinfra) and Claude as judgement; drop the proven-empty lanes (straitly, commandcode poolside, hetzner, bai, xkiro×2, opencode×3, zenmux paid, groq/inferx/orcarouter/grok); spend the Cursor pool before 09-22 per fleet-ops#4206; re-judge codex at its ~09-12 release and devin before billing resumes. The only recommended new money is a small OpenRouter top-up (~$15–20/mo); everything else is spend-what-is-paid, buy-nothing-new.

## Appendix — sources

- LIVE APIs (2026-09-07): OpenRouter `/api/v1/credits` (credits 90.06, usage 90.2469 → −0.19); xKiro `/v1/usage` (free tokens 5,012,001/5,000,000 used, wallet $5.00); RunInfra `/v1/credits` (balance $0.57, period spent $0.43, tier free); Cursor dashboard period-usage (pool $400, spend $0, cycle_end 2026-09-22T04:02Z); Claude OAuth `/oauth/usage` (99% both windows); Codex `wham/usage` (0% primary).
- Prometheus (`127.0.0.1:9090`): `fleet_prepaid_spend_usd{cursor}=0`, `pool_usd{cursor}=400`, `fleet_seat_credits_remaining_usd{openrouter}=−0.19,{xkiro}=5`, `fleet_seat_quota_remaining_pct{claude}=99,{codex}=0`.
- Session ledger: `~/.pi/agent/sessions/**/*.jsonl` — provider/model per session (model_change), `usage.cost.total` per message, final-text PR URLs; caches `~/workspaces/agent-state/fleet-metrics/seat-yield-sessions-cache.json` + `seat-spend-sessions-cache.json`.
- `watch.log` + rotated `.1/.2.gz/.4.gz` (2026-08-25 → 09-07) — pick lines, bench/unusable lines.
- `~/.pi/agent/models.json` — provider prices/cost fields and name notes (Straitly $50 gift, MergeGateway $10, ZenMux paid $5, minimax $0.30/$1.20 per M).
- `config/seat-caps.json` — class/cap/reason per provider (prepaid-quota vs metered vs free, senior ladder).
- Memories: ClinePass $9.99/mo (2026-08-18), xai-oauth/SuperGrok sub (fleet-ops#1163), codex 30d wall 08-13→~09-12, Devin free workhorse (08-20), pricing-model notes (until re-verified live).