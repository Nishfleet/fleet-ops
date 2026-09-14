#!/usr/bin/env bash
# tests/seat-lib-termination.test.sh
#
# fleet-ops#6101 (child of #4263) termination clause: "for every function in
# the pre-#5993 lib/seat-lib.sh, no bin/ or lib/ file calls it unless a
# sourced file defines it."
#
# #5993 (5411da097) deleted lib/seat-lib.sh; its 198 functions became
# silently-undefined 127s in whatever organ still called them. This test
# locks the demolition's define-or-127 invariant: every call-shaped
# reference to one of those 198 names, in every #!-sh bin/ and lib/*.sh,
# must be:
#   (a) defined by the calling file, or
#   (b) defined by a file the caller sources (resolved by basename against
#       bin/ and lib/ — the live source path is the install destination,
#       e.g. ~/.local/lib/pi-packet/litellm-seat.sh), or
#   (c) a call behind a declare -[fF]/command -v guard — it cannot 127 —
#       AND pinned in guarded_calls below so the residue stays visible, or
#   (d) a recorded non-call reference in prose_mentions below.
#
# lib/litellm-seat.sh is exempt from the caller scan: the #6101 packet
# forbids touching it (a separate #4263-family packet owns that file), and
# its remaining mentions of 198-names are locals, $vars and jq '.field'
# reads, not calls. It still counts as a definer for (b).
#
# The 198-name list is COMMITTED here rather than derived from git history:
# hosted CI clones are shallow, so `git show 5411da097^:lib/seat-lib.sh`
# cannot be relied on, and this list IS the termination spec.
#
# Hosted by tests/ci-standards-audit.test.sh so it runs in P14 without a
# workflow-file edit (the worker App cannot push .github/workflows/**) —
# the #5471 precedent.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

