# 24h after workers compact at 256k

#8637 merged at 2026-09-25T09:02:15Z as `f2314aed5b47f5cdb8f5907ec23e3494222ee4c6`. That commit is on origin/main. Worker `contextWindow` is 296000 in `config/pi-models.json` (the `worker-cheap` and `worker-capable` rows). Live `~/.pi/agent/settings.json` has `compaction.reserveTokens` 40000, so pi compacts at 256000.

This file is the three checks for the 24 hours after that merge, through 2026-09-26T09:02:15Z. The comparison window is the 24 hours before the merge. The GitHub snapshot below was read at 2026-09-26T09:52:18Z.

## Worker prompt tokens and 429s

`LiteLLM_SpendLogs`, `model_group` in `worker-cheap` and `worker-capable`.

```
  win   | requests | prompt_tokens | prompt_tokens_per_hour | avg_prompt |  p50  |  p95   | max_prompt
--------+----------+---------------+------------------------+------------+-------+--------+------------
 after  |    16438 |    1098546559 |               45772773 |      66830 | 58044 | 148397 |     265765
 before |    25495 |    1251660499 |               52152521 |      49094 | 48881 |  80775 |     108731
```

Prompt tokens per hour went from 52,152,521 to 45,772,773. Requests fell from 25,495 to 16,438. Each request carried more prompt: p95 80,775 to 148,397, max 108,731 to 265,765. The max is the 256k line.

429s on worker seats in the after window:

| seat | after 429 | after success | after requests | before 429 | before success |
|---|---:|---:|---:|---:|---:|
| cline-spacebunny-worker-capable | 26 | 556 | 904 | 20 | 874 |
| openrouter-spacebunny-worker-capable | 12 | 543 | 881 | 13 | 882 |
| synthetic-glm53flash-worker-cheap | 1 | 361 | 362 | 0 | 194 |

Every other worker seat had 0 times 429 in both windows. The messages were the daily free-model token quota, a subscription cap, an Anthropic token-plan cap, `Go usage limit exceeded`, and one `no left credit for step plan` on synthetic. cline-spacebunny's 429s ran from 2026-09-25 09:06:37 to 19:59:19, and 6 successes landed after the last one. zen-spacebunny-worker-cheap served the 265,765-token prompt on 2,570 successes and 0 times 429. Those seats kept completing requests, so this run did not open a follow-up issue.

## Context-length errors

Spend-log failures in both windows whose error class or message matched `context window`, `context length`, `ContextWindow`, `maximum context`, `too many tokens`, `prompt is too long`, or `input is too long`: 0 rows.

`LiteLLM_ErrorLogs` has 0 rows.

360 pi session files had mtime inside the after window. One of them, `agent-fleet-ops-8766`, contains the log line `Could not detect context length for model 'worker-cheap' ... defaulting to 256,000 tokens (probe-down)`. That line is a probe default. No session file in the window contains `ContextWindowExceededError`.

Worker sessions started in the window compacted at `tokensBefore` 256430, 257736, 258772, 259708, and 278110. The 264 `agent-0509-*` sessions started in the window have 0 assistant `stopReason` of `length`.

## 0509 issues that ran past 88k

Population: `~/.pi/agent/sessions/agent-0509-*` files whose names start in `[2026-09-25T09-02-15, 2026-09-26T09-02-15)`. Context on an assistant message is `usage.input + usage.cacheRead + usage.output`. An issue ran past 88k when one of its sessions in that window reached a max above 88000.

264 sessions, 119 issues. 110 sessions and 69 issues ran past 88k. The highest context in that set is 277082. Three of those issues have a compaction entry.

GitHub, at 2026-09-26T09:52:18Z: 63 CLOSED, 6 OPEN. 63/69 is 91%. The issue's baseline for compacted workers, from when the line was 88k, is 97/121 (80%). 91% is 11 points above that baseline.

The six open issues each have an open pull request: 0509#5608 for 5266, #5489 for 5351, #5554 for 5353, #5484 for 5433, #5568 for 5437, #5564 for 5510. None of the 69 carry `triage-mass-close`.

## Rollback copy

The three checks hold, so this run deleted `~/.pi/agent/settings.json.bak-2026-09-25`. That copy had `reserveTokens` 8192. After the delete, the path is absent and the live file still has `reserveTokens` 40000.

```
BAK_ABSENT
{'enabled': True, 'reserveTokens': 40000, 'keepRecentTokens': 20000}
```

encoded: 5. These counts are one reading of LiteLLM_SpendLogs and the pi session files. The compaction line they measure is already held by `contextWindow` 296000 in `config/pi-models.json`, which fleet-sync copies onto the host, and by `reserveTokens` 40000 in `~/.pi/agent/settings.json`, which pi rewrites itself.
