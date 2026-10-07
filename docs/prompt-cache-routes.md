# Prompt-cache routes: per-vendor verdicts and the Pi zero-cache cause

Read-only research for fleet-ops#9357. Every number below was read off this
box on 2026-10-07 and can be re-read with the command printed under it.

## 1. The metric pair is the right denominator

The alert uses

```
rate(litellm_input_cached_tokens_metric_total[1h])
  / rate(litellm_input_tokens_metric_total[1h])
```

`litellm_input_tokens_metric_total` is fed `standard_logging_payload["prompt_tokens"]`
(`litellm/integrations/prometheus.py`, the `.inc(... prompt_tokens)` call), and on
both response shapes this proxy sees, `prompt_tokens` **already contains** the
cached part:

- OpenAI: `prompt_tokens_details.cached_tokens` is a subset of `prompt_tokens`.
- Anthropic: `prompt_tokens` is `cache_read_input_tokens` +
  `cache_creation_input_tokens` + fresh input.

Measured share per requested model (so every value is <= 1, which is what makes
this safe as a share). This PromQL, against the live Prometheus, is what
produces the share column:

```
sum by (requested_model) (rate(litellm_input_cached_tokens_metric_total[1h]))
  /
sum by (requested_model) (rate(litellm_input_tokens_metric_total[1h]))
```

| requested_model | input tokens | cached tokens | share |
| --- | --- | --- | --- |
| worker-capable | 3.057e9 | 2.306e9 | 0.754 |
| worker-cheap  | 1.266e8 | 8.366e7 | 0.661 |
| senior         | 4.700e6 | 3.816e6 | 0.812 |
| judge          | 1.836e6 | 1.530e6 | 0.833 |

The raw per-deployment counters behind that table, straight off the proxy:

```
curl -sL 127.0.0.1:4000/metrics | grep -E '^litellm_(input_tokens|input_cached_tokens)_metric_total'
```

## 2. Why a zero-cache rung reports nothing at all

LiteLLM only emits a cache counter when the provider's own `usage` block
carries one of three keys (`litellm/types/utils.py`, the `Usage` constructor):

- `prompt_tokens_details.cached_tokens` (OpenAI shape)
- `cache_read_input_tokens` (Anthropic shape)
- `prompt_cache_hit_tokens` (DeepSeek shape)

If the provider sends none of them, `prompt_tokens_details` stays `None` and
there is no cache number to report. Nothing in fleet-ops config changes this:
for an OpenAI-compatible chat endpoint, prompt caching is server-side and
automatic, and LiteLLM actively **strips** the Anthropic-only `cache_control`
marker before sending (`remove_cache_control_flag_from_messages_and_tools` in
`litellm/llms/openai/chat/gpt_transformation.py`), so there is no client flag
that could turn caching on.

## 3. Per-vendor verdicts for the four zero-cache routes

Each verdict is one query over the spend log's stored provider `usage` object:

```
psql "postgresql://litellm@localhost:5432/litellm" -At -F'|' -c \
  "SELECT model_id, count(*) AS calls,
          count(*) FILTER (WHERE metadata->'usage_object'->'prompt_tokens_details' = 'null'::jsonb) AS null_details,
          count(*) FILTER (WHERE metadata->'usage_object'->'prompt_tokens_details' IS NOT NULL
                           AND metadata->'usage_object'->'prompt_tokens_details' <> 'null'::jsonb) AS has_details
     FROM \"LiteLLM_SpendLogs\"
    WHERE prompt_tokens > 0 AND \"startTime\" BETWEEN '2026-10-07 06:20:00' AND '2026-10-07 07:40:00'
    GROUP BY model_id HAVING count(*) > 20 ORDER BY 2 DESC"
```

The same 80-minute window, so the rows are directly comparable:

| rung (`model_id`) | calls | `prompt_tokens_details: null` | has cache details |
| --- | --- | --- | --- |
| minimax-m31-worker-capable | 330 | 0 | 330 |
| **cline-lagunas21-worker-capable** | **230** | **230** | **0** |
| stepfun-step5previewj-worker-capable | 221 | 0 | 221 |
| stepfun-step5previewb-worker-capable | 193 | 1 | 192 |
| opencodego2-ds41flash-worker-capable | 134 | 0 | 134 |
| pareto-glm53flash-worker-capable | 90 | 0 | 90 |
| zen-spacebunny-worker-capable | 28 | 0 | 28 |

