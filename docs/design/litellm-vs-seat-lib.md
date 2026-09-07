# LiteLLM proxy vs. seat-lib — design (P0)

Status: P0 design doc for fleet-ops#4130. Endorsed by Nish 2026-09-07 as an
implementation program (P0→P4), one PR per phase. This doc is phase-0 output;
it is NOT a gate — the con case is recorded and the program proceeds. Nish-reserved:
money only (no paid LiteLLM tier, no new paid seats).

All LiteLLM feature claims below are verified against current LiteLLM docs
(docs.litellm.ai, retrieved 2026-09-07), not memory. Each claim cites the doc
page. Where a doc page contradicts the issue's expected mapping, the doc wins
and the gap is named.

## 1. seat-lib inventory

`lib/seat-lib.sh` is 6576 lines, 152 functions (verified `wc -l` + grep). The
three buckets the issue asks for, with line ranges and the LiteLLM feature that
replaces each (or "fleet-specific" for bucket c).

### Bucket (a) — LiteLLM router does it natively

| seat-lib function(s) | Lines | LiteLLM native feature | Doc |
|---|---|---|---|
| `pick_seat` core fallback walk, `_rr_pick`, `_order_seats_by` | 4047-4886, 3604-3681 | `fallbacks` list + `order` field per deployment (ordered failover) | routing-load-balancing, reliability |
| cooldown / bench: `mark_seat_quota_bench`, `mark_seat_overload_bench`, `mark_seat_hang_bench`, `_geometric_bench_window`, `_escalated_backoff`, `_parse_reset_window_s` | 6146-6511, 4958-5180 | `cooldown_time` + `allowed_fails` + `allowed_fails_policy` (per-error-class) | reliability, health-check-routing |
| rate limit: `_provider_free_daily_request_count`, `_provider_free_daily_budget_reached`, `_mark_seat_free_daily_budget_bench`, `provider_cap`, `model_cap`, `total_seat_cap` | 2041-2245, 825-850 | `rpm`/`tpm` per deployment + `enforce_model_rate_limits` (hard limit) | load_balancing |
| spend caps: `_seat_daily_spend_usd`, `_seat_daily_spend_cap_reached`, `_mark_seat_spend_cap_bench` | 2178-2313 | `max_budget` + `budget_duration` per virtual key (Postgres) | users, db_info |
| retries: `_matcher_dispatch`, `_dispatch_lane_faults`, `classify_death_error`, `is_quota_cap_error`, `is_overload_error` | 5814-6403 | `num_retries` + `retry_policy` + `RetryPolicy` per model group | routing, router.py |
| model groups: `class_of`, `model_class_of`, `enumerate_seats` (grouping half) | 850-882, 1748-1778 | `model_name` alias with multiple deployments = one group | load_balancing |
| senior ladder: `find_senior_seat`, `senior_seat_available`, `_provider_is_keystone_only`, `_is_keystone_class` | 1833-1918 | `fallbacks: [{senior: [cursor-grok-4.6, xai-grok-4.6, ...]}]` ordered | reliability |
| selection metric export: `record_seat_selection`, `export_seat_selection_prom`, `keystone_record_event` | 1918-1990 | `/metrics` (Prometheus) + `LiteLLM_SpendLogs` | cost_tracking |
| credential resolve: `provider_has_credential`, `_parse_exec_provider_model` | 2898-2978 | `api_key: os.environ/...` or `api_key: command:...` in litellm_params | virtual_keys |

### Bucket (b) — OpenRouter already does it for paid seats

OpenRouter is a SEAT behind LiteLLM in this design, not a peer (issue rule).
These functions exist only because paid seats were routed through OpenRouter's
own router; once LiteLLM fronts OpenRouter as one deployment among many, the
fleet stops calling OpenRouter's routing and these collapse:

| function(s) | Lines | Note |
|---|---|---|
| OpenRouter-specific allowlist enforcement inside `_build_excluded_set`, `seat_is_reprobe_light_only` | 3682-3812, 479-486 | OpenRouter stays a deployment; its allowlist becomes a LiteLLM `tags` filter |