FUNC_NAMES=(
  active_ram_charge admit_ceiling _aimd_has_admitted_raise _aimd_probe_admitted
  _build_excluded_set _build_pick_active_cache classify_death_error class_of
  clear_active_seat count_active_heavy count_active_issue count_active_on_provider
  count_active_on_seat count_active_org count_active_total count_degraded_total
  _dispatch_lane_faults effective_model_cap effective_provider_cap
  _emit_failure_ceiling_metric _emit_seat_floor_failopen enumerate_seats
  _escalated_backoff _exec_is_pi_worker _expire_stale_cap0_seats
  _expiring_seat_behind_pace export_seat_selection_prom _failure_ceiling_wall
  find_senior_seat _geometric_bench_window _intake_repos_path
  is_credentials_error is_devin_writes_rejected _is_keystone_class
  is_openrouter_free_retired_error is_overload_error is_quota_cap_error
  is_sandbox_localhost_error is_spawn_etimeout is_workspace_trust_error
  is_writes_refused keystone_record_event _learned_audit _learned_ramp_stale
  litellm_pick_seat litellm_source _load_error_classes load_learned_caps
  load_quality_routing load_repo_privacy load_repo_product load_seat_caps
  load_seat_yield mark_seat_config_fault_bench mark_seat_credentials_bad
  mark_seat_devin_writes_rejected_bench mark_seat_empty_run mark_seat_empty_success
  _mark_seat_free_daily_budget_bench mark_seat_free_retired_corpse
  mark_seat_hang_bench mark_seat_overload_bench
  _mark_seat_provider_daily_budget_bench mark_seat_quota_bench
  mark_seat_spawn_fail _mark_seat_spend_cap_bench mark_seat_worked_no_text
  mark_seat_writes_refused_bench _mark_transport_down _matcher_dispatch
  max_probe_ceiling model_cap model_class_of _model_probe_admitted now_s
  _order_seats_by org_reserve packet_difficulty packet_id_from_path packet_repo
  _park_wall_s _parse_exec_provider_model _parse_reset_window_s
  _pick_expiring_floor_seat _pick_repair_rung_seat pick_seat
  _prepaid_elapsed_fraction _prepaid_iso_week _prepaid_paced _prepaid_usage
  _prepaid_usage_path _provider_backoff_bench_until _provider_bench_until
  provider_cap _provider_daily_429_logged _provider_daily_budget_reached
  _provider_daily_set_log _provider_daily_spend_usd_tokens
  _provider_free_daily_budget_reached _provider_free_daily_request_count
  provider_hard_ceiling provider_has_credential provider_has_recent_error
  _provider_is_keystone_only provider_live_reset_s provider_overload_bench_default
  provider_overload_wedged _provider_prepaid_reset_s provider_quota_bench_default
  provider_reason _provider_recent_fast_death provider_remote_agent
  _provider_seat_quota_reset_s provider_wall_ceiling_s ram_charge_gb_for
  ram_governor_cap _record_learned_cap _record_prepaid_pick _record_prepaid_usd
  record_seat_selection register_active_seat _repair_rung_offer
  repo_is_product repo_privacy reset_learned_caps_on_provider_change
  reset_seat_worked_no_text reset_tick_spawn_counts _rr_pick
  sandbox_localhost_resolves _sanitise_seat _seat_clamp_non_money_window_s
  seat_cost_for _seat_co_write_sidecar _seat_daily_spend_cap_reached
  _seat_daily_spend_usd _seat_dead_by_threshold _seat_duration_to_s
  seat_empty_success_path _seat_floor_is_failopen_class _seat_floor_is_money_wall
  _seat_floor_remaining_s _seat_floor_shortest_bench seat_hang_timeout_s
  _seat_has_recent_corpse_retired _seat_in_future seat_is_audition
  _seat_is_benched _seat_is_dead seat_is_reprobe_light_only _seat_key_guard
  _seat_key_in_caps seat_ledger_path _seat_list_org_unit _seat_list_pi_exec
  _seat_list_unit _seat_liveness_bound_s _seat_live_registry_files seat_log
  _seat_log_uses_file seat_max_concurrent _seat_merge_error_class _seat_now_epoch
  _seat_observed_fresh _seat_parked_by_ceiling _seat_rate_limit_fresh
  _seat_reap_stale_registry _seat_registry_unit_live _seat_remaining_s
  seat_spawn_bench_path _seat_text_is_money_wall seat_usable
  seat_walled_breakdown _seat_wall_source_justified seat_worked_no_text_path
  _seat_write_spawn_bench seat_yield_for senior_seat_available
  session_tool_calls _session_usd_from_usage _set_learned_in_memory
  _systemd_quantity_gb target_concurrent task_weight tick_spawn_cap_exceeded
  tick_spawn_cap_record _tick_spawn_count _tick_spawn_effective_cap
  _tick_spawn_has_other_usable _tick_spawn_ride_aimd total_seat_cap
  _transport_is_down unit_is_degraded _wall_capped_at_horizon
  worker_env_for_repo worker_memory_for_difficulty worker_memory_for_repo
  write_parked_ledger _writer_dispatch
)
# Exactly the pre-#5993 set: 198 names. If the #4263 demolition changes this,
# the count pin below fails and forces a conscious edit.
[[ ${#FUNC_NAMES[@]} -eq 198 ]] || fail "FUNC_NAMES drifted: ${#FUNC_NAMES[@]} != 198"

names_regex="$(IFS='|'; printf '%s' "${FUNC_NAMES[*]}")"

# Prints the function names a file defines (`name()` in the de-commented
# body), one per line.
def_set_of() {
    sed -e 's/#.*//' "$1" 2>/dev/null \
        | grep -oE '(^|[[:space:]])[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)' \
        | sed -E 's/^[^A-Za-z_]+|[[:space:]()]//g' | sort -u || true
}

# Non-call references that survive the call-shape filter are recorded here
# instead of being hunted into false 127s.
# now_s: the epoch-seconds LOCAL idiom — these hits are $var reads and
# spaced ((...)) arithmetic, not function calls. When a real call replaces
# one, delete the line.
# mark_seat_spawn_fail / seat_max_concurrent: printf repair-text and
# comments, not calls.
prose_mentions="bin/fleet-escalation-completion:now_s
bin/pi-salvage-worktree:now_s
bin/fleet-heartbeat:now_s
bin/fleet-heartbeat-low-water-mark:now_s
bin/fleet-heartbeat-undersaturation:now_s
bin/fleet-worktree-reaper:now_s
lib/cursor-api-bucket.sh:now_s
lib/precedence-band.sh:now_s
bin/fleet-empty-run-burst-canary:mark_seat_spawn_fail
bin/fleet-scout-leak-canary:seat_max_concurrent"

# Guarded-call residue: a call behind `declare -[fF] name` / `command -v
# name` can never 127, so it does not violate the clause — but it is dead
# weight until its owning packet lands, so each one is pinned file:name to
# keep the residue visible. fleet-ops#6101's packet forbids touching
# bin/pi-issue-run (a separate #4263-family packet owns it); its
# _record_prepaid_usd call sits behind `declare -f` until that packet ports
# it. lib/work-supply.sh's repo_is_product call is deliberately guarded:
# the lib is a standalone helper whose callers (pi-scout-run, the intake
# tick) source litellm-seat.sh first, and standalone use fails closed.
guarded_calls="bin/pi-issue-run:_record_prepaid_usd
lib/work-supply.sh:repo_is_product"

# The one surviving definer: lib/litellm-seat.sh. Callers reach it through
# the SEAT_LIB/PI_PACKET_SEAT_LIB idiom — `SEAT_LIB=".../litellm-seat.sh"`
# then `source "$SEAT_LIB"` — so a de-commented body that names
# litellm-seat.sh (the default path in the assignment or a direct source
# line) is the sourcing signal. Only this file may define 198-names for
# other files; the remaining repo defs are self-contained stubs covered by
# clause (a).
LITELLM_DEFS="$(def_set_of lib/litellm-seat.sh)"

# Collect the #!-sh bins plus lib/*.sh, minus the exempted caller file.
targets=()
while IFS= read -r f; do
    head -1 "$f" 2>/dev/null | grep -qE '#![[:space:]]*/.*sh' && targets+=("$f")
done < <(ls bin/* 2>/dev/null)
for f in lib/*.sh; do
    [[ "$f" == lib/litellm-seat.sh ]] && continue   # exempted above
    targets+=("$f")
done
[[ ${#targets[@]} -gt 100 ]] || fail "target scan list looks wrong: ${#targets[@]} files"

violations=0
for f in "${targets[@]}"; do
    # Call-shaped references only: strip comments, then require the name to
    # stand as a bare word. Assignments (name=), $vars, ((arithmetic, 'quoted'
    # strings, jq '.field' reads and definition lines are not calls; the
    # declaration lines (local/declare/typeset/readonly) carry the variable
    # form of these same names and are skipped wholesale.
    bodies="$(sed -e 's/#.*//' "$f" 2>/dev/null | grep -vE '^[[:space:]]*(local|declare|typeset|readonly)[[:space:]]' || true)"
    [ -n "$bodies" ] || continue
    hits="$(printf '%s\n' "$bodies" | grep -oE "(^|[^a-zA-Z0-9_\"'(.]|\$\()(${names_regex})([[:space:];)|]|$)" || true)"
    [ -n "$hits" ] || continue
    self_defs="$(printf '%s\n' "$bodies" | grep -oE '(^|[[:space:]])[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)' | sed -E 's/^[^A-Za-z_]+|[[:space:]()]//g' | sort -u || true)"
    for name in $(printf '%s\n' "$hits" | sed -E "s/^[^a-zA-Z_]+|[[:space:];)|)]+$//g" | sort -u); do
        # (a) defined by the calling file.
        grep -qxF "$name" <<<"$self_defs" && continue
        # (b) defined by lib/litellm-seat.sh, which the calling file sources
        #     (the SEAT_LIB idiom: the basename rides the default-path
        #     assignment, so a de-commented mention IS the sourcing signal).
        if grep -q 'litellm-seat\.sh' <<<"$bodies" \
            && grep -qxF "$name" <<<"$LITELLM_DEFS"; then
            continue
        fi
        # (d) a recorded non-call reference.
        grep -qxF "$f:$name" <<<"$prose_mentions" && continue
        # (c) a guarded call — provably cannot 127 — pinned in guarded_calls.
        if grep -qE "declare -[fF] ${name}\b|command -v ${name}\b" "$f" \
            && grep -qxF "$f:$name" <<<"$guarded_calls"; then
            continue
        fi
        echo "VIOLATION: $f calls $name but neither defines it nor sources a file that defines it"
        violations=$((violations + 1))
    done
done

[ "$violations" -eq 0 ] || fail "seat-lib termination: $violations unresolved 127 call(s)"
ok "seat-lib termination: all pre-#5993 references across ${#targets[@]} bin/lib files are backed by a definition (fleet-ops#6101)"