| vendor | verdict | proof |
| --- | --- | --- |
| cline | **Unsupported / not reported.** Not a fleet bug. | Every one of 230 calls on `cline-lagunas21-worker-capable` in the window has `prompt_tokens_details: null`. The Cline free/quota API returns a bare `usage.prompt_tokens`. No config change can make a vendor report a number it does not send. |
| zai | **Unsupported / not reported.** | Real traffic rows (e.g. `zai-glm53flashg-worker-capable`, prompt_tokens 32927 / 78952 / 32266) all carry `"prompt_tokens_details": null`. The row already declares `cache_read_input_token_cost`, which is a cost hint, not a request flag. |
| ollama | **Unsupported / not reported, and LiteLLM cannot surface it.** | The row uses `ollama_chat/`, whose transformation builds `litellm.Usage(prompt_tokens, completion_tokens, total_tokens)` with no `prompt_tokens_details` at all (`litellm/llms/ollama/chat/transformation.py`). Ollama's own `prompt_eval_count` is a single already-aggregated number with no cache field split out, so there is nothing for LiteLLM to read even if Ollama caches. |
| openrouter | **Unsupported / not reported.** | Real rows on `openrouter-nemotronultra-worker-capable` carry `"prompt_tokens_details": null`. OpenRouter does return cache fields on models that support them, so this is a property of the specific `:free` rows this fleet uses, not of LiteLLM's OpenAI-compatible path. |

Together these four vendors carry about 5.4e8 input tokens, and served 425 of
the 3,385 `worker-capable` calls in the measured 6h window, so 12.5% of the
router's calls for that alias land on a rung that reports no cache field:

```
sum(increase(litellm_deployment_success_responses_total{requested_model="worker-capable", model_id=~"cline.*|zai.*|ollama.*|openrouter.*"}[6h]))
```
over the same query without the `model_id` filter.

**No LiteLLM config change is warranted.** The rows already carry
`cache_read_input_token_cost` where a provider documents a cached-read price,
which is the only cache-shaped knob an OpenAI-compatible row has. Adding
anything else would be a flag LiteLLM ignores.

## 4. Why two Pi sessions read exactly zero

LiteLLM pins a session to one deployment, so a session that lands on a
zero-cache rung stays there and reports 0 on every turn, while its input
prefix grows normally. Both sessions named in the issue were pinned to the
same rung.

Session `01a1150b-798a-7373-83f0-7834f42c432e`, directory `agent-0509-7247`,
segment `2026-10-07T06-27-15-979Z`, 159 turns, 9,993,133 input tokens,
`cacheRead: 0` on every turn. Its per-turn prompt token counts match the
spend log exactly. Prompt-token counts repeat across sessions, so the join is
time-bounded to the segment's own first turns:

```
psql "postgresql://litellm@localhost:5432/litellm" -At -F'|' -c \
  "SELECT model_id, prompt_tokens, (metadata->'usage_object'->'prompt_tokens_details')::text
     FROM \"LiteLLM_SpendLogs\"
    WHERE prompt_tokens IN (28836,28986,29107)
      AND \"startTime\" BETWEEN '2026-10-07 06:27:16' AND '2026-10-07 06:27:40'
      AND model_id LIKE '%worker-capable%' ORDER BY \"startTime\""
```

| turn | Pi session input | spend-log rung | spend-log prompt_tokens_details |
| --- | --- | --- | --- |
| 1 | 28836 | cline-lagunas21-worker-capable | null |
| 2 | 28986 | cline-lagunas21-worker-capable | null |
| 3 | 29107 | cline-lagunas21-worker-capable | null |

Session `01a11520-f75c-77aa-99c4-37f7f74add55`, directory
`agent-0509-7233-miss`, segment `2026-10-07T06-50-44-445Z`, 66 turns,
4,839,636 input tokens, `cacheRead: 0` on every turn, also pinned to
`cline-lagunas21-worker-capable` (turns at 24399 / 25214 / 25416 / 31396 all
match that rung, under the same time-bounded join between 06:50:44 and
06:51:15).