### Bucket (c) — fleet-specific, NOT in LiteLLM (delete candidates after P0 mapping)

The issue's 2026-09-07 scope-widen asked to map each "fleet-specific" item
against off-the-shelf LiteLLM features too. Verified mapping:

| fleet-specific item | seat-lib functions | Lines | Off-the-shelf replacement | Verdict |
|---|---|---|---|---|
| per-seat concurrency counting | `count_active_on_seat`, `count_active_on_provider`, `count_active_issue`, `count_active_org`, `count_active_total`, `count_active_heavy`, `_build_pick_active_cache`, `register_active_seat`, `clear_active_seat`, `_seat_list_unit`, `_seat_list_pi_exec`, `_seat_registry_unit_live`, `unit_is_degraded`, `_seat_reap_stale_registry`, `_seat_live_registry_files` | 3211-3555, 4898-4958 | LiteLLM `max_parallel_requests` per deployment (async semaphore on the proxy) | **PARTIAL — see gap below** |
| RAM governor | `ram_governor_cap`, `seat_max_concurrent`, `target_concurrent`, `admit_ceiling`, `_systemd_quantity_gb`, `ram_charge_gb_for`, `worker_memory_for_repo`, `worker_memory_for_difficulty`, `worker_env_for_repo`, `active_ram_charge` | 1557-1748, 3465-3511 | systemd slice `MemoryHigh`/`MemoryMax` + systemd-oomd (already deployed, fleet-ops#3971) | **DELETE the counting governor** — admission by cgroup pressure, not by counting |
| prepaid pacing by expiry week | `_prepaid_iso_week`, `_prepaid_usage`, `_prepaid_usage_path`, `_record_prepaid_pick`, `_prepaid_paced` | 3555-3604 | LiteLLM `provider_budget_config` (`budget_limit` + `time_period`) + per-deployment `max_budget`/`budget_duration`; expiry-first = `order` field fallback order | **APPROXIMATION** — LiteLLM budgets are wall-clock periods (1d, 7d), not ISO-week/expiry-keyed. Expiry-first ordering is modelled as `order` in fallback config, not as a spend gate. Keep a thin expiry-ordering shim if exact-week pacing is required. |
| cursor weekly ceiling | (cursor row in seat-caps + spend-cap functions) | 62-70, 2178-2313 | `max_budget` + `budget_duration: 7d` on the cursor virtual key | **DELETE** — native |
| corpse retirement (403 credentials_bad) | `_seat_is_dead`, `_seat_has_recent_corpse_retired`, `mark_seat_spawn_fail` (death branches), `_seat_dead_by_threshold` | 3823-3858, 2468-2527, 5070-5545 | `background_health_checks` + `health_check_interval` + `allowed_fails` + `cooldown_time` | **PARTIAL — see gap below** |
| audition seats (light-only) | `seat_is_audition`, `seat_is_reprobe_light_only` | 468-486 | `tags` on deployments + `enable_tag_filtering`; packets tagged `light` reach audition deployments, `heavy`/`senior` cannot | **DELETE** — native tag routing |
| free-tier privacy exclusion | `load_repo_privacy`, `repo_privacy`, `packet_repo`, privacy branch in `pick_seat` | 168-234, 4049-4057 | a `private` virtual key whose `models` allowlist contains only paid deployments (fail-closed by construction), or tag routing with `allow_fail_open: false` | **DELETE** — native (key allowlist is fail-closed) |
| senior ladder | `find_senior_seat`, `senior_seat_available` | 1857-1918 | model group `senior` with ordered `fallbacks` | **DELETE** — native |
| AIMD learned caps | `load_learned_caps`, `_record_learned_cap`, `effective_provider_cap`, `effective_model_cap`, `_aimd_probe_admitted`, `_model_probe_admitted`, `reset_learned_caps_on_provider_change`, `max_probe_ceiling`, `provider_hard_ceiling`, `_learned_audit`, `_set_learned_in_memory`, `provider_overload_bench_default`, `provider_overload_wedged`, `provider_quota_bench_default`, `provider_reason`, `provider_has_recent_error`, `_provider_bench_until`, `_provider_backoff_bench_until` | 986-1557 | `max_parallel_requests` + `cooldown_time` + `allowed_fails` (the router backs off and cools down automatically; no hand-rolled AIMD) | **DELETE** — the router's cooldown IS the backoff. Probe-up is `max_parallel_requests` set to the probe ceiling. |
| tick spawn cap | `tick_spawn_cap_exceeded`, `tick_spawn_cap_record`, `reset_tick_spawn_counts`, `_tick_spawn_count` | 1278-1351 | `max_parallel_requests` per deployment + `default_max_parallel_requests` | **DELETE** — native concurrency cap replaces per-tick counting |
| spawn-stagger / cohort spread | (config `spawn_stagger_s`, applied in intake) | seat-caps.json:14 | NOT a LiteLLM feature — it is a host-side `systemctl start` stagger | **KEEP** (host-side, not seat-lib) |
| empty-run / no-text detection | `mark_seat_empty_run`, `seat_worked_no_text_path`, `mark_seat_worked_no_text`, `reset_seat_worked_no_text`, `session_tool_calls` | 5545-5910 | NOT a LiteLLM feature — it is a fleet verdict-line check on the worker transcript | **KEEP** (verdict gate, not routing) |
| transport-down detection | `is_spawn_etimeout`, `_transport_is_down`, `_mark_transport_down` | 5181-5264 | NOT a LiteLLM feature — it detects local `pi` CLI spawn failure, not upstream model health | **KEEP** (local CLI health, not seat routing) |
| failure-ceiling / floor-failopen | `_seat_floor_is_money_wall`, `_seat_floor_is_failopen_class`, `_seat_floor_remaining_s`, `_emit_seat_floor_failopen`, `_seat_floor_shortest_bench`, `_failure_ceiling_wall`, `_seat_parked_by_ceiling`, `_emit_failure_ceiling_metric`, `write_parked_ledger` | 3858-4047, 5086-5180 | `max_budget` (money wall) + `budget_duration` (failopen after reset) | **DELETE** — native budget enforcement (Postgres) |

### Gaps the docs expose (honest con-case fuel)

1. **Concurrency counting is NOT equivalent.** LiteLLM `max_parallel_requests`
   is an async semaphore *inside the proxy process* — it bounds in-flight API
   calls to one deployment. The fleet's `count_active_on_seat` counts *local
   systemd `pi-issue@` units* per provider, which bounds how many worker
   *processes* run on the host. These are different axes: the proxy can serve
   10 concurrent calls while the host has 25 units queued. The RAM governor
   (cgroup pressure) is what actually bounds host concurrency today
   (fleet-ops#3971), so deleting the counting governor is correct — but the
   *intake tick's* claim-bounding (`PICK_SEAT_COUNT_SLOTS`) reads
   `count_active_on_seat` to decide how many issues to claim. That caller must
   switch to reading LiteLLM `/health` readiness + `max_parallel_requests`
   headroom, not be deleted blindly. Named in the caller verdict list below.

2. **Health-check V2 is visibility-only.** LiteLLM PR #24787 (merged) changed
   `enable_health_check_routing: true` so background health checks *log*
   unhealthy deployments but do **not** exclude them from routing; the
   request-path cooldown cache is the sole exclusion mechanism, and 429/408
   no longer trigger cooldown in V2. So "auto-remove unhealthy deployments"
   is **reactive cooldown on hard failures (5xx/401/404)**, not proactive
   removal. Corpse retirement (403 credentials_bad) still works — 401/403 are
   hard failures and qualify — but transient 429 walls will NOT auto-bench a
   deployment; they rely on `cooldown_time` + `allowed_fails` after a real
   request fails. The fleet's current `mark_seat_quota_bench` benches on the
   *first* 429 with a parsed reset window. To preserve that behaviour, set
   `allowed_fails: 1` for quota-class errors via `allowed_fails_policy`, and
   accept that 429 cooldown is now request-path, not proactive.

3. **Prepaid expiry-week pacing has no native equivalent.** LiteLLM
   `provider_budget_config` is wall-clock (`time_period: 7d`), not keyed to
   the seat's actual subscription renewal ISO-week. The fleet's
   `_prepaid_paced` checks real expiry timestamps. Approximation: set
   `budget_duration: 7d` and order prepaid deployments first via `order`.
   Exact-week pacing needs a thin shim that rotates the `budget_duration`
   reset to the renewal date, or keep `_prepaid_paced` as the one hand-built
   survivor. P0 recommendation: keep a 1-function expiry-ordering helper,
   delete the rest.

4. **Budgets fail open without a database.** Verified
   (docs/proxy/users): "`max_budget` fails open [DB-less] … the global budget
   check is skipped and requests keep being served past the limit." So
   Postgres is **mandatory** for any budget enforcement (cursor ceiling,
   money walls, prepaid pacing). This matches the 2026-09-07 Postgres ban
   lift. Redis is required for `provider_budget_config` spend tracking and
   for rpm/tpm across multiple proxy instances.

## 2. Pi integration

Pi speaks `openai-completions`. The design adds ONE provider to
`~/.pi/agent/models.json`:

```json
{
  "providers": {
    "litellm": {
      "type": "openai-completions",
      "baseUrl": "http://127.0.0.1:4000",
      "apiKey": "sk-fleet-worker",
      "models": [
        { "id": "worker-cheap",  "cost": null },
        { "id": "worker-capable","cost": null },
        { "id": "senior",        "cost": null },
        { "id": "judge",         "cost": null }
      ]
    }
  }
}
```

`pick_seat` collapses to `pi --print --provider litellm --model <group>`. The
four groups map to LiteLLM `model_name` aliases, each backed by deployments
from `config/entitled-seats.json` + `config/seat-caps.json`. Keys resolve
through the existing credential resolvers (the models.json `!cmd` style) —
LiteLLM accepts `api_key: command:/path/to/resolver` via `litellm_params`, so
no key is copied into the repo or unit file.

### LiteLLM config for the current entitled seats (sketch)

```yaml
model_list:
  # worker-cheap: free lanes first, then prepaid, metered last
  - model_name: worker-cheap
    litellm_params: { model: openai/deepseek-v4-flash, api_base: <opencode>, api_key: command:..., tags: ["free"], order: 1, rpm: 3 }
  - model_name: worker-cheap
    litellm_params: { model: openai/deepseek-v4-flash, api_base: <commandcode>, tags: ["free"], order: 1, rpm: 3 }
  - model_name: worker-cheap
    litellm_params: { model: openai/deepseek-v4-flash, api_base: <hetzner>, tags: ["free"], order: 1, rpm: 2 }
  - model_name: worker-cheap
    litellm_params: { model: openai/glm-5-2, api_base: <devin>, tags: ["prepaid"], order: 2, max_parallel_requests: 3 }
  - model_name: worker-cheap
    litellm_params: { model: openai/deepseek-v4-pro, api_base: <straitly>, tags: ["metered"], order: 3, max_parallel_requests: 2 }
  # worker-capable: prepaid strong models
  - model_name: worker-capable
    litellm_params: { model: openai/swe-1-7, api_base: <devin>, tags: ["prepaid"], order: 1, max_parallel_requests: 4 }
  - model_name: worker-capable
    litellm_params: { model: openai/minimax-m3, api_base: <minimax>, tags: ["metered"], order: 2 }
  # senior: ordered fallback ladder
  - model_name: senior
    litellm_params: { model: openai/cursor-grok-4.6-high, api_base: <cursor>, tags: ["prepaid","senior"], order: 1, max_parallel_requests: 1 }
  - model_name: senior
    litellm_params: { model: openai/grok-4.6, api_base: <xai-oauth>, tags: ["prepaid","senior"], order: 2, max_parallel_requests: 1 }
  - model_name: senior
    litellm_params: { model: openai/deepseek-v4-flash, api_base: <openrouter>, tags: ["metered","senior"], order: 3 }
  # judge: same ladder, separate group for spend tagging
  - model_name: judge
    litellm_params: { model: openai/cursor-grok-4.6-high, api_base: <cursor>, tags: ["prepaid","judge"], order: 1, max_parallel_requests: 1 }

router_settings:
  routing_strategy: simple-shuffle
  fallbacks:
    - worker-cheap: [worker-capable]
    - senior: [worker-capable]
    - judge: [senior]
  cooldown_time: 60
  allowed_fails: 2
  num_retries: 2
  timeout: 1800
  enable_tag_filtering: true
  provider_budget_config:
    cursor:    { budget_limit: 16, time_period: 1d }   # $16/day overage floor
    straitly:  { budget_limit: 5,  time_period: 1d }

general_settings:
  master_key: sk-fleet-master
  background_health_checks: true
  health_check_interval: 60
  database_url: postgresql:///litellm   # local socket, no network listener
```

Virtual keys: `sk-fleet-worker` (allowlist: worker-cheap, worker-capable),
`sk-fleet-senior` (allowlist: senior, judge), `sk-fleet-private` (allowlist:
paid deployments only — fail-closed privacy). The `private` key's model
allowlist contains no `tags: ["free"]` deployment, so a private-repo request
cannot reach a free lane by construction.

## 3. Con case (honest)

1. **New organ.** LiteLLM proxy is a long-running daemon in front of EVERY
   seat. Global-standing-rules require Nish's endorsement for a new organ —
   **ENDORSED 2026-09-07**, so this objection is discharged, but the organ
   count still ticks +1 (proxy) +1 (Postgres) +1 (Redis) = +3 running units.
2. **RAM.** LiteLLM proxy ~0.5-1 GB RSS; Postgres pinned to MemoryMax=1G;
   Redis ~50-100 MB. On a 15 GB RAM-governed VPS with workers already
   thrashing at the oomd 80% line (fleet-ops#3930), +1.5 GB for the routing
   tier is real. Mitigation: dedicated slice `app-litellm.slice`
   `MemoryMax=1G`, Postgres `MemoryMax=1G`, Redis `MemoryMax=128M`; the
   worker slice ceiling stays 12G.
3. **Single point of failure.** Every seat now depends on one proxy process.
   A proxy crash benches the whole fleet. Mitigation: `Restart=on-failure`,
   `RestartSec=2`, and the P4 drill (kill proxy → workers fail loud <60s →
   restore direct-seat route <10 min).
4. **CVE history.** LiteLLM is a large, fast-moving Python codebase with a
   CVE track. Mitigation: pin a digest, `pip-audit` in the proxy unit's
   timer, dependabot on the proxy install.
5. **Added latency.** One extra localhost hop per call (~1-5 ms). Negligible
   for 30-min worker sessions; material for the judge hourly run. Acceptable.
6. **Health-check V2 reactive-only** (gap #2 above). Transient 429 walls no
   longer auto-bench; rely on `allowed_fails_policy` + request-path cooldown.
7. **Prepaid expiry-week pacing is approximate** (gap #3 above). One
   hand-built helper likely survives.
8. **No systemd-unit concurrency** (gap #1 above). The proxy bounds API-call
   concurrency, not host process concurrency. The RAM governor (cgroup)
   remains the host brake; the intake tick's claim-bounding must query
   `/health` headroom instead of counting units.

## 4. Net machinery count

DELETED (P3, after P2 proves the proxy):
- `lib/seat-lib.sh` — 6576 lines, 152 functions, **DELETED in full** (Nish
  2026-09-07 "nothing hand built"). Survivors: a 1-function expiry-ordering
  helper (~20 lines) if gap #3 is kept, and the empty-run/transport-down
  verdict gates (~400 lines) which are NOT routing and move to a new
  `lib/worker-verdict.sh`. Net seat-lib deletion: ~6150 lines.
- `tests/seat-lib.test.sh` and seat-lib AIMD tests — DELETED with the lib.
- agent-state ledgers made redundant by Postgres tables (see delete list
  below).
- canaries/timers for mechanisms that no longer exist (see caller verdicts).

ADDED:
- LiteLLM proxy systemd unit (1) + Postgres unit (1) + Redis unit (1) = 3
  running units.
- `config/litellm-proxy.yaml` (paper, not machinery).
- 1 provider row in `models.json` (paper).

Net: **negative by ~6000 lines of code and ~10 canary/timer units, positive by
3 systemd units.** Code deletion dominates. The 3 new units are off-the-shelf
distro/pip packages, not hand-built machinery. Recommendation stands GO.

### agent-state ledger delete list (P3)

These `~/.local/state/pi-packet/` and `agent-state/lanes/seats/` files are
redundant with LiteLLM's Postgres tables (`LiteLLM_SpendLogs`,
`LiteLLM_VerificationToken`, `LiteLLM_BudgetTable`, cooldown cache in Redis):

- `learned-caps.json` + `learned-caps-audit.log` + `learned-caps*.bak-*` →
  replaced by router cooldown state (Redis) + `max_parallel_requests`.
- `seat-yield.json` → replaced by `LiteLLM_SpendLogs` + `/key/info` spend.
  (Yield-by-PR is a fleet metric, not routing — keep a thin export that reads
  SpendLogs, delete the JSON ledger.)
- `prepaid-usage/*.json` → replaced by `LiteLLM_BudgetTable` per-key spend.
- `fleet-seat-selection.prom`, `fleet-seat-floor-failopen.prom`,
  `fleet-seat-failure-ceiling.prom` textfiles → replaced by LiteLLM
  `/metrics` scrape.
- `lanes/seats/*.json` (per-seat health ledgers) → replaced by
  `/health/readiness` + `/model/info`.
- `lanes/seats/*.spawn-bench.json` → replaced by router cooldown.
- `lanes/seats-corpse-retired-*` → replaced by deployment health-check
  exclusion.
- `pi-seat-health.json` → replaced by `/health/readiness`.
- `active-seats/*.json` (per-unit seat registry) → replaced by router
  in-flight tracking; the intake tick reads `/health` headroom instead.
- `audition-verdicted.json` → replaced by tag-routing audit log.
- `cursor-overage-meter.json` → replaced by `LiteLLM_BudgetTable` for the
  cursor key.

## 5. Migration phases (one PR each, merged before next)

- **P0** (this PR): design doc + the exact seat-lib function delete list for
  P3 (bucket c table above) + the caller verdict list (below) + the
  agent-state ledger delete list (above).
- **P1**: proxy organ. LiteLLM proxy as systemd USER unit in the
  pi-audit-style slice, `MemoryMax=1G`, config-file router (Postgres for
  budgets/keys/spend, Redis for fast path). Model groups from
  `entitled-seats.json` + `seat-caps.json`. Keys via credential resolvers.
  `/health` canary wired into `completion-canary`. LiteLLM `/metrics`
  scraped by the existing Prom. Postgres: one distro systemd unit,
  `MemoryMax=1G`, local socket only, no network listener. Redis: one unit,
  `MemoryMax=128M`.
- **P2**: first consumer, proven. Add the `litellm` provider to
  `models.json`. Route `agent-cron-run fable-check` to `litellm/judge`.
  Proof = one hourly run end-to-end through the proxy, proxy log showing the
  fallback chain honoured.
- **P3a**: workers read groups from LiteLLM while seat-lib still exists.
  Dual-run 24h; compare pick outcomes in the proxy log vs. the old
  `pick_seat` decisions.
- **P3b**: delete `seat-lib.sh` and every caller's seat logic in one PR.
  Net line count in the PR body; must be negative (~6000).
- **P4**: drill + closeout. Kill the proxy → workers fail loud <60s
  (`OnFailure` escalation); restore the direct-seat route <10 min. Kill
  Postgres → same. Record the drill in `fleet-ops/docs`. Delete redundant
  canaries/timers. Acceptance: `grep -rl seat-lib ~/.local/bin
  ~/.local/lib ~/.config/systemd/user` returns nothing; 24h of merged
  product PRs through the proxy at ≥ pre-migration rate.

### Rollback per phase

- P1: stop the proxy unit; no consumer yet, no rollback needed.
- P2: remove the `litellm` provider row; `fable-check` falls back to
  `pick_seat`.
- P3a: flip a `PI_SEAT_SOURCE=seat-lib|litellm` env var; both paths live.
- P3b: revert the PR; seat-lib is restored from git.
- P4: the drill IS the rollback proof.

## 6. Caller verdict list (P0 deliverable — the 10+ callers)

Each caller of seat-lib is either DELETED (canary for a mechanism that no
longer exists) or REWRITTEN to query LiteLLM endpoints.

| caller | current seat-lib use | P3 verdict |
|---|---|---|
| `pi-issue-run` | `pick_seat` | REWRITE: `pi --print --provider litellm --model <group>`; one line |
| `pi-packet-run` | `pick_seat` + privacy | REWRITE: pick group + `private` key for private repos |
| `pi-scout-run` | `pick_seat` (scout role) | REWRITE: `litellm/worker-cheap` |
| `pi-audit-run` | `pick_seat` (audit role) | REWRITE: `litellm/worker-cheap` |
| `agent-cron-run` | `pick_seat` (fable-check → judge) | REWRITE: `litellm/judge` (P2) |
| `blocked-reconcile` | seat health read | REWRITE: query `/health/readiness` |
| `fleet-entitled-wired-canary` | checks every entitled seat is wired | REWRITE: query `/model/info` for the deployment list |
| `fleet-aimd-meter-canary` | reads learned-caps | DELETE — AIMD is gone, router cooldown replaces it |
| `fleet-claim` | `pick_seat` for claim | REWRITE: intake reads `/health` headroom + `max_parallel_requests` |
| `fleet-review-arm-check` | `find_senior_seat` | REWRITE: query `/health` for the `senior` group |
| `fleet-seat-live-validate` | paints seat ledgers | DELETE — `/health` is the authority |
| `fleet-prepaid-util-canary` | reads prepaid-usage | DELETE — `LiteLLM_BudgetTable` is the authority |
| `fleet-researcher-run` | `pick_seat` | REWRITE: `litellm/worker-cheap` |
| `pi-issue-failed-reap` | seat death classification | REWRITE: read router cooldown state from `/health` |
| `fleet-seat-comeback-release` | un-benches seats | REWRITE: router cooldown auto-expires; canary reads `/health` |
| `fleet-seat-recovery` | re-audits dead seats | REWRITE: trigger `/health` refresh; DELETE if redundant |
| `pi-transport-check` / `pi-transport-self-heal` | local CLI spawn health | KEEP — not seat routing |
| `ram-measure` | RAM governor | KEEP — cgroup measurement, not routing |
| `lib/pi-intake-tick.sh` | `PICK_SEAT_COUNT_SLOTS` | REWRITE: query `/health` headroom for claim-bounding |

Console PI WORK tile + `pi-seat-health.json`: read from
`/health/readiness` and `/model/info`, not from a pi hook.

## 7. Recommendation

**GO.** Ranked by fleet motives (quality > 300/day > efficiency):

- **Quality**: the router's `fallbacks` + `cooldown_time` + health-check
  exclusion is a battle-tested failover chain; the hand-rolled 6576-line
  seat-lib has accumulated 152 functions of special-casing (AIMD, bench
  windows, floor-failopen, corpse thresholds) that the router does natively.
  Removing it removes a large surface of routing bugs.
- **300/day**: deleting seat-lib and ~10 canaries reduces the per-tick
  metadata flood and the oomd kill storms that cost claims
  (fleet-ops#3930). The proxy adds ~1.5 GB RAM but removes the counting
  governor that was already superseded by cgroup pressure admission.
- **Efficiency**: prepaid seats drain via `provider_budget_config` +
  `order`; cursor weekly ceiling via `budget_duration: 7d`; spend caps via
  Postgres. Net code is ~6000 lines negative.

The honest con case (3 new units, SPOF, CVE surface, V2 reactive health,
approximate expiry pacing) is real but bounded by the P4 drill and the
dedicated slices. The one likely hand-built survivor is a ~20-line
expiry-ordering helper (gap #3). Everything else in seat-lib is a deletion
candidate.

---

### P3 seat-lib function delete list (exact, for P3b)

Delete in full: every function in bucket (a), bucket (b), and the
"DELETE"-verdict rows of bucket (c). That is the entire routing/budget/
health/privacy/AIMD/concurrency-counting surface — 148 of 152 functions.
Keep (move to `lib/worker-verdict.sh`, NOT routing): `mark_seat_empty_run`,
`seat_worked_no_text_path`, `mark_seat_worked_no_text`,
`reset_seat_worked_no_text`, `session_tool_calls` (verdict gates), and the
transport-down quartet (`is_spawn_etimeout`, `_transport_is_down`,
`_mark_transport_down`, `mark_seat_spawn_fail`'s transport branch). Add one
new `expiry_order_prepaid` helper (~20 lines) if gap #3 is kept.

Net: seat-lib.sh deleted; ~6150 lines removed; ~420 lines move to
`lib/worker-verdict.sh`; ~20 lines new helper. PR body carries the
`git diff --stat` net.

---

## P1 status — proxy organ (fleet-ops#4174, child of #4130)

P1 ships the proxy organ as paper + installable units. The live install
(apt + pip + start) is Nish-gated; the runbook is
`docs/litellm-postgres-setup.md`.

Shipped in P1:

- `systemd/fleet-litellm-proxy.service` — long-running daemon,
  `Restart=on-failure`, `RestartSec=2s`, slice `app-litellm.slice`,
  `MemoryMax=1G`, loopback only (`127.0.0.1:4000`).
- `systemd/app-litellm.slice` / `app-litellm-postgres.slice` /
  `app-litellm-redis.slice` — dedicated slices so a DB bloat cannot
  push the proxy past its ceiling.
- `systemd/fleet-litellm-postgres.service` + slice — fleet-owned
  Postgres cluster (`~/.local/share/fleet-litellm-postgres`), real
  long-running daemon, `MemoryMax=1G`, loopback `127.0.0.1:5432` only.
  The proxy `Requires=`+`After=` it (Nish, 2026-09-07 reopen: the
  earlier distro-service + oneshot-readiness-marker shape left
  Postgres/Redis as `active (exited)` and the proxy started before the
  DB socket was up — rejected).
- `systemd/fleet-litellm-redis.service` + slice — fleet-owned Redis
  (`~/.local/share/fleet-litellm-redis/redis.conf`), real long-running
  daemon, `MemoryMax=128M`, bind `127.0.0.1:6379`. The proxy
  `Requires=`+`After=` it.
- `config/litellm-proxy.yaml` — the router config from §2, with
  `api_key: command:...` placeholders (no real key in the repo). The
  live copy at `~/.config/fleet-ops/litellm-proxy.yaml` holds the
  credential resolvers.
- `libexec/fleet-litellm-health-canary.py` + service + 60s timer —
  polls `/health/readiness`, exports `fleet_litellm_proxy_up`,
  `fleet_litellm_postgres_up`, `fleet_litellm_redis_up` + per-group
  readiness. Connection-refused (organ dead) exits 1 so the global
  `service.d/10-escalate.conf` drop-in climbs the ladder.
- `config/fleet-organs.json` — four new organs (`litellm-proxy`,
  `litellm-postgres`, `litellm-redis`, `litellm-health-canary`).
- `config/fleet_rules.yml` — four new `absent()` rules
  (`FleetLitellmProxyAbsent`, `FleetLitellmPostgresAbsent`,
  `FleetLitellmRedisAbsent`, `FleetLitellmHealthCanaryAbsent`).
- `config/prometheus.yml` — new `litellm` scrape job →
  `127.0.0.1:4000/metrics`.

Net machinery count for P1: +3 systemd units (proxy/postgres/redis) +
1 canary unit/timer = +4 running units, +1 config yaml, +1 canary bin.
This is the P1 add; the P3 delete (~6000 lines seat-lib + ~10 canaries)
is what makes the program net-negative. Recorded here for the program
ledger.

Rollback for P1: `systemctl --user stop fleet-litellm-proxy
fleet-litellm-postgres fleet-litellm-redis` + remove the `litellm` prom
scrape job. No consumer yet (P2 lands the first consumer), so stopping
the organ has zero fleet impact.

P2 (next phase, to be filed): first consumer — route
`agent-cron-run fable-check` to `litellm/judge`, prove one hourly run
end-to-end through the proxy with the proxy log showing the fallback
chain honoured.
