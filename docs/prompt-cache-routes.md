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
there is no cache number to report. One route is a second case: Ollama's own
API reports a cache counter in a field LiteLLM never reads, so there the
provider does cache and the router still reports nothing. Section 3 has the
proof. Nothing in fleet-ops config changes this:
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
| ollama | **Caches, but LiteLLM cannot surface it.** | The row uses `ollama_chat/`, whose transformation builds `litellm.Usage(prompt_tokens, completion_tokens, total_tokens)` with no `prompt_tokens_details` at all (`litellm/llms/ollama/chat/transformation.py`: `prompt_tokens = response_json.get("prompt_eval_count", ...)`). Ollama's cache counter is a **separate** field, `prompt_eval_cached_count`, and no LiteLLM through 1.105.1 reads it, so the router reports 0 cached while Ollama caches. Re-probed on this box 2026-10-17: one 8839-token prompt posted twice to `https://ollama.com/api/chat` reads `prompt_eval_cached_count: 0` on the first call and **8710 of 8839** on the second, and a real 48-call burst on `ollama_chat/deepseek-v4.1-flash` carries `prompt_tokens_details: null` on every row. Upstream: berriai/litellm#45021. This section's earlier verdict, that `prompt_eval_count` "is a single already-aggregated number with no cache field split out", was wrong: the field exists and is split out, LiteLLM just does not read it (fleet-ops#9881). |
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
per `requested_model`, over the rows whose cache the router can **measure**.
Both sides of the ratio are pinned to that row set with an `and on (model_id)`
filter: the denominator keeps the input rows that also carry a cached-token
series, and the numerator keeps the cached rows that also carry an input series,
so the two sets are identical and a row present in only one metric cannot skew
the alias either way. That counter is sparse — LiteLLM instantiates a
deployment's label set only on its first non-zero `cached_tokens` — so the
filter is exactly "rows this router can measure", and it is what stops the four
vendors above from diluting an alias.
A row that *had* a cached series keeps exporting it flat, so a caching route
that drops to 0 still fires. Before this filter, a single unmeasurable row
carrying most of an alias's input could hold the alias under 50% and page on a
route whose cache was working, which is what happened on 2026-10-17
(fleet-ops#9881, and its earlier duplicate #9856).

The rule is unit-tested with `promtool`. The fixture
`config/grafana/tests/prompt-cache-hit.test.yml` carries the
exact A expression from `prompt-cache-hit.yaml` inlined in
`prompt-cache-hit.test.rules.yml`, so the test cannot drift from the deployed
query. Run it with:

```
promtool test rules config/grafana/tests/prompt-cache-hit.test.yml
```

The fixture lives outside `config/grafana/provisioning/` on purpose: Grafana
loads every file in the mounted `provisioning/alerting/` directory as alert
provisioning, so a promtool file there stops Grafana at startup ("failure to map
file ... rule group has no folder set"). CI runs this test in the `ci` job and
boots the quadlet's Grafana in the `grafana-boot` job.

It covers twelve cases in two kinds, because they check different things. The
seven `alert_rule_test` cases run the rule through the Prometheus alert engine,
which fires on any series the expression returns, so they answer "which lanes are
in the result":

1. a high-volume lane whose cache dropped to ~0.2 fires;
2. a healthy high-volume lane is silent;
3. a low-volume probe lane with zero cache is silent, held off by the volume
   floor;
4. a broken lane beside a healthy one in the same scrape fires for the broken
   one only, so the `and on (requested_model)` does not cross lanes;
5. a **total** cache failure (cached series present and exactly 0) fires;
6. the 2026-10-17 page as a case: an unmeasurable row carries 828 of the alias's
   1039 input tok/s with no cached series, which the old query read as a 0.083
   share and a page, while the filtered query leaves 211 tok/s, under the floor,
   so the lane is held off;
7. the same shape with the measurable row above the floor: 900 cached of 1200
   input tok/s is a healthy 0.75, and the unmeasurable row's 800 tok/s must not
   drag the alias to 0.45.

The five `promql_expr_test` cases answer what the alert_rule_test cases cannot:
not which series appear, but **what Grafana's threshold step then reads**.
Grafana's C is a threshold of `> 0` over A, so a lane reads Alerting at 1 and
Normal at 0:

8. a total cache failure, share exactly 0, returns **1**, so it pages;
9. a healthy busy lane returns **0** beside a broken one at **1**, and a
   sub-floor lane is absent from the result entirely (which is what makes
   `noDataState: OK` the right policy for an idle fleet);
10. case 7's shape returns **0**, where the old query returned **1**;
11. a row whose provider never sent a cache number returns **nothing**: it is
    not a lane in the ratio at all, and the per-model drill-down is what covers
    it;
12. the two sides are pinned to one row set: a measurable row caching 1200 of
    its 20000 input tok/s is a 0.06 breach that returns **1**, while a
    cached-only row adding 30000 cached tok/s must not lift the bare ratio to
    1.56 and read as healthy. That case fails on the pre-fix query, which
    returned **0**.

Every series in the fixture carries the `model_id` label the deployment rows
carry, because the filter matches on it: a fixture without `model_id` would let
`and on (model_id)` match on an empty label and prove nothing.

That split is load-bearing. Query A ends in `bool`, so it returns the 0/1 breach
verdict rather than the ratio, and the inlined test rule wraps it in `> 0` to
reproduce the threshold the Prometheus engine does not have. The `bool` is what
makes case 8 fire at all:

```
# pre-fix A (no `bool`), case 8's series, threshold applied by hand (fires iff > 0):
#   exp 1E+00   got 0E+00        -> a 0% share read 0, `0 > 0` is false, Grafana held it Normal
# current A, all twelve cases -> SUCCESS
```

Without `bool` only shares strictly between 0 and 0.5 would have paged, and the
case this rule exists for, a route that cached nothing at all, would have stayed
silent while every request paid full input price.

### It fires on this box's own data

Rule `prompt-cache-hit-low` was replayed over the last 24h of the live
Prometheus at 5-minute steps, running the deployed expression as of each step.
52 steps read 1, all on `worker-capable`, in five runs. The longest held 125
minutes:

```
2026-10-06T14:39:13Z .. 16:39:13Z   125 min (25 steps of A=1, for: 30m clears at 90 min in)
2026-10-06T10:24:13Z .. 11:29:13Z    70 min
2026-10-07T02:54:13Z .. 03:34:13Z    45 min
```

At the midpoint of the longest run, 2026-10-06T15:30:00Z, the input was:

```
worker-capable   share=0.206   input_tok/s=5357.8
worker-cheap     share=0.263   input_tok/s=240.8    (under the 1000 floor, held off)
```

So the condition this rule pages on is not hypothetical, and it is worth
knowing what caused that dip before treating a page as a regression. At that
instant 43.8% of worker input ran on `cline-ds41flash-worker-capable` and about
15% on the `ollama-*` rows, both of section 3's no-cache-field vendors, so the
alias's share fell because the **mix** leaned on vendors that cannot report a
cache number, not because a caching route broke. That is the mix-shift cause the
`and on (model_id)` filter now excludes, and the 2026-10-17 page was the same
cause with one row instead of two. A page therefore wants the per-model
drill-down first:

```
sum by (model_id) (rate(litellm_input_cached_tokens_metric_total[1h]))
  / sum by (model_id) (rate(litellm_input_tokens_metric_total[1h]))
```

One deployment that stops caching shows as a `model_id` whose share drops while
the rest hold. A fleet-wide mix shift toward section 3's vendors used to show as
several of them rising at once; since fleet-ops#9881 those rows are outside the
ratio, so that pattern no longer pages and what is left in the drill-down is a
real drop on a row that does report a cache number.

Coverage limit, stated rather than hidden: a row that stops reporting its cache
**and** loses its cached-token series in the same window is not covered, because
one scrape cannot tell it from a row that never reported one. In-process that is
not reachable — a sparse counter keeps being exported once instantiated, so a
route that stops reporting reads a flat series and still fires — and hiding it
takes a proxy restart. `docs/prompt-cache-routes.md` section 3's vendor table
stays the record of which rows can report a cache at all, so a row moving into
that list is a documentation and router change rather than an alert one.