**Named rung:** `cline-lagunas21-worker-capable`.
**Named cause:** Cline returns a `usage` block with no cache field, so
LiteLLM has nothing to put in `prompt_tokens_details` and Pi's
`usage.prompt_tokens_details.cached_tokens` reads 0. The prefix itself was
fine: `input` rises monotonically (28836 -> 28986 -> 29107 -> 94526) and
`cacheWrite` is 0 because an OpenAI-compatible provider does not report a
cache write either. Nothing about these sessions' prompts broke caching.

The pinning is visible inside `agent-0509-7247` itself. Its two segments, same
directory and same `worker-capable` model, split cleanly by rung:

| segment | turns | input | cacheRead |
| --- | --- | --- | --- |
| 2026-10-07T06-27-15-979Z | 159 | 9,993,133 | 0 |
| 2026-10-07T07-23-22-020Z | 78 | 185,897 | 4,980,992 |

The 06:27 segment is pinned to the Cline rung and caches nothing; the 07:23
segment lands on caching rungs and reads 4,980,992 cached tokens. The model
alias is not the variable, the rung is.

The issue recorded these sessions mid-flight (156 and 43 turns); the counts
above are final, read after the sessions ended on 2026-10-07.

## 5. What the alert does and does not cover

`config/grafana/provisioning/alerting/prompt-cache-hit.yaml` watches the share
per `requested_model`. It deliberately does **not** alert on the four vendors
above, because a total-zero cache for a vendor that reports no cache field is
not a regression. If a vendor that does report caching today stops, the share
for its alias falls and the rule fires.

The rule is unit-tested with `promtool`. The fixture
`config/grafana/provisioning/alerting/prompt-cache-hit.test.yml` carries the
exact A expression from `prompt-cache-hit.yaml` inlined in
`prompt-cache-hit.test.rules.yml`, so the test cannot drift from the deployed
query. Run it with:

```
promtool test rules config/grafana/provisioning/alerting/prompt-cache-hit.test.yml
```

It covers nine cases in two kinds, because they check different things. The
six `alert_rule_test` cases run the rule through the Prometheus alert engine,
which fires on any series the expression returns, so they answer "which lanes are
in the result":

1. a high-volume lane whose cache dropped to ~0.2 fires;
2. a healthy high-volume lane is silent;
3. a low-volume probe lane with zero cache is silent, held off by the volume
   floor;
4. a broken lane beside a healthy one in the same scrape fires for the broken
   one only, so the `and on (requested_model)` does not cross lanes;
5. a **total** cache failure (cached series present and exactly 0) fires;
6. a lane whose **cached series vanished entirely** while input kept flowing
   fires, via the `or (0 * input)` branch.

The three `promql_expr_test` cases answer what the alert_rule_test cases cannot:
not which series appear, but **what Grafana's threshold step then reads**.
Grafana's C is a threshold of `> 0` over A, so a lane reads Alerting at 1 and
Normal at 0:

7. a total cache failure, share exactly 0, returns **1**, so it pages;
8. a healthy busy lane returns **0** beside a broken one at **1**, and a
   sub-floor lane is absent from the result entirely (which is what makes
   `noDataState: OK` the right policy for an idle fleet);
9. a vanished cached series with input still flowing returns **1**.

That split is load-bearing. Query A ends in `bool`, so it returns the 0/1 breach
verdict rather than the ratio, and the inlined test rule wraps it in `> 0` to
reproduce the threshold the Prometheus engine does not have. The `bool` is what
makes case 7 fire at all:

```
# pre-fix A (no `bool`), case 7's series, threshold applied by hand (fires iff > 0):
#   exp 1E+00   got 0E+00        -> a 0% share read 0, `0 > 0` is false, Grafana held it Normal
# current A, all nine cases -> SUCCESS
```

Without `bool` only shares strictly between 0 and 0.5 would have paged, and the
case this rule exists for, a route that cached nothing at all, would have stayed
silent while every request paid full input price.