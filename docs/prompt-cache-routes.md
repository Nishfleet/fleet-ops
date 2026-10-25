# Prompt-cache routes: per-vendor verdicts and the Pi zero-cache cause

Read-only research for fleet-ops#9357. Every number below was read off this
box, on the date its section gives, and can be re-read with the command printed
under it.

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

The `opencodego2-ds41flash-worker-capable` row above (134 calls, 0 null, 134
with cache details) still read a 91-95% daily share in section 6's spend-log
query through 2026-10-19, and stopped reporting on its streamed path on
2026-10-20; see section 6.

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

Section 6 records a page where the lane never stopped caching at the vendor: the
reporting path did, which the rule cannot tell apart from a real drop.

## 6. 2026-10-20: the OpenCode Go lane stopped reporting cache on streamed usage

The rule from section 5 went critical on `worker-capable` at 2026-10-21
06:57:50Z (fleet-ops#9935). The lane still caches and the counter stopped
seeing it.

**What the spend log shows.** `opencodego2-ds41flash-*` held a cache-read
share of 91-95% every day from 2026-10-12 to 2026-10-19 (93.14%, 91.54%,
91.64%, 93.30%, 94.58%, 93.47%, 93.40%, 91.17%), 0.35% on 2026-10-20 and 0.21%
on 2026-10-21. The last row that carried a cache number on real traffic is
2026-10-20 06:50:49Z, a `sk-fleet-worker` call on
`opencodego2-ds41flash-worker-capable`: 69,904 prompt tokens, 69,888 cached.
Since then the lane has 415 rows and the only five that carry a cache field are
hand-made probe calls from this investigation, four of which read
`cached_tokens: 0` because the probe sent a cold prefix on purpose. Nothing on
this side changed: the proxy process started 2026-10-17 18:19 IST and
`config/litellm-proxy.yaml` last changed on 2026-10-17, so this is not a fleet
deploy.

Both numbers above come from the spend log, which keeps the provider usage
block under `metadata->'usage_object'`:

```
psql "postgresql://litellm@localhost:5432/litellm" -At -F'|' -c "
  SELECT to_char(date_trunc('day', \"startTime\"), 'MM-DD'), count(*),
         round(100.0 * sum(coalesce((metadata->'usage_object'->'prompt_tokens_details'->>'cached_tokens')::bigint, 0))
               / nullif(sum(prompt_tokens), 0), 2),
         count(*) FILTER (WHERE metadata->'usage_object'->'prompt_tokens_details'->>'cached_tokens' IS NOT NULL)
    FROM \"LiteLLM_SpendLogs\"
   WHERE model_id LIKE 'opencodego2-ds41flash%' AND prompt_tokens > 0 AND \"startTime\" >= '2026-10-11'
   GROUP BY 1 ORDER BY 1"
```

The five probe rows and the 415-row count are the same query without the
`GROUP BY`, filtered to `"startTime" > '2026-10-20 06:50:49'` and cut down to
`count(*)`, `min("startTime")` and `max("startTime")`. Test the field with
`->>'cached_tokens' IS NOT NULL`, never with `->` alone: in `jsonb`,
`'null'::jsonb IS NOT NULL` is true.

**The prefix did not break.** Pi's request bodies were captured at the proxy
boundary: a throwaway forwarder on 127.0.0.1:4001 that logs each request body
and passes it to 127.0.0.1:4000, with `PI_CODING_AGENT_DIR` pointed at a copy of
the agent config whose `litellm` base URL names 4001. The sizes are `wc -c` of
those captures. Two consecutive turns of one session were 61.9 KB and 62.2 KB,
and
their common messages were byte-identical: the second request only appends
the assistant turn and its tool result, which is the shape a provider prefix
cache needs. Replayed straight to `https://opencode.ai/zen/go/v1/chat/completions`
with the same key and the same `x-opencode-session` header, those two bodies
read back `cached_tokens` 15,488 of 15,586 (99.4%) and 15,616 of 15,638 (99.9%).
A later turn of the same session, 106 KB and 27,715 prompt tokens, read back
27,648, which is 99.8%.

**The field is missing only on the streamed answer the proxy gets.** The
106 KB body, same session header, same `worker-capable` key:

| path | `prompt_tokens` | cache field |
| --- | --- | --- |
| direct to the vendor, `stream: true` | 27,715 | `cached_tokens: 27,648` |
| through the proxy, `stream: false` | 27,715 | `cached_tokens: 27,648` |
| through the proxy, `stream: true` | 24,536 | absent |

The 24,536 is not the vendor's number: it falls 3,179 tokens short of the
27,715 the vendor itself reports for the same bytes, and a count taken by the
wrapper instead of read from the provider's `usage` block is the only cause that
fits. That reading is inferred from the gap, not measured. The tokens are
cached, the counter cannot see it, and the rule reads a flat zero.

Every captured body carries `"stream": true` and
`"stream_options": {"include_usage": true}`, so each call asks for the usage
block. To re-read the table: the first row is the first command unchanged, the
third row is the second command unchanged, and the second row is the second
command with `"stream": false` in a copy of the body. The proxy answer names
its row in the `x-litellm-model-id` header.

```
curl -sS --config <(sed -n 's|^OPENCODE_API_KEY_2=\(.*\)|header = "Authorization: Bearer \1"|p' \
      ~/.config/fleet-ops/seats/opencode-2.env) \
     -H 'Content-Type: application/json' -H 'x-opencode-session: fleet2-worker-capable' \
     --data-binary @body.json https://opencode.ai/zen/go/v1/chat/completions | tail -2

curl -sS --config <(sed -n 's|^LITELLM_INISH_DAILY_KEY=\(.*\)|header = "Authorization: Bearer \1"|p' \
      ~/.config/fleet-ops/seats/inish-daily.env) \
     -H 'Content-Type: application/json' -H 'x-litellm-session-id: sa' \
     --data-binary @body.json http://127.0.0.1:4000/v1/chat/completions
```

**Ruled out, one run each on this box 2026-10-21.** Each is the first command
above with one flag or one body field changed: `-H 'User-Agent: litellm/1.98.0'`,
`-H 'User-Agent: python-httpx/0.28.1' -H 'Accept-Encoding: gzip, deflate, br,
zstd'`, `--http1.1`, `--resolve opencode.ai:443:<ip>` for each of the four A
records (172.65.90.20 to .23), `store` dropped, `reasoning_effort` dropped, a
body with a tool call and its result appended, and
`stream_options.continuous_usage_stats` added. All keep the field. The control
that matters is a miss, not a hit: the same prefix read twice in one minute in
the spend log, 2026-10-21 07:09:43 and 07:09:54, logged `cached_tokens` 0 and
then 13,440. A miss reports 0, so an absent field is not a miss, it is a field
the caller never got.

**What the vendor sends now.** Its streamed usage block rides on the chunk that
carries the last of the reply, instead of on a trailing chunk with no content.
A 13,538-token probe answered in two chunks plus `[DONE]` (the tail of the first
command above, `stream: true`):

```
data: {"choices":[{"delta":{"reasoning_content":"docs","role":"assistant"}}],...}
data: {"choices":[{"delta":{"content":"ok"}}],"usage":{"prompt_tokens":13538,
       "completion_tokens":2,"prompt_tokens_details":{"cached_tokens":13440}}}
data: [DONE]
```

A row that still reports, `commandcode-glm53flashb-worker-cheap`, ends its
stream the other way: seven content chunks, then two with an empty delta, and
the `usage` block on the second of those. Same box, same proxy, minutes apart:

```
data: {"choices":[{"index":0,"delta":{}}],...}
data: {"choices":[{"index":0,"delta":{}}],"usage":{"prompt_tokens":13521,
       "prompt_tokens_details":{"cached_tokens":0}}}
data: [DONE]
```

That answer was a cold prefix, and it still carries the field, set to 0. So
streaming does not drop the field by itself. The visible difference between the
row that reports and the row that does not is where the usage block sits: on the
empty-delta tail chunk, or on the chunk that carries the last content. The
drop follows that difference, which makes it the placement, not the streaming
and not the cache.

**No in-repo lever exists.** LiteLLM v1.98.0 cannot force a non-streaming
upstream call for a streaming caller (the note at
`config/litellm-proxy.yaml:50`, fleet-ops#8923), and no row parameter changes
the shape a gateway returns its streamed usage in. An OpenAI-compatible row has
`cache_read_input_token_cost` and nothing else cache-shaped. The levers that
would restore the counter both change what production does, so neither is taken
here: the image bump is tracked at fleet-ops#9384, and re-weighting the lane off
rows that do not report changes a provider row, which needs Nish's yes first
(`config/litellm-proxy.yaml:51`).

**For the next page.** Section 5's drill-down names the row but not the cause.
Add one non-streamed replay of any captured request: if
`prompt_tokens_details.cached_tokens` comes back, the vendor still reports and
the loss is on the streamed path; if it stays absent, the vendor stopped
reporting.