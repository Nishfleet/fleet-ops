# shellcheck shell=bash
# pi-packet seat-lib.sh — shared seat enumeration and selection logic.
# Sourced by pi-packet-run and pi-issue-run. NOT executed directly.
#
# P4-A (2026-08-25): per-seat caps replace the legacy single '4 Devin workers'
# cap. Caps live in config/seat-caps.json (not hardcoded) so fleet-ops PRs can
# tune them without touching code. Selection order (fleet-ops#387): free
# lanes first, then prepaid-quota alternating (never stack one prepaid dry),
# then metered last. prepaid_providers_in_order is expiry-first among
# prepaid. Caps add an UPPER bound per provider and per model, never a lower
# one. Classes: free / prepaid-quota / metered (subscription is an alias of
# prepaid-quota).
#
# fleet-ops#1133: a packet that declares `difficulty: keystone` inverts that
# cost-first walk (prepaid capable first, then metered, free last) and
# refuses a third cheap retry so systemd OnFailure can summon the senior
# auditor. Unmarked packets keep the #387/#1178 order (volume first).
#
# fleet-ops#1167: cursor is keystone/senior-review only (never volume).
# leftover prepaid after the volume prefix is xai-oauth (alternate).
# Every pick appends seat-selection.jsonl and refreshes
# fleet_seat_selection_24h{provider=} for the digest / Weekly Review.
#
# AIMD learned caps (fleet-ops#217, re-land #424): the declared cap is the
# FLOOR. pick_seat may admit cap+1 on a free lane with room below
# max_probe_ceiling, zero 429s, and RAM headroom. A fresh 429/concurrency
# signal halves the learned cap and benches until the provider window.
# hard_ceiling rows (devin, ollama) never probe. Metered rows default
# max_probe_ceiling to the declared cap so money-adjacent seats do not
# climb. State lives in learned-caps.json; every change writes one line to
# learned-caps-audit.log (this library is the reader that #424 was missing).
#
# Survivors justified against systemd: systemd Restart= restarts the SAME
# ExecStart — it cannot choose a different provider/model seat. Seat rotation
# (pick a DIFFERENT seat on each retry) is real added value that systemd
# genuinely cannot do, so it stays here. The per-seat health ledger check
# (never route to an exhausted seat) and the per-seat/per-model caps are
# likewise routing decisions systemd cannot make.

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export HOME="${HOME:-/home/nish}"

STATE_DIR="${PI_PACKET_STATE:-$HOME/.local/state/pi-packet}"
ATTEMPTS_DIR="$STATE_DIR/attempts"
ACTIVE_SEATS_DIR="$STATE_DIR/active-seats"
# SEAT_LOG_FILE pins the seat_log target to a specific file instead of the
# state-dir watch.log (fleet-ops#3928): a test harness that would otherwise
# write to the production watch.log can redirect the audit line to its own
# scratch file without moving the whole PI_PACKET_STATE dir. Unset in
# production, so this keeps the live LOG_FILE behaviour byte-for-byte.
LOG_FILE="${SEAT_LOG_FILE:-$STATE_DIR/watch.log}"
# Worker packet dir (pi-issue-run reads <inst>.in here; intake writes it).
# Used by count_active_heavy to read each active unit's difficulty line.
PI_ISSUES_DIR="${PI_ISSUES_DIR:-$HOME/.local/state/pi-issues}"

MODELS_JSON="${PI_MODELS_JSON:-$HOME/.pi/agent/models.json}"
# Per-seat health ledger (authority). Written atomically by the pi
# seat-health extension (one file per provider+model). Read-only here:
# no polling, no network — file reads only.
LEDGER_DIR="${PI_SEAT_HEALTH_LEDGER_DIR:-/home/nish/workspaces/agent-state/lanes/seats}"
# Legacy single-record seat-health sidecar (pi-seat-health.json). The out-of-repo
# seat-health.ts extension writes it on every observation (including a healthy 200
# from a simple packet), so when the WRAPPER benches a seat (mark_seat_empty_run /
# mark_seat_spawn_fail) the sidecar keeps reporting health_class=healthy/http 200
# until the extension's next observation — the seat-health probe and the wrapper
# bench disagree, the seat keeps being re-selected and burns issues (fleet-ops#3559).
# The wrapper co-writes this sidecar on a wrapper bench so the record honours it.
# Env override matches seat-health.ts (PI_SEAT_HEALTH_SIDECAR); tests stub it.
SEAT_HEALTH_SIDECAR="${PI_SEAT_HEALTH_SIDECAR:-$HOME/workspaces/agent-state/lanes/pi-seat-health.json}"
STALE_SECS=21600   # 6h — observed_at older than this counts as no-data
RATE_LIMIT_FRESH_SECS=1800  # 30 min — a rate_limited marker is only trusted while freshly observed; older than this, retry the seat
PI_BIN="${PI_BIN:-$HOME/.local/bin/pi}"
# Capacity map (P4-A). The file is the source of truth; this env var lets
# tests and fleet-ops overrides point at a different map without editing
# the install path.
SEAT_CAPS_JSON="${SEAT_CAPS_JSON:-$HOME/.local/state/pi-packet/seat-caps.json}"
# fleet-ops#457: quality-weighted routing overlay. Missing scoreboard =
# no cuts (do not brick pick_seat). Over-threshold lanes lose heavy work.
QUALITY_ROUTING_JSON="${QUALITY_ROUTING_JSON:-$HOME/.local/state/pi-packet/quality-routing.json}"
QUALITY_SCOREBOARD_JSON="${QUALITY_SCOREBOARD_JSON:-$HOME/workspaces/agent-state/quality-scoreboard/snapshot.json}"
QUALITY_ROUTING_PY="${QUALITY_ROUTING_PY:-$HOME/.local/lib/pi-packet/quality-routing.py}"
# fleet-ops#3250: per-seat rolling PR-yield ledger, written by
# libexec/fleet-metrics-export.py. pick_seat loads it once per call.
SEAT_YIELD_JSON="${SEAT_YIELD_JSON:-$HOME/.local/state/pi-packet/seat-yield.json}"
HEAVY_PKT_BYTES="${PI_PACKET_HEAVY_BYTES:-8192}"

mkdir -p "$ATTEMPTS_DIR" "$ACTIVE_SEATS_DIR"

# Runtime probe for the systemd-cat fallback (fleet-ops#3272).
_SEAT_SYSTEMD_CAT="$(command -v systemd-cat 2>/dev/null || true)"

# Decide whether the durable log goes to the watch.log file or to the journal.
# File is used when the user-level logrotate config is present (so the file is
# kept small), or when the LOG_FILE is not the production watch.log (i.e., a
# test harness has set PI_PACKET_STATE to a scratch dir). Otherwise fall back
# to systemd-cat so the log lands in journald's own rotation instead of an
# unbounded flat file.
_seat_log_uses_file() {
    if [[ -n "${SEAT_LOG_FORCE_FILE:-}" ]]; then
        return 0
    fi
    local logrotate_conf="${SEAT_LOGROTATE_CONF:-$HOME/.config/logrotate.conf}"
    if [[ -f "$logrotate_conf" ]]; then
        return 0
    fi
    local prod_state="$HOME/.local/state/pi-packet"
    case "$LOG_FILE" in
        "$prod_state"/*) return 1 ;;
        *) return 0 ;;
    esac
}

seat_log() {
    local line ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf -v line '[%s] %s\n' "$ts" "$*"
    if _seat_log_uses_file; then
        # Durable audit trail in watch.log. logrotate is the rotation owner
        # when ~/.config/logrotate.conf is present (fleet-ops#3272).
        printf '%s' "$line" >>"$LOG_FILE"
    elif [[ -n "$_SEAT_SYSTEMD_CAT" ]]; then
        # No user logrotate: avoid an unbounded flat file by writing to the
        # systemd journal. 'journalctl -t pi-packet' reads the seat log.
        printf '%s' "$line" | "$_SEAT_SYSTEMD_CAT" --identifier=pi-packet --priority=info 2>/dev/null || \
            printf '%s' "$line" >>"$LOG_FILE"
    else
        # Final fallback: still append to the file even if unrotated, because
        # losing the audit trail is worse than an unbounded log on a host
        # that somehow has no journal and no logrotate.
        printf '%s' "$line" >>"$LOG_FILE"
    fi
    # Also emit to stderr so systemd's journal / `systemctl status` shows the
    # reason (fleet-ops#342).
    printf '%s' "$line" >&2
}

# fleet-ops#4219 P3a: LiteLLM seat routing. When PI_SEAT_SOURCE=litellm,
# callers resolve their seat from the LiteLLM proxy (model group) instead
# of pick_seat. The proxy handles fallback, cooldown, and health checks.
# PI_SEAT_SOURCE=seat-lib (the default) keeps the existing pick_seat path.
# This function returns provider<TAB>model, the same shape as pick_seat.
# Args: $1 = LiteLLM model group (worker-cheap, worker-capable, senior,
#   judge, worker-private). Callers pass their group; pi-packet-run passes
#   worker-private when the packet targets a private repo.
# Env: PI_SEAT_SOURCE (default: seat-lib).
# Returns: 0 always; prints provider<TAB>model on stdout.
litellm_pick_seat() {
    local group="${1:-worker-cheap}"
    printf 'litellm\t%s\n' "$group"
}

# True when the fleet is routing through LiteLLM instead of seat-lib.
litellm_source() {
    [[ "${PI_SEAT_SOURCE:-seat-lib}" == "litellm" ]]
}

now_s() { date -u +%s; }

# Single source of truth for "now" inside seat-lib's freshness/expire
# checks. Production callers leave FLEET_SEAT_RECOVERY_NOW unset and
# fall through to real wall clock (date -u +%s); tests set it to an ISO
# timestamp so the bench_until / observed_at / usable_at comparisons see
# the same clock the harness set, not the host's real wall clock. Without
# this, a hard-coded bench_until in a test fixture ages out the moment
# the host clock passes it, the fail-open path returns "usable" for
# every quota_bench ledger, and any test that needs a "no-usable" verdict
# silently degrades to "no transition — nothing to fire" (fleet-ops#735).
_seat_now_epoch() {
    if [[ -n "${FLEET_SEAT_RECOVERY_NOW:-}" ]]; then
        date -u -d "$FLEET_SEAT_RECOVERY_NOW" +%s 2>/dev/null || date -u +%s
        return
    fi
    date -u +%s
}

# --- repo privacy (free-tier privacy line, vault 2026-08-18) ----------------
# Source of truth: config/repo-privacy.json. Free-class seats train on
# prompts, so they may only process PUBLIC-repo work. pick_seat skips every
# free-class seat when the routing target is private (privacy=private). A
# missing/unparseable config fails CLOSED (default_policy=private) so a
# newly created private product repo can never silently leak to a free lane
# before it is classified here. fleet-ops#520.
REPO_PRIVACY_JSON="${REPO_PRIVACY_JSON:-$HOME/.local/state/pi-packet/repo-privacy.json}"
_repo_privacy_loaded=0
REPO_PRIVACY_DEFAULT="private"
declare -A REPO_PRIVACY_MAP=()

load_repo_privacy() {
    REPO_PRIVACY_MAP=()
    _repo_privacy_loaded=1
    local default
    default=$(jq -r '.default_policy // "private"' "$REPO_PRIVACY_JSON" 2>/dev/null || echo "private")
    case "$default" in
        public|private) REPO_PRIVACY_DEFAULT="$default" ;;
        *) REPO_PRIVACY_DEFAULT="private" ;;
    esac
    local repo vis
    while IFS=$'\t' read -r repo vis; do
        [[ -n "$repo" ]] || continue
        REPO_PRIVACY_MAP["$repo"]="$vis"
    done < <(
        {
            jq -r '.public[]?  | [.,"public"]  | @tsv' "$REPO_PRIVACY_JSON" 2>/dev/null || true
            jq -r '.private[]? | [.,"private"] | @tsv' "$REPO_PRIVACY_JSON" 2>/dev/null || true
        }
    )
}

# repo_privacy <repo> -> echoes "private" or "public".
# Fail-closed: a repo with no entry resolves to REPO_PRIVACY_DEFAULT (private
# unless the config explicitly widens it). A missing config also fails closed.
repo_privacy() {
    local repo="$1" v
    if (( ! _repo_privacy_loaded )); then load_repo_privacy || true; fi
    v="${REPO_PRIVACY_MAP[$repo]:-}"
    [[ "$v" == "public" || "$v" == "private" ]] || v="$REPO_PRIVACY_DEFAULT"
    echo "$v"
}

# packet_repo <pkt> -> echoes the Nishfleet repo name targeted by a packet, or
# empty if no TARGET line is present. Recognises every TARGET shape the
# dispatch wrappers emit:
#   TARGET: repo Nishfleet/<repo> issue <N> unit <unit>      (pi-issue-run)
#   TARGET: <role> unit <unit>, repo Nishfleet/<repo>        (pi-scout-run legacy)
#   TARGET REPO: Nishfleet/<repo>                            (pi-scout-run 0509)
#   TARGET: intake unit <unit>, repo Nishfleet/<repo>        (pi-intake-repair-run)
packet_repo() {
    local pkt="$1" line repo
    [[ -f "$pkt" ]] || return 0
    line=$(grep -m1 -E '^TARGET(:| REPO:)' "$pkt" 2>/dev/null || true)
    [[ -n "$line" ]] || return 0
    # Strip everything up to and including "Nishfleet/", then take the first
    # token (the repo name). Handles both "repo Nishfleet/<repo>" and
    # "Nishfleet/<repo>" shapes, and trailing punctuation.
    repo=${line##*Nishfleet/}
    repo=${repo%%[[:space:],]*}
    printf '%s' "$repo"
}

# --- product-repo flag (fleet-ops#3724) -------------------------------------
# Source of truth: config/intake-repos.json `repos[].product`. A seat marked
# product_only in seat-caps.json is a metered last-resort seat that may only
# ever serve a product repo — never fleet-ops (control plane) and never an
# unclassified repo. Fail-closed: a missing flag, an unlisted repo, or a
# missing/unparseable config resolves to not-product, so a paid seat can
# never silently serve a repo that is not a declared product repo.
INTAKE_REPOS_JSON="${FLEET_INTAKE_REPOS_JSON:-}"
_intake_repos_loaded=0
declare -A REPO_PRODUCT_MAP=()

# Resolve the intake-repos.json path: explicit FLEET_INTAKE_REPOS_JSON first,
# then the config CO-LOCATED with this lib (code and config from the same
# checkout), then the checkout fleet-deploy-check maintains, and only then
# the legacy sibling checkouts.
#
# Why co-located must win (2026-09-08, fleet-ops#4450 follow-up): the legacy
# order probed ~/workspaces/products/fleet-ops FIRST. That mirror is stale
# (pinned at 4f7d0e3e, 2026-09-04) and predates the `product` flag #4450
# added, so it has no product flag at all. A stale sibling checkout could
# therefore SHADOW the deployed config, and did: REPO_PRODUCT_MAP loaded
# empty on the live fleet, repo_is_product returned false for 0509,
# work_supply_label_budget fell back to the floor of 8 against a measured
# drain of 11.5 issues/h, and every product_only seat was skipped with
# "packet repo is not a declared product repo". Resolving next to the
# running code makes that class of shadowing impossible: the config a
# checkout reads is the one shipped beside the code executing.
_intake_repos_path() {
    if [[ -n "${INTAKE_REPOS_JSON:-}" && -f "${INTAKE_REPOS_JSON:-}" ]]; then
        printf '%s' "$INTAKE_REPOS_JSON"
        return 0
    fi
    local lib_dir c
    local -a candidates=()
    lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P) || lib_dir=""
    [[ -n "$lib_dir" ]] && candidates+=("$lib_dir/../config/intake-repos.json")
    candidates+=("${FLEET_OPS_CHECKOUT:-$HOME/workspaces/tooling/fleet-ops-deploy-clone}/config/intake-repos.json")
    candidates+=("$HOME/workspaces/products/fleet-ops/config/intake-repos.json")
    candidates+=("$HOME/workspaces/tooling/fleet-ops/config/intake-repos.json")
    for c in "${candidates[@]}"; do
        [[ -f "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

load_repo_product() {
    REPO_PRODUCT_MAP=()
    _intake_repos_loaded=1
    local f
    f=$(_intake_repos_path) || return 1
    local repo prod
    while IFS=$'\t' read -r repo prod; do
        [[ -n "$repo" ]] || continue
        [[ "$prod" == "true" ]] && REPO_PRODUCT_MAP["$repo"]=1
    done < <(jq -r '.repos[]? | [.name, (.product // false | tostring)] | @tsv' "$f" 2>/dev/null || true)
}

# repo_is_product <repo> -> 0 when <repo> is a declared product repo
# (intake-repos.json product flag), 1 otherwise. Fail-closed on empty repo,
# unlisted repo, or missing/unparseable config.
repo_is_product() {
    local repo="$1"
    if (( ! _intake_repos_loaded )); then load_repo_product || true; fi
    [[ -n "$repo" && "${REPO_PRODUCT_MAP[$repo]:-0}" == "1" ]]
}

# --- capacity map (P4-A) ----------------------------------------------------
# Read once per shell. Returns 0 on success, 1 if the map is missing/unreadable.
# Caller is expected to fall back to "no caps" behaviour (allow everything)
# rather than fail the spawn, because missing caps is a CONFIG problem, not
# a seat problem — a broken config must not brick the whole ladder.
_seat_caps_loaded=0
declare -A SEAT_PROVIDER_CAP=()
declare -A SEAT_MODEL_CAP=()
declare -A SEAT_MODEL_CLASS=()
declare -A SEAT_PROVIDER_CLASS=()
declare -A SEAT_PROVIDER_BENCH_DEFAULT=()
declare -A SEAT_PROVIDER_REMOTE_AGENT=()
# fleet-ops 2026-08-27 #652 hot-patch: 503-overload bench defaults per provider.
# Distinct from SEAT_PROVIDER_BENCH_DEFAULT (quota/cap wall): overload is a
# transient "upstream provider is temporarily unavailable" that the existing
# is_quota_cap_error matcher does NOT catch. Without a default, the writer
# fails open and pick_seat re-offers the same seat to the next worker, which
# then hits the same 503 storm (the 2026-08-27 fleet-ops#652 root cause).
declare -A SEAT_PROVIDER_OVERLOAD_BENCH_DEFAULT=()
declare -A SEAT_PROVIDER_QUOTA_WINDOW=()
declare -A SEAT_PROVIDER_WEEKLY_BUDGET=()
# fleet-ops#217/#424 AIMD: probe ceiling, hard-ceiling flag, dated cap=0 reason.
declare -A SEAT_PROVIDER_MAX_PROBE=()
# fleet-ops#3125: model-granularity AIMD probe ceiling (devin glm-5-2 -> 6,
# swe-1-7 -> 8). Loaded from per-model object rows that carry
# max_probe_ceiling next to cap; absent means the declared model cap is the
# hard ceiling (no model-level probe).
declare -A SEAT_MODEL_PROBE_CEILING=()
declare -A SEAT_PROVIDER_HARD_CEILING=()
declare -A SEAT_PROVIDER_REASON=()
# fleet-ops#3690: per-tick per-provider spawn cap. Limits how many NEW
# sessions pick_seat routes to a provider within a single intake tick so a
# fresh fleet (learned-caps reset) does not burst N spawns on one provider
# and trip resource_exhausted. 0 = unlimited. Loaded from tick_spawn_cap on
# the provider block in seat-caps.json; the intake tick resets the counter
# file at the start of each tick.
declare -A SEAT_TICK_SPAWN_CAP=()
# fleet-ops#1432: classification of cap=0 seats as intentional (dead_decoy /
# money_only) vs stale (broken endpoint, TPM ceiling, exhausted quota). Drives
# the summary line in _build_excluded_set so the operator sees at a glance
# which cap=0 seats are by-design vs which need re-audition. Keyed on
# "provider" for provider-level cap=0, "provider/model" for model-level.
declare -A SEAT_CAP_ZERO_CLASS_INTENTIONAL=()
declare -A SEAT_CAP_ZERO_CLASS_STALE=()
# fleet-ops#3322: audition lane. A seat carrying audition: true in the LIVE
# caps is only eligible for packet_difficulty light (cap 1, 10 sessions / 7d /
# $1 cost cap, injected by lib/pi-intake-tick.sh from config/model-candidates.json).
# Keyed on "provider" for provider-level audition, "provider/model" for model-level.
declare -A SEAT_AUDITION=()
# fleet-ops#4129: a stale cap=0 seat re-admitted by _expire_stale_cap0_seats is
# marked light-only here. The seat was cap=0 because it was broken (endpoint 404,
# TPM ceiling, exhausted quota); re-admitting it at cap=1 lets pick_seat re-probe
# on a LIGHT packet, but it must NOT land heavy/keystone/senior-review work until
# the re-probe proves the seat answers. Keyed on "provider" for provider-level
# re-admission, "provider/model" for model-level. Cleared by load_seat_caps and
# re-populated only when a seat actually expires; a re-probe that succeeds clears
# the marker via the seat-health observation path (the bench writers re-wall a
# still-broken seat, which does not touch this map — the next load_seat_caps
# drops it only if the seat is no longer stale-cap=0).
declare -A SEAT_REPROBE_LIGHT_ONLY=()
SEAT_FREE_ORDER=""
SEAT_PREPAID_ORDER=""
# fleet-ops#3125: seat-caps product_order. "yield" routes product picks
# (PI_PICK_ROLE=product) through the rolling PR-yield ledger instead of the
# free-first ladder; "value" (fleet-ops#3323) ranks by yield/cost with a
# quality-first key on heavy/keystone; empty/absent keeps the class-bucket
# ladder.
SEAT_PRODUCT_ORDER=""
# fleet-ops#3121: the senior (judge/orchestrator/reviewer) role seat ladder,
# in priority order (provider/model). First usable seat wins. Replaces the
# dead straitly role and the old keystone_only_providers dual mechanism.
SEAT_SENIOR_ORDER=()
# fleet-ops#3121: cursor weekly ceiling for the senior ladder. When cursor's
# prepaid-usage count for the week hits this, find_senior_seat skips cursor
# and falls through to the next seat (xai-oauth/grok-4.6). 0 = no ceiling.
SEAT_SENIOR_CURSOR_CEILING=0
SEAT_CURSOR_OVERAGE_MODEL="cursor-grok-4.6-high"
SEAT_CURSOR_INCLUDED_EXHAUSTED=0
SEAT_CURSOR_DAILY_TARGET_USD=16
SEAT_COMEBACK_MIN_PROBE_S=900
SEAT_COMEBACK_RATE_LIMIT_S=900
SEAT_COMEBACK_DAILY_QUOTA_S=3600
SEAT_COMEBACK_MONTHLY_QUOTA_S=86400
SEAT_COMEBACK_FREE_BALANCE_S=86400
SEAT_COMEBACK_CREDENTIALS_BAD_S=604800
SEAT_RAM_GB_PER_WORKER=1.5
# Org/repair packets charge at most this many seats against the intake
# cap (fleet-ops 2026-08-27 seat-cap un-strangle). Extra org units keep
# running; they just cannot fill the RAM ceiling and skip ready issues.
SEAT_ORG_RESERVE=2
SEAT_PACE_PCT="${SEAT_PACE_PCT:-80}"
# fleet-ops#3723: per-provider daily request budget for free-model accounts
# whose cap is per-ACCOUNT (OpenRouter free models). When the shared counter
# of assistant turns across the provider's *:free sessions today (UTC) reaches
# this, every free model on the provider benches until 00:00 UTC. Keyed on
# provider name. 0 = no daily budget (default; only OpenRouter carries one).
declare -A SEAT_FREE_DAILY_REQUEST_BUDGET=()

# fleet-ops#3724: per-seat routing guard for a metered seat that may only
# ever serve PRODUCT repos (config/intake-repos.json `product` flag on the
# repos[] entry — fleet-ops is control plane, never product). Keyed on
# "provider/model". A seat with SEAT_PRODUCT_ONLY[p/m]=1 is collected in a
# last-resort bucket pick_seat appends after every other class, so it is
# offered only when no free/prepaid seat is usable.
declare -A SEAT_PRODUCT_ONLY=()
# Nish 2026-09-10 (ds41 amendment): a product_only seat may also carry
# last_resort:true — it sinks below every other seat in the last-resort
# bucket, so the PAYG api.deepseek.com seat is offered only when no other
# seat of any class (including other product_only seats) is usable.
# Keyed on "provider/model". Absent = normal product_only bucket order.
declare -A SEAT_LAST_RESORT=()
# fleet-ops#3724: per-seat daily USD spend cap measured from Pi session
# usage.cost (the same source the fleet-ops#3283 fleet_seat_spend_usd export
# aggregates). When today's (UTC) spend on the seat reaches this, seat-lib
# benches it until 00:00 UTC with a dated ledger reason — an external budget
# wall (health_class=quota_bench, consecutive_failure_count=0), never charged
# to the work item. Keyed on "provider/model". Absent = no daily spend cap.
declare -A SEAT_DAILY_SPEND_CAP_USD=()

# fleet-ops#4453: provider-level daily USD budget for a prepaid seat whose
# allowance expires each UTC day (Pareto Pass: $20/day, unused $ lost at
# 23:59). Unlike SEAT_DAILY_SPEND_CAP_USD (which reads Pi session usage.cost
# and is per-seat), ParetoInference reports usage.cost=0 on the Pass, so the
# spend meter here is TOKEN-derived: per-message usage.input/output/cacheRead
# tokens x the provider's own pi-models cost map (per 1M), summed over the
# provider's sessions today (UTC). daily_budget_usd is the real daily
# allowance (the accept-jq reads it); daily_stop_usd is the bench threshold
# (margin below the budget so the first 200-after-reset re-probe and cleanup
# never blow past it). Keyed on provider name. Absent = no daily-budget gate.
declare -A SEAT_PROVIDER_DAILY_BUDGET_USD=()
declare -A SEAT_PROVIDER_DAILY_STOP_USD=()

# fleet-ops#457: lanes whose snapshot metrics exceed quality-routing.json
# cuts. Empty when the scoreboard is missing/stale. Loaded once per pick.
_quality_routing_loaded=0
declare -A QUALITY_HEAVY_BAN=()

# fleet-ops#3250: per-seat rolling PR-yield ledger. Loaded once per pick so
# downstream gating has fresh data; missing/stale -> empty -> 0.5 fallback.
# fleet-ops#3323: the same ledger carries cost_per_session (mean usage.cost
# per session over the window) so product picks can rank by value.
_seat_yield_loaded=0
declare -A SEAT_YIELD=()
declare -A SEAT_COST=()

load_quality_routing() {
    QUALITY_HEAVY_BAN=()
    _quality_routing_loaded=1
    local py="$QUALITY_ROUTING_PY"
    if [[ ! -f "$py" ]]; then
        local here_py
        here_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/quality-routing.py"
        [[ -f "$here_py" ]] && py="$here_py"
    fi
    [[ -f "$py" ]] || return 0
    [[ -f "$QUALITY_ROUTING_JSON" ]] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    local lane
    while IFS= read -r lane; do
        [[ -n "$lane" ]] || continue
        QUALITY_HEAVY_BAN["$lane"]=1
        seat_log "quality-routing: $lane excluded from heavy/keystone work"
    done < <(python3 "$py" heavy-bans \
        --thresholds "$QUALITY_ROUTING_JSON" \
        --scoreboard "${QUALITY_SCOREBOARD_JSON:-}" 2>/dev/null || true)
}

# fleet-ops#3250: load the per-seat rolling PR-yield ledger written by the
# metrics exporter. Fail-open: a missing/unparseable JSON leaves SEAT_YIELD
# empty and every seat falls back to the 0.5 provisional yield.
load_seat_yield() {
    SEAT_YIELD=()
    SEAT_COST=()
    _seat_yield_loaded=1
    [[ -f "$SEAT_YIELD_JSON" ]] || return 0
    [[ -s "$SEAT_YIELD_JSON" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local seat y _sessions _provisional c
    while IFS=$'\t' read -r seat y _sessions _provisional c; do
        [[ -n "$seat" ]] || continue
        SEAT_YIELD["$seat"]="$y"
        SEAT_COST["$seat"]="$c"
    done < <(
        jq -r 'to_entries[]
               | [ .key,
                   (.value.yield // 0.5 | tostring),
                   (.value.sessions // 0 | tostring),
                   (.value.provisional // true | tostring),
                   (.value.cost_per_session // 0 | tostring) ]
               | @tsv' "$SEAT_YIELD_JSON" 2>/dev/null || true
    )
}

# Return the yield for a seat (0..1, default 0.5 for unknown/new seats).
# Echoes nothing and returns 1 if the seat argument is empty.
seat_yield_for() {
    local p="${1:-}" m="${2:-}"
    [[ -n "$p" && -n "$m" ]] || return 1
    if (( ! _seat_yield_loaded )); then load_seat_yield || true; fi
    echo "${SEAT_YIELD[$p/$m]:-0.5}"
}

# fleet-ops#3323: return the rolling cost per session for a seat. Unknown
# seats default to 0 — the value floor clamps cost to 0.001, so an
# unmeasured seat prices as free and is tried, not starved.
# Echoes nothing and returns 1 if the seat argument is empty.
seat_cost_for() {
    local p="${1:-}" m="${2:-}"
    [[ -n "$p" && -n "$m" ]] || return 1
    if (( ! _seat_yield_loaded )); then load_seat_yield || true; fi
    echo "${SEAT_COST[$p/$m]:-0}"
}

# fleet-ops#3322: return 0 if the seat is an audition seat (provider-level or
# model-level audition: true in the LIVE caps). Audition seats are only
# eligible for packet_difficulty light — pick_seat gates them out of every
# other difficulty. Returns 1 (not audition) for unknown/empty seats.
seat_is_audition() {
    local p="${1:-}" m="${2:-}"
    [[ -n "$p" && -n "$m" ]] || return 1
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    [[ -n "${SEAT_AUDITION[$p]:-}" || -n "${SEAT_AUDITION[$p/$m]:-}" ]]
}

# fleet-ops#4129: return 0 if the seat was re-admitted from a stale cap=0 by
# _expire_stale_cap0_seats and is therefore light-only until a re-probe proves
# it answers. pick_seat gates it out of every non-light difficulty, same shape
# as seat_is_audition. Returns 1 (not re-probe-light-only) for unknown/empty.
seat_is_reprobe_light_only() {
    local p="${1:-}" m="${2:-}"
    [[ -n "$p" && -n "$m" ]] || return 1
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    [[ -n "${SEAT_REPROBE_LIGHT_ONLY[$p]:-}" || -n "${SEAT_REPROBE_LIGHT_ONLY[$p/$m]:-}" ]]
}

load_seat_caps() {
    SEAT_PROVIDER_CAP=()
    SEAT_MODEL_CAP=()
    SEAT_MODEL_CLASS=()
    SEAT_PROVIDER_CLASS=()
    SEAT_PROVIDER_BENCH_DEFAULT=()
    SEAT_PROVIDER_OVERLOAD_BENCH_DEFAULT=()
    SEAT_PROVIDER_QUOTA_WINDOW=()
    SEAT_PROVIDER_WEEKLY_BUDGET=()
    SEAT_PROVIDER_MAX_PROBE=()
    SEAT_PROVIDER_HARD_CEILING=()
    SEAT_PROVIDER_REASON=()
    SEAT_TICK_SPAWN_CAP=()
    SEAT_CAP_ZERO_CLASS_INTENTIONAL=()
    SEAT_CAP_ZERO_CLASS_STALE=()
    SEAT_PRODUCT_ONLY=()
    SEAT_LAST_RESORT=()
    SEAT_DAILY_SPEND_CAP_USD=()
    SEAT_PROVIDER_DAILY_BUDGET_USD=()
    SEAT_PROVIDER_DAILY_STOP_USD=()
    SEAT_AUDITION=()
    SEAT_REPROBE_LIGHT_ONLY=()
    SEAT_FREE_ORDER=""
    SEAT_PREPAID_ORDER=""
    SEAT_PRODUCT_ORDER=""
    SEAT_MODEL_PROBE_CEILING=()
    SEAT_SENIOR_ORDER=()
    SEAT_SENIOR_CURSOR_CEILING=0
    SEAT_CURSOR_OVERAGE_MODEL="cursor-grok-4.6-high"
    SEAT_CURSOR_INCLUDED_EXHAUSTED=0
    SEAT_CURSOR_DAILY_TARGET_USD=16
    SEAT_COMEBACK_MIN_PROBE_S=900
    SEAT_COMEBACK_RATE_LIMIT_S=900
    SEAT_COMEBACK_DAILY_QUOTA_S=3600
    SEAT_COMEBACK_MONTHLY_QUOTA_S=86400
    SEAT_COMEBACK_FREE_BALANCE_S=86400
    SEAT_COMEBACK_CREDENTIALS_BAD_S=604800
    SEAT_RAM_GB_PER_WORKER=1.5
    SEAT_ORG_RESERVE=2
    SEAT_TARGET_CONCURRENT=25
    SEAT_SPAWN_STAGGER_S=0

    [[ -f "$SEAT_CAPS_JSON" ]] || { seat_log "seat-caps: NO CAPS FILE at $SEAT_CAPS_JSON — falling back to no-cap behaviour"; return 1; }
    if ! jq -e . "$SEAT_CAPS_JSON" >/dev/null 2>&1; then
        seat_log "seat-caps: $SEAT_CAPS_JSON unparseable — falling back to no-cap behaviour"
        return 1
    fi

    local ram ores tgt stagger
    ram=$(jq -r '.ram_gb_per_worker // 1.5' "$SEAT_CAPS_JSON")
    [[ "$ram" =~ ^[0-9]+(\.[0-9]+)?$ ]] && SEAT_RAM_GB_PER_WORKER="$ram"
    ores=$(jq -r '.org_reserve // 2' "$SEAT_CAPS_JSON")
    [[ "$ores" =~ ^[0-9]+$ ]] && SEAT_ORG_RESERVE="$ores"
    tgt=$(jq -r '.target_concurrent // 25' "$SEAT_CAPS_JSON")
    [[ "$tgt" =~ ^[0-9]+$ ]] && SEAT_TARGET_CONCURRENT="$tgt"
    # fleet-ops#3784: seconds to sleep between cohort spawns so clone/npm/pi
    # startup peaks do not overlap (oomd slice-pressure kills). 0 disables.
    stagger=$(jq -r '.spawn_stagger_s // 0' "$SEAT_CAPS_JSON")
    [[ "$stagger" =~ ^[0-9]+$ ]] && SEAT_SPAWN_STAGGER_S="$stagger"

    # fleet-ops#602: the read loops below must use LOCAL variables. bash's
    # `local` is DYNAMIC scoping, so a bare `p`/`m` here would write into the
    # caller's variable of the same name — a lazy-loading model_cap()/class_of()
    # would have its own $p/$m clobbered to the last jq line before its lookup
    # ran, returning 0 for every unlisted-model seat and NO-USABLE-SEAT for
    # the whole free role (pi-audit@ free-glm-5-3 unit-failure loop 2026-08-27).
    local p m cap class bench_def max_probe hard reason window budget ko ov_model ov_ex ov_usd cb icz remote audition tick_cap
    # Unit separator (\x1f), not TSV: bash `read` collapses consecutive tabs
    # so optional empty fields (max_probe_ceiling, reason) would vanish.
    while IFS=$'\x1f\n' read -r p cap class bench_def max_probe hard reason icz remote audition tick_cap; do
        [[ -n "$p" ]] || continue
        SEAT_PROVIDER_CAP["$p"]="$cap"
        # subscription is the pre-#387 name for prepaid-quota.
        [[ "$class" == "subscription" ]] && class="prepaid-quota"
        SEAT_PROVIDER_CLASS["$p"]="$class"
        [[ "$bench_def" =~ ^[0-9]+$ ]] && SEAT_PROVIDER_BENCH_DEFAULT["$p"]="$bench_def"
        # AIMD bounds (fleet-ops#217/#424). max_probe_ceiling absent -> ""
        # -> max_probe_ceiling() returns the declared cap (no upward probe).
        [[ "$max_probe" =~ ^[0-9]+$ ]] && SEAT_PROVIDER_MAX_PROBE["$p"]="$max_probe"
        [[ "$hard" == "true" ]] && SEAT_PROVIDER_HARD_CEILING["$p"]=1
        [[ -n "$reason" ]] && SEAT_PROVIDER_REASON["$p"]="$reason"
        # fleet-ops#3690: per-tick spawn cap (0 = unlimited).
        [[ "$tick_cap" =~ ^[0-9]+$ ]] && SEAT_TICK_SPAWN_CAP["$p"]="$tick_cap"
        # fleet-ops#1432: classification of cap=0 seats (intentional vs stale).
        # fleet-ops#2435: "corpse" joins the intentional set — a model whose
        # ledger is seat_dead (terminal "corpse" class, no comeback clock)
        # is retired, never re-auditioned, so its cap-0 skip classifies as
        # intentional (by design), not stale (re-audit when the external
        # condition clears). fleet-ops#4271: "yield" joins the intentional set
        # — a seat retired for zero PR yield (0 PRs over >= 20 picks) is
        # intentional, never auto-expired; the re-audition path (yield gate
        # #3251) is the only way back in.
        if [[ "$icz" == "dead_decoy" || "$icz" == "money_only" || "$icz" == "corpse" || "$icz" == "yield" ]]; then
            SEAT_CAP_ZERO_CLASS_INTENTIONAL["$p"]="$icz"
        elif [[ "$icz" == "stale" ]]; then
            SEAT_CAP_ZERO_CLASS_STALE["$p"]="$icz"
        fi
        # fleet-ops#3531: remote agents (e.g. devin) run outside the local
        # harness and must be judged by session outcome, not local tool count.
        [[ "$remote" == "true" ]] && SEAT_PROVIDER_REMOTE_AGENT["$p"]=1
        # fleet-ops#3322: provider-level audition flag (xkiro free-tier seats
        # carry it at provider level via #3505). A seat carrying audition: true
        # is only eligible for packet_difficulty light — pick_seat gates it.
        [[ "$audition" == "true" ]] && SEAT_AUDITION["$p"]=1
    # A provider may be a bare number (shorthand for cap=N, class=free, no
    # models — e.g. "devin": 0). Indexing .value.cap on a number crashes jq
    # and, with `2>/dev/null || true`, silently empties the whole cap map —
    # which then makes total_seat_cap() return 0 and the intake ceiling fall
    # back to the (inflated) RAM governor. Normalise by type first.
    # quota_bench_default_s (fleet-ops#90) is optional; absent -> empty ->
    # provider_quota_bench_default returns 0 (no default, writer fails open).
    # max_probe_ceiling / hard_ceiling / reason (fleet-ops#217) likewise
    # optional; absent fields emit "" so the guards above skip them.
    done < <(jq -r '.providers | to_entries[] | .key as $k | .value as $v | [$k, (if ($v|type)=="number" then $v else ($v.cap // 0) end), (if ($v|type)=="number" then "free" else ($v.class // "free") end), (if ($v|type)=="object" then ($v.quota_bench_default_s // "") else "" end), (if ($v|type)=="object" then ($v.max_probe_ceiling // "") else "" end), (if ($v|type)=="object" then ($v.hard_ceiling // false) else false end), (if ($v|type)=="object" then ($v.reason // "") else "" end), (if ($v|type)=="object" then ($v.intentional_cap_zero // "") else "" end), (if ($v|type)=="object" then ($v.remote_agent // "") else "" end), (if ($v|type)=="object" then ($v.audition // false) else false end), (if ($v|type)=="object" then ($v.tick_spawn_cap // "") else "" end)] | join("\u001f")' "$SEAT_CAPS_JSON" 2>/dev/null || true)

    while IFS=$'\x1f\n' read -r p m cap class mprobe maudition; do
        [[ -n "$p" && -n "$m" ]] || continue
        # Models map may be a bare number (cap) or an object {cap, class,
        # max_probe_ceiling}. Per-model class is an override for a free lane
        # inside a mixed provider (e.g. cline has prepaid-pass seats and a
        # free z-ai GLM); max_probe_ceiling opts the seat into model-level
        # AIMD probing (fleet-ops#3125).
        if [[ "$cap" =~ ^[0-9]+$ ]]; then
            SEAT_MODEL_CAP["$p/$m"]="$cap"
        else
            # Extract cap from object JSON; fail closed to 0 if missing.
            local mcap
            mcap=$(jq -r '.cap // 0' <<<"$cap" 2>/dev/null)
            [[ "$mcap" =~ ^[0-9]+$ ]] && SEAT_MODEL_CAP["$p/$m"]="$mcap"
        fi
        if [[ "$mprobe" =~ ^[0-9]+$ ]]; then
            SEAT_MODEL_PROBE_CEILING["$p/$m"]="$mprobe"
        fi
        if [[ -n "$class" ]]; then
            [[ "$class" == "subscription" ]] && class="prepaid-quota"
            SEAT_MODEL_CLASS["$p/$m"]="$class"
        fi
        # fleet-ops#3322: model-level audition flag. A candidate injected by
        # the intake tick from config/model-candidates.json carries audition:
        # true at model level (cap 1, light issues only).
        [[ "$maudition" == "true" ]] && SEAT_AUDITION["$p/$m"]=1
        # fleet-ops#1432: model-level intentional_cap_zero classification.
        # Only present when the model value is an object (not a bare number).
        if [[ ! "$cap" =~ ^[0-9]+$ ]]; then
            local icz
            icz=$(jq -r '.intentional_cap_zero // ""' <<<"$cap" 2>/dev/null || true)
            # fleet-ops#2435: "corpse" is intentional too — see the provider
            # loop comment. Matches the ledger's terminal corpse class.
            # fleet-ops#4271: "yield" (zero-PR retirement) is intentional too —
            # never auto-expired; re-audition only via the yield gate (#3251).
            if [[ "$icz" == "dead_decoy" || "$icz" == "money_only" || "$icz" == "corpse" || "$icz" == "yield" ]]; then
                SEAT_CAP_ZERO_CLASS_INTENTIONAL["$p/$m"]="$icz"
            elif [[ "$icz" == "stale" ]]; then
                SEAT_CAP_ZERO_CLASS_STALE["$p/$m"]="$icz"
            fi
            # fleet-ops#3241: a model-level stale cap=0 expires on the date
            # in its own .reason. Without this load the reason was invisible
            # to _expire_stale_cap0_seats, so a model-level stale seat could
            # never expire and persisted at cap=0 silently forever.
            local mreason
            mreason=$(jq -r '.reason // ""' <<<"$cap" 2>/dev/null || true)
            [[ -n "$mreason" ]] && SEAT_PROVIDER_REASON["$p/$m"]="$mreason"
            # fleet-ops#3724: product_only + daily_spend_cap_usd model flags.
            # product_only: pick_seat offers the seat only for a packet whose
            # repo carries the product flag in config/intake-repos.json, and
            # only after every free/prepaid seat is unusable (last-resort
            # bucket). daily_spend_cap_usd: when today's (UTC) Pi usage.cost
            # on the seat reaches it, the seat benches until 00:00 UTC.
            local mpo mspend mlr
            mpo=$(jq -r '.product_only // false' <<<"$cap" 2>/dev/null || true)
            [[ "$mpo" == "true" ]] && SEAT_PRODUCT_ONLY["$p/$m"]=1
            mspend=$(jq -r '.daily_spend_cap_usd // ""' <<<"$cap" 2>/dev/null || true)
            [[ "$mspend" =~ ^[0-9]+(\.[0-9]+)?$ ]] && SEAT_DAILY_SPEND_CAP_USD["$p/$m"]="$mspend"
            # last_resort (Nish 2026-09-10): product_only seats flagged
            # last_resort sink to the tail of the last-resort bucket.
            mlr=$(jq -r '.last_resort // false' <<<"$cap" 2>/dev/null || true)
            [[ "$mlr" == "true" ]] && SEAT_LAST_RESORT["$p/$m"]=1
        fi
    # Unit separator (\x1f), not TSV, for the same reason the providers loop
    # uses it: bash `read` collapses consecutive tabs, so an empty per-model
    # `class` would shift `max_probe_ceiling` out of mprobe and the model
    # probe ceilings would silently never load (fleet-ops#3125).
    done < <(jq -r '.providers | to_entries[] | .key as $p | .value as $v | (if ($v|type)=="object" then ($v.models // {}) else {} end) | to_entries[] | [$p, .key, (.value // 0 | tostring), (if (.value|type)=="object" then (.value.class // "") else "" end), (if (.value|type)=="object" then (.value.max_probe_ceiling // "") else "" end), (if (.value|type)=="object" then (.value.audition // false) else false end)] | join("\u001f")' "$SEAT_CAPS_JSON" 2>/dev/null || true)

    SEAT_FREE_ORDER=$(jq -r '.free_providers_in_order // [] | join(" ")' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    SEAT_PREPAID_ORDER=$(jq -r '.prepaid_providers_in_order // [] | join(" ")' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    # fleet-ops#3125: product_order selects the product-pick ordering.
    # "yield" = rank every candidate by the rolling PR-yield ledger.
    SEAT_PRODUCT_ORDER=$(jq -r '.product_order // ""' "$SEAT_CAPS_JSON" 2>/dev/null || true)

    # fleet-ops#3121: senior role seat ladder (replaces keystone_only_providers
    # — one mechanism, not two; cursor stays keystone/senior-review via the
    # hardcoded _provider_is_keystone_only gate below, and the senior ladder
    # lists the seats a senior call may draw, in priority order).
    while IFS= read -r sn; do
        [[ -n "$sn" ]] || continue
        SEAT_SENIOR_ORDER+=("$sn")
    done < <(jq -r '.senior_seats_in_order // [] | .[]' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    local sr_ceiling
    sr_ceiling=$(jq -r '.senior_cursor_weekly_ceiling // 0' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    [[ "$sr_ceiling" =~ ^[0-9]+$ ]] && SEAT_SENIOR_CURSOR_CEILING="$sr_ceiling"
    ov_model=$(jq -r '.cursor_overage.overage_model // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    [[ -n "$ov_model" ]] && SEAT_CURSOR_OVERAGE_MODEL="$ov_model"
    ov_ex=$(jq -r '.cursor_overage.included_exhausted // false' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    [[ "$ov_ex" == "true" ]] && SEAT_CURSOR_INCLUDED_EXHAUSTED=1
    ov_usd=$(jq -r '.cursor_overage.daily_spend_target_usd // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    [[ "$ov_usd" =~ ^[0-9]+(\.[0-9]+)?$ ]] && SEAT_CURSOR_DAILY_TARGET_USD="$ov_usd"
    cb=$(jq -r '.walled_comeback.min_probe_interval_s // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    [[ "$cb" =~ ^[0-9]+$ ]] && SEAT_COMEBACK_MIN_PROBE_S="$cb"
    cb=$(jq -r '.walled_comeback.rate_limit_s // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    [[ "$cb" =~ ^[0-9]+$ ]] && SEAT_COMEBACK_RATE_LIMIT_S="$cb"
    cb=$(jq -r '.walled_comeback.daily_quota_s // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    [[ "$cb" =~ ^[0-9]+$ ]] && SEAT_COMEBACK_DAILY_QUOTA_S="$cb"
    cb=$(jq -r '.walled_comeback.monthly_quota_s // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    [[ "$cb" =~ ^[0-9]+$ ]] && SEAT_COMEBACK_MONTHLY_QUOTA_S="$cb"
    cb=$(jq -r '.walled_comeback.free_balance_exhausted_s // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    [[ "$cb" =~ ^[0-9]+$ ]] && SEAT_COMEBACK_FREE_BALANCE_S="$cb"
    cb=$(jq -r '.walled_comeback.credentials_bad_s // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    [[ "$cb" =~ ^[0-9]+$ ]] && SEAT_COMEBACK_CREDENTIALS_BAD_S="$cb"

    while IFS=$'\t' read -r p window budget; do
        [[ -n "$p" ]] || continue
        [[ -n "$window" ]] && SEAT_PROVIDER_QUOTA_WINDOW["$p"]="$window"
        [[ "$budget" =~ ^[0-9]+$ ]] && SEAT_PROVIDER_WEEKLY_BUDGET["$p"]="$budget"
    done < <(jq -r '.providers | to_entries[] | .key as $k | .value as $v | (if ($v|type)=="object" then [$k, ($v.quota_window // ""), ($v.weekly_budget // "")] else [$k, "", ""] end) | @tsv' "$SEAT_CAPS_JSON" 2>/dev/null || true)

    # fleet-ops 2026-08-27 #652 hot-patch: 503-overload bench default per provider.
    # Same shape as the quota_bench_default_s read above — bare numbers are
    # allowed for legacy providers (e.g. zenmux: 2) and yield a missing default.
    while IFS=$'\t' read -r p obench; do
        [[ -n "$p" ]] || continue
        [[ "$obench" =~ ^[0-9]+$ ]] && SEAT_PROVIDER_OVERLOAD_BENCH_DEFAULT["$p"]="$obench"
    done < <(jq -r '.providers | to_entries[] | .key as $k | .value as $v | (if ($v|type)=="object" then [$k, ($v.overload_bench_default_s // $v["503_bench_default_s"] // "")] else [$k, ""] end) | @tsv' "$SEAT_CAPS_JSON" 2>/dev/null || true)

    # fleet-ops#3723: per-provider daily request budget for free-model
    # accounts whose cap is per-ACCOUNT (OpenRouter free models). The budget
    # is shared across every *:free model on the provider; seat-lib counts
    # assistant turns in today's (UTC) Pi session files and benches all free
    # models on the provider once the counter hits the cap. 0/absent = no
    # daily budget (only OpenRouter carries one today).
    while IFS=$'\t' read -r p budget; do
        [[ -n "$p" ]] || continue
        [[ "$budget" =~ ^[0-9]+$ ]] && (( budget > 0 )) && SEAT_FREE_DAILY_REQUEST_BUDGET["$p"]="$budget"
    done < <(jq -r '.providers | to_entries[] | .key as $k | .value as $v | (if ($v|type)=="object" then [$k, ($v.free_model_daily_request_budget // "")] else [$k, ""] end) | @tsv' "$SEAT_CAPS_JSON" 2>/dev/null || true)

    # fleet-ops#4453: provider-level daily USD budget for an expiring daily
    # allowance (Pareto Pass $20/day). daily_budget_usd is the real allowance
    # (accept-jq reads it); daily_stop_usd is the bench threshold (margin
    # below the budget). Both must be positive numbers; daily_budget_usd with
    # no daily_stop_usd stops the stop at the budget itself. Absent = the
    # gate does not apply to that provider.
    while IFS=$'\t' read -r p dbudg dstop; do
        [[ -n "$p" ]] || continue
        [[ "$dbudg" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && (( $(awk -v a="$dbudg" 'BEGIN{print (a>0)}') == 1 )) && SEAT_PROVIDER_DAILY_BUDGET_USD["$p"]="$dbudg"
        [[ "$dstop" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && (( $(awk -v a="$dstop" 'BEGIN{print (a>0)}') == 1 )) && SEAT_PROVIDER_DAILY_STOP_USD["$p"]="$dstop"
    done < <(jq -r '.providers | to_entries[] | .key as $k | .value as $v | (if ($v|type)=="object" then [$k, ($v.daily_budget_usd // ""), ($v.daily_stop_usd // "")] else [$k, "", ""] end) | @tsv' "$SEAT_CAPS_JSON" 2>/dev/null || true)

    # fleet-ops#3111: expire-to-default for stale cap=0 seats. A stale cap=0
    # seat (intentional_cap_zero="stale") has a dated reason — "2026-08-28
    # re-audition: endpoint 404". The 2026-09-03 incident showed stale seats
    # lingering at cap=0 for weeks with nobody re-auditioning them (groq sat
    # since 2026-08-28, inferx since 2026-08-28, orcarouter since 2026-08-27)
    # while the fleet starved. After SEAT_CAP_ZERO_STALE_TTL_S (default 14d),
    # a stale cap=0 seat is automatically re-admitted at cap=1 so pick_seat
    # re-probes it on the next cycle — if the external condition cleared, the
    # seat is back; if it did not, the bench writers re-wall it and the
    # operator re-dates the reason. A seat with no parseable date in its
    # reason is NOT expired (we don't know when it was marked stale — expiring
    # it immediately would break the #1432 classification tests) but it IS
    # logged loudly as cap0-stale-undated so it can never persist silently
    # (fleet-ops#3241). Intentional
    # cap=0 seats (dead_decoy, money_only, corpse) are NEVER expired — they
    # are by-design. Tests set SEAT_CAP_ZERO_STALE_EXPIRE=0 to disable.
    _expire_stale_cap0_seats

    _seat_caps_loaded=1
    return 0
}

# fleet-ops#3873: per-seat hang-watchdog timeout. A slow seat (e.g.
# ollama/<retired-V4-flash>) does 14-149 tool calls then gets rc=124
# killed at the global 2520s (42 min) watchdog before writing final text —
# every run scored as worked-no-text / empty. The seat answers 200 and does
# real work; the timeout is too short for that seat. seat-caps.json declares
# a provider-level hang_timeout_s override; this helper reads it and falls
# back to the global default. pi-issue-run calls it after picking the seat.
# A value < 60s is ignored (defensive: a misconfigured sub-minute timeout
# would kill every session). Returns the timeout in seconds on stdout.
seat_hang_timeout_s() {
    local p="$1" m="$2" v
    (( ${_seat_caps_loaded:-0} )) || load_seat_caps >/dev/null 2>&1 || true
    v=$(jq -r --arg p "$p" '.providers[$p].hang_timeout_s // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 60 )); then
        printf '%s\n' "$v"
        return 0
    fi
    printf '%s\n' "${PI_HANG_TIMEOUT_S:-2520}"
}

# fleet-ops#3111: expire stale cap=0 seats to a default cap so pick_seat
# re-probes them after SEAT_CAP_ZERO_STALE_TTL_S. Reads the reason date from
# the SEAT_PROVIDER_REASON / model-level reason; if older than the TTL (or no
# date), bumps the cap to SEAT_CAP_ZERO_STALE_DEFAULT (default 1). Idempotent:
# re-running load_seat_caps re-evaluates against the current time. Best-effort
# logging so the operator sees which seats expired.
SEAT_CAP_ZERO_STALE_TTL_S="${SEAT_CAP_ZERO_STALE_TTL_S:-1209600}"  # 14 days
SEAT_CAP_ZERO_STALE_DEFAULT="${SEAT_CAP_ZERO_STALE_DEFAULT:-1}"
SEAT_CAP_ZERO_STALE_EXPIRE="${SEAT_CAP_ZERO_STALE_EXPIRE:-1}"

_expire_stale_cap0_seats() {
    (( ${SEAT_CAP_ZERO_STALE_EXPIRE:-1} )) || return 0
    (( ${#SEAT_CAP_ZERO_CLASS_STALE[@]} > 0 )) || return 0
    local now_s ttl default
    now_s=$(date -u +%s)
    ttl="${SEAT_CAP_ZERO_STALE_TTL_S:-1209600}"
    default="${SEAT_CAP_ZERO_STALE_DEFAULT:-1}"
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=1209600
    [[ "$default" =~ ^[0-9]+$ ]] || default=1
    local key reason date_s cap
    for key in "${!SEAT_CAP_ZERO_CLASS_STALE[@]}"; do
        # Only expire seats still at cap=0.
        cap="${SEAT_PROVIDER_CAP[$key]:-}"
        # Model-level key (contains "/"): check SEAT_MODEL_CAP.
        if [[ "$key" == */* ]]; then
            cap="${SEAT_MODEL_CAP[$key]:-}"
        fi
        [[ "$cap" == "0" ]] || continue
        reason="${SEAT_PROVIDER_REASON[$key]:-}"
        # Extract the first YYYY-MM-DD from the reason. No parseable date ->
        # do NOT expire (we don't know when it was marked stale; expiring
        # immediately would re-probe seats that may still be genuinely
        # broken) but DO log loudly: an undated stale cap can never expire,
        # so without this line it persists silently forever (fleet-ops#3241).
        date_s=0
        local date_str=""
        if [[ "$reason" =~ ([0-9]{4})-([0-9]{2})-([0-9]{2}) ]]; then
            date_str="${BASH_REMATCH[0]}"
            date_s=$(date -u -d "$date_str" +%s 2>/dev/null || echo 0)
        fi
        if (( date_s <= 0 )); then
            seat_log "cap0-stale-undated: $key stale cap=0 has no dated reason; it can never expire — audit the seat and date the reason (fleet-ops#3241)"
            continue
        fi
        if (( now_s - date_s >= ttl )); then
            if [[ "$key" == */* ]]; then
                SEAT_MODEL_CAP[$key]="$default"
            else
                SEAT_PROVIDER_CAP[$key]="$default"
            fi
            # fleet-ops#4129: a re-admitted stale cap=0 seat was broken (404,
            # TPM ceiling, exhausted quota). Re-probe it on LIGHT only — never
            # heavy/keystone/senior-review — until a light re-probe proves it
            # answers. The 2026-09-07 incident put a heavy fable-check on a
            # cap0-stale laguna free seat the instant it was re-admitted, before
            # any probe had run. Keyed identically to the cap write above.
            SEAT_REPROBE_LIGHT_ONLY[$key]=1
            seat_log "cap0-stale-expire: $key stale cap=0 expired (age=$((now_s - date_s))s; reason dated ${date_str}) -> re-admitted at cap=$default for re-probe (light-only, fleet-ops#4129) (fleet-ops#3111)"
        fi
    done
    return 0
}

# Sum of all provider caps (lower bound on fleet capacity). 0 if caps not loaded.
total_seat_cap() {
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    local p cap total=0
    for p in "${!SEAT_PROVIDER_CAP[@]}"; do
        cap="${SEAT_PROVIDER_CAP[$p]:-0}"
        total=$((total + cap))
    done
    echo "$total"
}

# Cap for one provider (0 if unknown). 0 is a real value (zenmux); the caller
# must distinguish "no cap" from "cap is 0" via the caps-loaded flag.
provider_cap() {
    local p="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    echo "${SEAT_PROVIDER_CAP[$p]:-0}"
}

# Cap for one provider/model pair. 0 if unlisted; provider cap wins if smaller.
model_cap() {
    local p="$1" m="$2"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    echo "${SEAT_MODEL_CAP[$p/$m]:-0}"
}

class_of() {
    local p="$1" c
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    c="${SEAT_PROVIDER_CLASS[$p]:-free}"
    [[ "$c" == "subscription" ]] && c="prepaid-quota"
    echo "$c"
}

# Class for a specific provider/model. A provider may carry both free and
# non-free lanes (e.g. cline has cline-pass/ subscription seats and a free
# z-ai/glm-5.3-flash seat). The model's class is the first available of:
#   1) an explicit class on the {cap, class} object in the per-model map,
#   2) the provider class from the cap map.
# Per-model class overrides allow a free lane inside an otherwise
# prepaid-quota/metered provider to be bucketed as free, so the free-tier
# privacy line and order are honoured for that specific lane (fleet-ops#384).
model_class_of() {
    local p="$1" m="$2" c
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    c="${SEAT_MODEL_CLASS[$p/$m]:-}"
    if [[ -z "$c" ]]; then
        c=$(class_of "$p")
    fi
    [[ "$c" == "subscription" ]] && c="prepaid-quota"
    echo "$c"
}

# True (return 0) when the provider is configured as a remote agent. Remote
# agents (e.g. devin) run outside the local Pi harness, so a session may finish
# with zero local tool calls while still producing a real outcome (e.g. a PR
# URL). Empty-run detection must judge by outcome, not by local tool count
# (fleet-ops#3531).
provider_remote_agent() {
    local p="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    [[ "${SEAT_PROVIDER_REMOTE_AGENT[$p]:-0}" == "1" ]]
}

# fleet-ops#4690: `devin --sandbox` talks to a gh proxy at localhost:3128.
# If /etc/hosts has no IPv4 localhost, getent ahosts localhost has no
# 127.0.0.1 line, the sandbox cannot reach the proxy, and every devin run
# burns as empty-success. This is a HOST class, not a 900s empty-run timer:
# hold while the class is true, release the instant 127.0.0.1 is back.
# FLEET_SANDBOX_LOCALHOST_AHOSTS (even empty) is the test seam; unset uses
# live `getent ahosts localhost`.
sandbox_localhost_resolves() {
    local out
    if [[ -n "${FLEET_SANDBOX_LOCALHOST_AHOSTS+x}" ]]; then
        out="$FLEET_SANDBOX_LOCALHOST_AHOSTS"
    else
        out=$(getent ahosts localhost 2>/dev/null || true)
    fi
    grep -q '^127.0.0.1' <<<"$out"
}

# True when captured stdout/stderr carries the live sandbox proxy signature.
# Args are TEXT (not paths), matching is_quota_cap_error / is_overload_error.
is_sandbox_localhost_error() {
    local out="$1" err="$2"
    grep -qiF 'error connecting to localhost' <<<"$out"$'\n'"$err"
}

# fleet-ops#4825: the Devin CLI refuses an untrusted workspace with the literal
# "Refusing to run in an untrusted workspace". This is a CONFIG/TRUST fault, not
# a seat yield, not a quota wall, not a transient retry. The seat-retirement
# standing rule classes config/trust faults as INFRASTRUCTURE: the seat is
# skipped (benched) but NEVER retired on it, so devin is not walled out of the
# fleet by a misconfigured trust key. The fix is the managed config key
# `skip_workspace_trust: true` (pinned by install.sh), but the detector must
# still classify the literal so a future vendor change that re-breaks the
# config cannot silently retire the seat as an ordinary failure.
is_workspace_trust_error() {
    local out="$1" err="$2"
    local combined="$out"$'\n'"$err"
    [[ -n "$combined" ]] || return 1
    grep -qiF 'Refusing to run in an untrusted workspace' <<<"$combined"
}

# fleet-ops#4780: the Devin CLI under `--sandbox` forces its "autonomous"
# permission mode, which since 2026-09-08 rejects every file write
# non-interactively with the literal "rejected a tool call that requires
# confirmation". Every run then ends empty at the first edit (100% empty
# runs, 30+ on 2026-09-09). This is a CLI/flag CONFIG fault, not a seat
# yield: the fix is dropping `--sandbox` (the provider now runs
# `--permission-mode dangerous` unsandboxed, standing VPS write autonomy
# Nish 2026-08-05). The detector must still classify the literal so a
# future vendor change that re-breaks the flag cannot silently retire the
# seat as an ordinary failure.
is_devin_writes_rejected() {
    local out="$1" err="$2"
    local combined="$out"$'\n'"$err"
    [[ -n "$combined" ]] || return 1
    grep -qiF 'rejected a tool call that requires confirmation' <<<"$combined"
}

# fleet-ops#5189: a seat behind a tool-approval gate can end a run rc=0 while
# every write the agent attempted was refused — the run "succeeds", the
# report says the verdicts "did not post", and nothing escalates (the
# orchestrator-decision-sweep drafted 10+ verdicts across five 2026-09-10
# sweeps on cursor/cursor-grok-4.6-high under --auto-review and landed none;
# the unit exited 0 each time). Two signals, either is a match:
#   1. the WRITES-REFUSED contract sentinel — a write-doing prompt declares a
#      refused required write with that marker (prompts declare it; the
#      runner greps it);
#   2. the refusal phrases the gated seats already produce in stdout:
#      "approval card(s) rejected" (cursor's auto-review card), "blocked by
#      auto-review" / "auto-review blocked", and devin's "rejected a tool
#      call" literal (same class, different seat).
# Args are TEXT (not paths), matching is_quota_cap_error / is_overload_error.
is_writes_refused() {
    local out="$1" err="$2"
    local combined="$out"$'\n'"$err"
    [[ -n "$combined" ]] || return 1
    if grep -q 'WRITES-REFUSED' <<<"$combined"; then
        return 0
    fi
    grep -qiE 'approval[[:space:]-]?cards?[[:space:]]+(were|was[[:space:]]+)?(rejected|refused|denied)|blocked[[:space:]]+by[[:space:]]+(cursor[[:space:]]+)?auto-review|auto-review[[:space:]]+blocked|rejected[[:space:]]+a[[:space:]]+tool[[:space:]]+call' <<<"$combined"
}

# Default bench window (seconds) for a provider's quota/cap 429 when the
# error text carries no explicit reset window (fleet-ops#90). 0 = no default
# configured; the writer then fails open (no marker) and relies on the
# reactive seat-health ledger's existing quota_exhausted block.
provider_quota_bench_default() {
    local p="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    echo "${SEAT_PROVIDER_BENCH_DEFAULT[$p]:-0}"
}

# --- live quota reset from fleet-metrics-export (fleet-ops#4217) ------------
# The exporter writes fleet_seat_quota_{remaining_pct,reset_seconds,
# observed_seconds}{provider,window} into the node_exporter textfile from each
# provider's OWN usage endpoint. When a quota wall's error text carries no
# parseable reset window, a fresh live row beats the static
# quota_bench_default_s guess in seat-caps.json: it is the provider's real
# reset horizon (the issue's motivation: xai benched 7d for a 1.5d reset).
#
# Only EXHAUSTED windows count (remaining_pct <= SEAT_LIVE_QUOTA_EXHAUSTED_PCT,
# default 1): a window with 95% left resetting in 14h is not this wall's
# recovery time, and benching on it would re-create the opposite over-bench
# (Devin benched 22h at 94% weekly left). Across exhausted windows the MINIMUM
# positive reset wins — the soonest the seat can plausibly recover.
#
# reset_seconds is as-of-observation, so observed_seconds is subtracted;
# observations older than SEAT_LIVE_QUOTA_STALE_S (900s, the exporter's own
# QUOTA_STALE_S) are not trusted.
#
# Echoes integer seconds > 0, or 0 when there is no usable live figure (file
# missing/unreadable, no rows for the provider, stale observation, no exhausted
# window, or the reset has already passed). Callers fall back to the static
# default — this helper must never brick a bench decision.
SEAT_LIVE_QUOTA_PROM="${SEAT_LIVE_QUOTA_PROM:-/var/lib/prometheus/node-exporter/fleet.prom}"
# fleet-ops#5022: a prepaid subscription's SHORT window (OpenCode Go's 5-hour
# rolling window, written by bin/fleet-prepaid-util-canary) is walled well
# before it is fully exhausted, so it uses a USED-percent threshold where the
# fleet_seat_quota_* source uses a remaining-percent one. Same purpose: when a
# quota wall's error text carries no reset window, bench the seat to the
# window's real reset instead of the static quota_bench_default_s.
SEAT_LIVE_PREPAID_PROM="${SEAT_LIVE_PREPAID_PROM:-/var/lib/prometheus/node-exporter/prepaid-usage.prom}"
SEAT_LIVE_PREPAID_WALL_PCT="${SEAT_LIVE_PREPAID_WALL_PCT:-95}"
SEAT_LIVE_QUOTA_STALE_S="${SEAT_LIVE_QUOTA_STALE_S:-900}"
SEAT_LIVE_QUOTA_EXHAUSTED_PCT="${SEAT_LIVE_QUOTA_EXHAUSTED_PCT:-1}"

provider_live_reset_s() {
    local p="$1" out
    out=$(_provider_seat_quota_reset_s "$p")
    if [[ "$out" =~ ^[0-9]+$ ]] && (( out > 0 )); then
        echo "$out"
        return 0
    fi
    _provider_prepaid_reset_s "$p"
}

# fleet_seat_quota_* source (fleet-metrics-export.py): only an EXHAUSTED window
# (remaining_pct <= SEAT_LIVE_QUOTA_EXHAUSTED_PCT) counts.
_provider_seat_quota_reset_s() {
    local p="$1"
    [[ -r "$SEAT_LIVE_QUOTA_PROM" ]] || { echo 0; return 0; }
    awk -v prov="$p" -v stale="$SEAT_LIVE_QUOTA_STALE_S" -v thresh="$SEAT_LIVE_QUOTA_EXHAUSTED_PCT" '
        function label(line, key,    re, s) {
            re = key "=\"[^\"]*\""
            if (match(line, re)) {
                s = substr(line, RSTART, RLENGTH)
                sub("^" key "=\"", "", s)
                sub("\"$", "", s)
                return s
            }
            return ""
        }
        /^fleet_seat_quota_observed_seconds\{/ && label($1, "provider") == prov {
            obs = $2 + 0; have_obs = 1
        }
        /^fleet_seat_quota_remaining_pct\{/ && label($1, "provider") == prov {
            rem[label($1, "window")] = $2 + 0
        }
        /^fleet_seat_quota_reset_seconds\{/ && label($1, "provider") == prov {
            rst[label($1, "window")] = $2 + 0
        }
        END {
            if (!have_obs || obs > stale + 0) { print 0; exit }
            best = 0
            for (w in rst) {
                if (!(w in rem) || rem[w] > thresh + 0) continue
                live = int(rst[w] - obs)
                if (live <= 0) continue
                if (best == 0 || live < best) best = live
            }
            print best
        }
    ' "$SEAT_LIVE_QUOTA_PROM" 2>/dev/null || echo 0
}

# fleet_prepaid_usage_pct / fleet_prepaid_window_reset_seconds source
# (bin/fleet-prepaid-util-canary, fleet-ops#5022): the provider's own usage
# endpoint says what percent of the SHORT (5h) window is used and when it
# resets. A window at/above SEAT_LIVE_PREPAID_WALL_PCT used is this wall's
# recovery time. Honours the same freshness bound as the fleet_seat_quota
# source; the emitted observed timestamp is absolute, so "now" comes from the
# caller (awk's systime() is a gawk extension this box does not have).
_provider_prepaid_reset_s() {
    local p="$1" now
    [[ -r "$SEAT_LIVE_PREPAID_PROM" ]] || { echo 0; return 0; }
    now=$(date -u +%s)
    awk -v prov="$p" -v wall="$SEAT_LIVE_PREPAID_WALL_PCT" -v stale="$SEAT_LIVE_QUOTA_STALE_S" -v now="$now" '
        function label(line, key,    re, s) {
            re = key "=\"[^\"]*\""
            if (match(line, re)) {
                s = substr(line, RSTART, RLENGTH)
                sub("^" key "=\"", "", s)
                sub("\"$", "", s)
                return s
            }
            return ""
        }
        /^fleet_prepaid_usage_pct\{/ && label($1, "provider") == prov && label($1, "window") == "5h" {
            used = $2 + 0; have_used = 1
        }
        /^fleet_prepaid_window_reset_seconds\{/ && label($1, "provider") == prov && label($1, "window") == "5h" {
            rst = $2 + 0; have_rst = 1
        }
        /^fleet_prepaid_usage_observed_timestamp\{/ && label($1, "provider") == prov {
            obs = $2 + 0; have_obs = 1
        }
        END {
            if (!have_used || !have_rst || !have_obs) { print 0; exit }
            if (used + 0 < wall + 0) { print 0; exit }
            age = now - obs
            if (age < 0) age = 0
            if (age > stale + 0) { print 0; exit }
            live = int(rst - age)
            if (live <= 0) { print 0; exit }
            print live
        }
    ' "$SEAT_LIVE_PREPAID_PROM" 2>/dev/null || echo 0
}

# --- wall ceiling: the provider's real reset horizon (fleet-ops#2563) -------
# A vendor can advertise a reset window far longer than its own quota cycle.
# Live: cline/cline-pass/minimax-m3 came back HTTP 402 with
# retry_after=1530000 (17.7 days), so the ledger was written
# usable_at=2026-09-19 from a provider whose seat-caps.json row declares
# quota_window="weekly". A 19-day wall on a weekly-resetting seat is not a
# quota window; it is a seat frozen for three reset cycles, and nothing else
# bounds it (consecutive_failure_count was 6, nowhere near
# SEAT_FAILURE_CEILING=20, so the failure-ceiling park never engages).
#
# The bound already exists in config as `quota_window` — it was loaded into
# SEAT_PROVIDER_QUOTA_WINDOW and read by exactly one consumer (_prepaid_paced,
# weekly-pace only). This turns it into the wall ceiling too, so no new config
# key is needed: a provider that declares its reset cycle gets its walls capped
# at one cycle and is re-probed at that cadence instead of frozen for the whole
# vendor-claimed countdown. A provider with no quota_window keeps the legacy
# behaviour (0 = no ceiling).
#
# The ceiling is a RE-PROBE CADENCE, not a claim the quota reset: seat_usable
# fail-opens after the wall, the probe either works or re-benches for one more
# cycle. Cost of being wrong is one failed probe per cycle; cost of honouring
# the vendor number is a dead seat for weeks.
provider_wall_ceiling_s() {
    local p="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    case "${SEAT_PROVIDER_QUOTA_WINDOW[$p]:-}" in
        hourly)  echo 3600 ;;
        daily)   echo 86400 ;;
        weekly)  echo 604800 ;;
        monthly) echo 2678400 ;;   # 31d — the longest real monthly cycle
        *)       echo 0 ;;
    esac
}

# Echo the effective wall ISO timestamp for a provider, capped at the
# provider's reset horizon measured from <anchor> (the marker's observed_at,
# or now when that is empty/unparseable). Echoes <wall> unchanged when the
# provider declares no quota_window, when either timestamp will not parse, or
# when the wall is already inside the horizon. Never widens a wall.
_wall_capped_at_horizon() {
    local p="$1" anchor="$2" wall="$3"
    local ceil wall_s anchor_s max_s
    ceil=$(provider_wall_ceiling_s "$p")
    if [[ ! "$ceil" =~ ^[0-9]+$ ]] || (( ceil <= 0 )); then printf '%s' "$wall"; return 0; fi
    wall_s=$(date -u -d "$wall" +%s 2>/dev/null || echo 0)
    [[ "$wall_s" =~ ^[0-9]+$ ]] && (( wall_s > 0 )) || { printf '%s' "$wall"; return 0; }
    anchor_s=0
    [[ -n "$anchor" ]] && anchor_s=$(date -u -d "$anchor" +%s 2>/dev/null || echo 0)
    [[ "$anchor_s" =~ ^[0-9]+$ ]] && (( anchor_s > 0 )) || anchor_s=$(date -u +%s)
    max_s=$(( anchor_s + ceil ))
    if (( wall_s > max_s )); then
        date -u -d "@$max_s" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$wall"
        return 0
    fi
    printf '%s' "$wall"
}

# Default bench window (seconds) for a provider's 503/upstream-overload storm
# when the error text carries no Retry-After / reset window (fleet-ops #652
# 2026-08-27 hot-patch). Mirrors provider_quota_bench_default: 0 = no default
# configured; the writer then fails open (no marker) and pick_seat re-offers
# the same seat, which immediately hits the same 503 storm again.
provider_overload_bench_default() {
    local p="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    echo "${SEAT_PROVIDER_OVERLOAD_BENCH_DEFAULT[$p]:-0}"
}

# --- Provider-overload wedge (fleet-ops#2661) -------------------------------
# A partial 503 storm (PONG probes pass but tool-loading 503s) benches 2+
# seats on the SAME provider inside a short window, and each of those walls expiry
# shortly after— so per-seat bench expiry alone would re-release them straight back
# into the storm. The escalation lanes (stop-escalation-dispatch,
# alert-repair-dispatch) must NEVER land on a provider mid-storm: they are the
# lanes that diagnose/repair the storm's damage, and a dispatch into the storm just
# dies the same way the workers died. This helper counts this provider's seats
# currently or recently in overload_bench: a seat whose overload wall end
# (bench_until ?? usable_at) is still in the future OR expired within the trailing
# PROVIDER_OVERLOAD_WEDGE_WINDOW_S. When the count reaches
# PROVIDER_OVERLOAD_WEDGE_MIN (2) the provider is WEDGED — pick_seat's
# gated skip and alert-repair-dispatch's Python mirror exclude it from the
# escalation ladder entirely. Workers do NOT set the gate env: their per-seat
# seat_usable() benches are the right granularity for them; the wedge is the
# escalation-only isolation the issue asks for.
PROVIDER_OVERLOAD_WEDGE_WINDOW_S="${PROVIDER_OVERLOAD_WEDGE_WINDOW_S:-1800}"
PROVIDER_OVERLOAD_WEDGE_MIN="${PROVIDER_OVERLOAD_WEDGE_MIN:-2}"

# Returns 0 (wedged) when this provider has >= PROVIDER_OVERLOAD_WEDGE_MIN
# seats in overload_bench whose wall end is in the future or expired within
# the trailing window; 1 (not wedged) otherwise. Never raises: a missing/
# unreadable ledger dir or a bad timestamp counts nothing (fail-open: a flaky
# read must not brick the whole pick).
provider_overload_wedged() {
    local p="$1" f hc p2 wall_end we now_e window_s min_n count=0
    now_e=$(_seat_now_epoch)
    window_s="${PROVIDER_OVERLOAD_WEDGE_WINDOW_S:-1800}"
    min_n="${PROVIDER_OVERLOAD_WEDGE_MIN:-2}"
    for f in "$LEDGER_DIR"/*__*.json; do
        [[ -f "$f" ]] || continue
        [[ "$(basename "$f")" != *".spawn-bench.json" ]] || continue
        hc=$(jq -r '.health_class // ""' "$f" 2>/dev/null || true)
        [[ "$hc" == "overload_bench" ]] || continue
        p2=$(jq -r '.provider // ""' "$f" 2>/dev/null || true)
        [[ "$p2" == "$p" ]] || continue
        wall_end=$(jq -r '(.bench_until // .usable_at // "")' "$f" 2>/dev/null || true)
        [[ -n "$wall_end" ]] || continue
        we=$(date -u -d "${wall_end%Z}" +%s 2>/dev/null || echo 0)
        [[ "$we" =~ ^[0-9]+$ ]] || continue
        # Wall end in the future OR expired within the trailing window — i.e.
        # this seat was in overload_bench within that window. A seat whose wall
        # expired longer ago is not recent storm evidence and must not wedge.
        (( we >= now_e - window_s )) || continue
        count=$((count + 1))
        (( count >= min_n )) && return 0
    done
    return 1
}

# --- AIMD learned caps (fleet-ops#217, re-land #424) ------------------------
# Declared cap in seat-caps.json is the FLOOR. pick_seat may admit cap+1
# (additive probe) when zero provider errors + RAM headroom + room below
# max_probe_ceiling, and backs off to ~0.5x on a 429/concurrency signal
# from the per-seat health ledger. Learned state persists in
# learned-caps.json; every change writes one line to learned-caps-audit.log.
# This library is the reader of that log (fleet-ops#424: leftover meter
# after auto-revert had no reader).
#
# Authority: the existing per-seat health ledger (LEDGER_DIR). No network,
# no wrapper scripts. File reads at pick_seat time only.
#
# hard_ceiling rows (devin, ollama) never probe and never back off below
# declared. Metered rows default max_probe_ceiling to declared so
# money-adjacent seats never climb without a ledger line.
LEARNED_CAPS_JSON="${LEARNED_CAPS_JSON:-$HOME/.local/state/pi-packet/learned-caps.json}"
LEARNED_CAPS_AUDIT="${LEARNED_CAPS_AUDIT:-$HOME/.local/state/pi-packet/learned-caps-audit.log}"
_seat_learned_loaded=0
declare -A LEARNED_CAP=()
declare -A LEARNED_BENCH_UNTIL=()
# fleet-ops#3690: ramp flag. A provider whose cap block changed on deploy is
# seeded at floor/2 with ramp=true so the next tick starts low and climbs +1
# per probe instead of bursting to declared. While ramp=true the declared
# floor clamp is bypassed (eff may sit below declared); graduating to declared
# clears the flag and normal AIMD resumes.
declare -A LEARNED_RAMP=()

# fleet-ops#4723: ramp graduates on staleness. A ramp=true entry bypasses the
# declared floor clamp and climbs only +1 per probe, and a probe needs the
# provider to be picked. A provider seeded at floor/2 by a deploy cap change
# and then walled (quota, 429, corpse) is never picked, never probes, and so
# stays pinned below its declared cap forever once the wall lifts — decay is
# fast, ramp needs traffic, traffic needs cap. Measured 2026-09-09: xkiro sat
# at learned_cap=1 of declared 3 with last_at 2026-09-07T16:58Z (42h stale),
# alongside zenmux, alibaba-coding, crof and straitly, while the intake
# reported 3 usable seat slots against target_concurrent=25.
#
# No AIMD write within LEARNED_RAMP_STALE_S proves no traffic in that window,
# and no traffic is no evidence of harm, so the slow-start has nothing left to
# protect: drop the flag and let the declared floor apply again. This is the
# same graduation effective_provider_cap already performs when a ramp reaches
# declared, reached by elapsed time instead of by probes. The declared cap is
# the config-pinned value, and the RAM governor, the usable-seat-slot gate
# (fleet-ops#3732) and spawn_stagger still bound the resulting spawn rate, so
# this cannot reproduce the fleet-ops#3690 reset-then-burst (that was a reset
# of learned_cap itself to null, not a flag graduation).
LEARNED_RAMP_STALE_S="${LEARNED_RAMP_STALE_S:-21600}"

# 0 (true) iff $1 is an ISO8601 timestamp older than LEARNED_RAMP_STALE_S.
# An absent or unparseable timestamp is NOT stale: never graduate a ramp on a
# reading failure, that would be a silent cap raise on bad data.
_learned_ramp_stale() {
    local ts="$1" epoch now
    [[ -n "$ts" ]] || return 1
    epoch=$(date -u -d "$ts" +%s 2>/dev/null) || return 1
    [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
    now=$(date -u +%s)
    (( now - epoch >= LEARNED_RAMP_STALE_S ))
}

load_learned_caps() {
    LEARNED_CAP=()
    LEARNED_BENCH_UNTIL=()
    LEARNED_RAMP=()
    _seat_learned_loaded=1
    [[ -f "$LEARNED_CAPS_JSON" ]] || return 0
    local p lc bu ramp last_at
    while IFS=$'\x1f\n' read -r p lc bu ramp last_at; do
        [[ -n "$p" ]] || continue
        [[ "$lc" =~ ^[0-9]+$ ]] && LEARNED_CAP["$p"]="$lc"
        [[ -n "$bu" ]] && LEARNED_BENCH_UNTIL["$p"]="$bu"
        if [[ "$ramp" == "true" ]] && ! _learned_ramp_stale "$last_at"; then
            LEARNED_RAMP["$p"]=1
        fi
    done < <(jq -r '.providers // {} | to_entries[] | [.key, (.value.learned_cap//""), (.value.bench_until//""), (.value.ramp|tostring), (.value.last_at//"")] | join("\u001f")' "$LEARNED_CAPS_JSON" 2>/dev/null || true)
}

# Hard upper bound a provider may probe to. Absent -> declared cap (no
# upward probe). Money-adjacent default: never climb without an explicit
# max_probe_ceiling in seat-caps.json.
max_probe_ceiling() {
    local p="$1" declared
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    if [[ -n "${SEAT_PROVIDER_MAX_PROBE[$p]:-}" ]]; then
        echo "${SEAT_PROVIDER_MAX_PROBE[$p]}"
        return
    fi
    declared=$(provider_cap "$p")
    echo "$declared"
}

# 0 if the provider is a declared hard ceiling (never probe above declared).
provider_hard_ceiling() {
    local p="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    [[ "${SEAT_PROVIDER_HARD_CEILING[$p]:-0}" == "1" ]]
}

provider_reason() {
    local p="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    echo "${SEAT_PROVIDER_REASON[$p]:-}"
}

# True if the provider has a FRESH 429/concurrency signal in the per-seat
# ledger. credentials_bad and seat_dead are NOT rate signals.
provider_has_recent_error() {
    local p="$1" f hc dead observed usable_at bench_until
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    local m
    while IFS=$'\t' read -r pm m _ _; do
        [[ "$pm" == "$p" ]] || continue
        f=$(seat_ledger_path "$p" "$m")
        [[ -f "$f" ]] || continue
        IFS=$'\x1f'$'\n' read -r hc dead observed usable_at bench_until < <(
            jq -r '[(.health_class//""),(.seat_dead|tostring),(.observed_at//""),(.usable_at//""),(.bench_until//"")] | join("\u001f")' "$f" 2>/dev/null || true
        )
        case "$hc" in
            rate_limited)
                if _seat_rate_limit_fresh "$observed" && [[ -n "$usable_at" ]] && _seat_in_future "$usable_at"; then
                    return 0
                fi ;;
            quota_exhausted|quota_bench)
                local bu="$bench_until"; [[ -z "$bu" ]] && bu="$usable_at"
                if [[ -n "$bu" ]] && _seat_in_future "$bu"; then
                    return 0
                fi ;;
        esac
    done < <(enumerate_seats)
    return 1
}

# Soonest future bench_until/usable_at across this provider's walled models.
_provider_bench_until() {
    local p="$1" f hc observed usable_at bench_until soonest=""
    local m
    while IFS=$'\t' read -r pm m _ _; do
        [[ "$pm" == "$p" ]] || continue
        f=$(seat_ledger_path "$p" "$m")
        [[ -f "$f" ]] || continue
        IFS=$'\x1f'$'\n' read -r hc observed usable_at bench_until < <(
            jq -r '[(.health_class//""),(.observed_at//""),(.usable_at//""),(.bench_until//"")] | join("\u001f")' "$f" 2>/dev/null || true
        )
        [[ "$hc" == "rate_limited" || "$hc" == "quota_exhausted" || "$hc" == "quota_bench" ]] || continue
        local bu="$bench_until"
        [[ -z "$bu" ]] && bu="$usable_at"
        if [[ -z "$bu" ]] || ! _seat_in_future "$bu"; then continue; fi
        if [[ -z "$soonest" ]]; then
            soonest="$bu"
        else
            local s_s b_s
            s_s=$(date -u -d "$soonest" +%s 2>/dev/null || echo 0)
            b_s=$(date -u -d "$bu" +%s 2>/dev/null || echo 0)
            (( b_s > 0 && b_s < s_s )) && soonest="$bu"
        fi
    done < <(enumerate_seats)
    echo "$soonest"
}

# fleet-ops#3677: cap the AIMD backoff bench so a prepaid seat re-probes
# within 15-30 min of a resource_exhausted, NOT the hours the per-seat
# ledger's wall may carry (the Devin sub was ~85-97% unused while one backoff
# pinned learned_cap=2 of 7 declared for ~6h). floor/2 remains the immediate
# cap reduction; the bench is only a "don't re-probe" gate. Growth never
# exceeds the provider's real quota reset window (devin quota_bench_default_s
# =900), with 1800s as the hard ceiling when the provider sets no default.
# Args: provider ledger_bench_until (RFC3339, may be empty). Echoes a capped
# bench_until, or empty when $2 is empty.
_provider_backoff_bench_until() {
    local p="$1" raw="$2"
    local cap_s=1800 rw now_s raw_s capped_s
    rw=$(provider_quota_bench_default "$p")
    if [[ "$rw" =~ ^[0-9]+$ ]] && (( rw > 0 )); then
        (( rw < cap_s )) && cap_s=$rw
    fi
    [[ -n "$raw" ]] || { echo ""; return; }
    now_s=$(date -u +%s)
    raw_s=$(date -u -d "$raw" +%s 2>/dev/null || echo 0)
    capped_s=$(( now_s + cap_s ))
    if (( raw_s > 0 && raw_s <= capped_s )); then
        echo "$raw"
    else
        date -u -d "@$capped_s" +%Y-%m-%dT%H:%M:%SZ
    fi
}

_learned_audit() {
    local line="$1"
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >>"$LEARNED_CAPS_AUDIT" 2>/dev/null || true
}

_set_learned_in_memory() {
    local p="$1" lc="$2" bench="${3:-}" ramp="${4:-}"
    LEARNED_CAP["$p"]="$lc"
    if [[ -n "$bench" ]]; then
        LEARNED_BENCH_UNTIL["$p"]="$bench"
    else
        unset 'LEARNED_BENCH_UNTIL[$p]'
    fi
    if [[ "$ramp" == "1" ]]; then
        LEARNED_RAMP["$p"]=1
    elif [[ "$ramp" == "0" ]]; then
        unset 'LEARNED_RAMP[$p]'
    fi
}

# Persist learned state for one provider and emit an audit line.
# Args: provider learned_cap result bench_until [ramp]
# result in {probe, backoff, decay, ramp}. ramp in {0,1}; absent preserves the
# current in-memory LEARNED_RAMP[$p] (so probes during a ramp keep the flag
# until graduation clears it explicitly with ramp=0).
_record_learned_cap() {
    local p="$1" lc="$2" result="$3" bench="${4:-}" ramp="${5:-}"
    [[ "$lc" =~ ^[0-9]+$ ]] || return 1
    # Absent ramp arg: preserve the current flag (probe during ramp stays ramp).
    local ramp_val="${LEARNED_RAMP[$p]:-0}"
    [[ "$ramp" == "0" || "$ramp" == "1" ]] && ramp_val="$ramp"
    mkdir -p "$(dirname "$LEARNED_CAPS_JSON")" 2>/dev/null || true
    local tmp="$LEARNED_CAPS_JSON.tmp.$$.$RANDOM" now_utc
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local ramp_json
    [[ "$ramp_val" == "1" ]] && ramp_json="true" || ramp_json="false"
    if [[ -f "$LEARNED_CAPS_JSON" ]] && jq -e . "$LEARNED_CAPS_JSON" >/dev/null 2>&1; then
        # Merge via object addition, not $ps[$p] = ... jq 1.7 rejects
        # assignment through a variable-held object ("Invalid path
        # expression") and the fallback would then rewrite the file with
        # only this provider, wiping sibling learned caps.
        if jq --arg p "$p" --argjson lc "$lc" --arg r "$result" \
                --arg b "$bench" --arg t "$now_utc" --argjson ramp "$ramp_json" \
            '.providers = ((.providers // {}) + {($p): {learned_cap:$lc, last_result:$r, bench_until:(if $b == "" then null else $b end), ramp:$ramp, last_at:$t}})' \
            "$LEARNED_CAPS_JSON" >"$tmp" 2>/dev/null; then
            :
        else
            rm -f "$tmp" 2>/dev/null || true
            tmp=""
        fi
    else
        tmp=""
    fi
    if [[ -z "$tmp" || ! -s "$tmp" ]]; then
        tmp="$LEARNED_CAPS_JSON.tmp.$$.$RANDOM"
        if ! jq -nc --arg p "$p" --argjson lc "$lc" --arg r "$result" \
            --arg b "$bench" --arg t "$now_utc" --argjson ramp "$ramp_json" \
            '{providers: {($p): {learned_cap:$lc, last_result:$r, bench_until:(if $b == "" then null else $b end), ramp:$ramp, last_at:$t}}}' >"$tmp" 2>/dev/null; then
            seat_log "aimd: state write FAILED for $p (lc=$lc result=$result) — in-memory only"
            rm -f "$tmp" 2>/dev/null || true
            _set_learned_in_memory "$p" "$lc" "$bench" "$ramp_val"
            return 0
        fi
    fi
    chmod 0644 "$tmp" 2>/dev/null || true
    if mv "$tmp" "$LEARNED_CAPS_JSON" 2>/dev/null; then
        _set_learned_in_memory "$p" "$lc" "$bench" "$ramp_val"
        local bench_desc="no bench"
        if [[ -n "$bench" ]]; then
            local bs nowb
            nowb=$(date -u +%s)
            bs=$(date -u -d "$bench" +%s 2>/dev/null || echo 0)
            bs=$(( bs > nowb ? bs - nowb : 0 ))
            bench_desc="bench=${bs}s bench_until=$bench"
        fi
        local ramp_desc=""
        [[ "$ramp_val" == "1" ]] && ramp_desc=" ramp"
        _learned_audit "aimd $p: learned_cap=$lc result=$result$bench_desc$ramp_desc"
        return 0
    fi
    seat_log "aimd: state rename FAILED for $p at $LEARNED_CAPS_JSON — in-memory only"
    rm -f "$tmp" 2>/dev/null || true
    _set_learned_in_memory "$p" "$lc" "$bench" "$ramp_val"
    return 0
}

# fleet-ops#3690: reset learned AIMD state ONLY for providers whose
# providers.<p> block changed between the old and new seat-caps.json, not the
# whole file. A ram_gb_per_worker / worker_memory / spawn_stagger_s edit
# touches top-level fields and must NOT reset AIMD — the old whole-file wipe
# (install.sh pre-#3690) dropped every provider to null and the next tick
# burst to declared caps (5 devin spawns at once, all rc=143 in <30s). For
# each changed provider, drop its learned entries (the "p" key and any "p/*"
# model keys) and seed learned_cap=floor/2 with ramp=true so the next tick
# starts low and ramps +1 per probe instead of bursting to declared.
# Unchanged providers keep their learned state. Best-effort: a jq failure
# logs and leaves the file unchanged. Args: old_caps new_caps learned_caps
reset_learned_caps_on_provider_change() {
    local old_caps="$1" new_caps="$2" learned="$3"
    [[ -f "$old_caps" && -f "$new_caps" && -f "$learned" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    cmp -s "$old_caps" "$new_caps" && return 0
    local now_utc bak tmp changed_list
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    changed_list=$(jq -n --slurpfile old "$old_caps" --slurpfile new "$new_caps" '
        ($old[0].providers // {}) as $o | ($new[0].providers // {}) as $n |
        (($o | keys) + ($n | keys)) | unique | .[] |
        select(($o[.] // "" | tostring) != ($n[.] // "" | tostring))
    ' 2>/dev/null || true)
    [[ -n "$changed_list" ]] || return 0
    bak="$learned.bak-$(date -u +%Y%m%dT%H%M%SZ)"
    cp -f "$learned" "$bak" 2>/dev/null || true
    tmp="$learned.tmp.$$.$RANDOM"
    if jq -n --slurpfile old "$old_caps" --slurpfile new "$new_caps" \
            --slurpfile lc "$learned" --arg t "$now_utc" '
        ($old[0].providers // {}) as $o |
        ($new[0].providers // {}) as $n |
        ($lc[0].providers // {}) as $prov |
        (($o | keys) + ($n | keys)) as $all |
        ($all | unique | map(select(($o[.] // "" | tostring) != ($n[.] // "" | tostring)))) as $changed |
        ($changed | map(. + "/")) as $pfxs |
        {
            providers: (
                ($prov | with_entries(select(
                    .key as $k |
                    ($changed | index($k) | not) and
                    ($pfxs | map(. as $pfx | $k | startswith($pfx)) | any | not)
                ))) +
                ($changed | map(. as $p |
                    ($n | has($p)) as $exists |
                    if $exists then
                        ($n[$p]) as $pv |
                        {($p): {
                            learned_cap: (($pv | if type == "number" then . else (.cap // 1) end) | if . < 2 then 1 else (. / 2 | floor) end),
                            last_result: "ramp",
                            ramp: true,
                            bench_until: null,
                            last_at: $t
                        }}
                    else empty end
                ) | add // {})
            )
        }
    ' >"$tmp" 2>/dev/null && mv -f "$tmp" "$learned" 2>/dev/null; then
        local changed_flat="${changed_list//$'\n'/ }"
        echo "reset learned-caps.json for providers: ${changed_flat} (seat-caps.json per-provider change, fleet-ops#3690)"
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    seat_log "aimd: per-provider learned-caps reset FAILED (jq error) — leaving $learned unchanged" 2>/dev/null || true
    return 0
}

# fleet-ops#3690: per-tick per-provider spawn cap. Limits how many NEW
# sessions pick_seat routes to a provider within a single intake tick so a
# fresh fleet (learned-caps reset) does not burst N spawns on one provider
# and trip resource_exhausted (5 devin spawns at once, all rc=143 in <30s).
# The intake tick calls reset_tick_spawn_counts at the start of each tick to
# zero the counter file; pick_seat calls tick_spawn_cap_exceeded before
# routing and tick_spawn_cap_record after a successful pick. A provider
# without tick_spawn_cap in seat-caps.json is unlimited (returns 1 = not
# exceeded). The counter file is $STATE_DIR/tick-spawn-counts.json:
# {"devin": 2, ...}. Tests override via SEAT_TICK_SPAWN_COUNTS_JSON.
SEAT_TICK_SPAWN_COUNTS_JSON="${SEAT_TICK_SPAWN_COUNTS_JSON:-$STATE_DIR/tick-spawn-counts.json}"

# Reset all per-tick spawn counters to 0. Called by the intake tick at the
# start of each tick. Best-effort: a write failure logs and continues (the
# cap degrades to unlimited, never blocks intake).
reset_tick_spawn_counts() {
    local dir
    dir=$(dirname "$SEAT_TICK_SPAWN_COUNTS_JSON" 2>/dev/null || echo "$STATE_DIR")
    mkdir -p "$dir" 2>/dev/null || true
    local tmp="$SEAT_TICK_SPAWN_COUNTS_JSON.tmp.$$.$RANDOM"
    if jq -nc '{}' >"$tmp" 2>/dev/null && mv -f "$tmp" "$SEAT_TICK_SPAWN_COUNTS_JSON" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    seat_log "tick-spawn: reset FAILED at $SEAT_TICK_SPAWN_COUNTS_JSON — cap degrades to unlimited" 2>/dev/null || true
    return 0
}

# Echo the current spawn count for a provider (0 if the file is missing or
# unparseable). Args: provider
_tick_spawn_count() {
    local p="$1"
    [[ -f "$SEAT_TICK_SPAWN_COUNTS_JSON" ]] || { echo 0; return; }
    local n
    n=$(jq -r --arg p "$p" '.[$p] // 0' "$SEAT_TICK_SPAWN_COUNTS_JSON" 2>/dev/null || echo 0)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    echo "$n"
}

# fleet-ops#4723: true (return 0) if another provider still has a usable
# seat this pick could fall through to. The #3690 burst guard stays in
# force whenever a fallback exists; the AIMD ride below is only for the
# sole-usable-provider starve. Does not call pick_seat (re-entrancy).
_tick_spawn_has_other_usable() {
    local skip="$1" p m pcap
    local _SEAT_USABLE_SILENT=1
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    while IFS=$'\t' read -r p m _; do
        [[ -n "$p" && -n "$m" && "$p" != "$skip" ]] || continue
        pcap="${SEAT_PROVIDER_CAP[$p]:-0}"
        [[ "$pcap" =~ ^[0-9]+$ ]] || pcap=0
        (( pcap > 0 )) || continue
        [[ -z "${SEAT_CAP_ZERO_CLASS_INTENTIONAL[$p]:-}" ]] || continue
        if seat_usable "$p" "$m"; then
            return 0
        fi
    done < <(enumerate_seats)
    return 1
}

# fleet-ops#4723: true if watch.log shows this provider dying rc=143 or
# rc=124 in the last 60s. The #3690 burst (5 simultaneous SIGTERM/timeout
# deaths) is the veto: ride AIMD only when those deaths are absent.
_provider_recent_fast_death() {
    local p="$1"
    local f="$LOG_FILE"
    [[ -n "$p" && -f "$f" ]] || return 1
    local now
    now=$(date -u +%s)
    awk -v p="$p" -v now="$now" '
        index($0, p "/") && ($0 ~ /rc=143/ || $0 ~ /rc=124/) {
            ts = $0
            sub(/^\[/, "", ts)
            sub(/\].*/, "", ts)
            cmd = "date -u -d \"" ts "\" +%s"
            cmd | getline s
            close(cmd)
            if (s + 0 > 0 && (now - s) <= 60 && (now - s) >= 0) { found = 1; exit }
        }
        END { exit found ? 0 : 1 }
    ' "$f"
}

# fleet-ops#4723: true if AIMD has actually admitted a raise (last_result
# probe, or learned_cap above the floor/2 ramp seed). A fresh ramp seed at
# floor/2 is NOT a raise — that is the #3690 slow-start and must keep the
# fixed tick_spawn_cap.
_aimd_has_admitted_raise() {
    local p="$1" lr lc declared floor
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    if (( ! _seat_learned_loaded )); then load_learned_caps || true; fi
    lr=""
    if [[ -f "$LEARNED_CAPS_JSON" ]]; then
        lr=$(jq -r --arg p "$p" '.providers[$p].last_result // empty' "$LEARNED_CAPS_JSON" 2>/dev/null || true)
    fi
    [[ "$lr" == "probe" ]] && return 0
    lc="${LEARNED_CAP[$p]:-}"
    declared=$(provider_cap "$p")
    [[ "$declared" =~ ^[0-9]+$ ]] || return 1
    floor=$(( declared / 2 ))
    (( floor < 1 )) && floor=1
    [[ "$lc" =~ ^[0-9]+$ ]] && (( lc > floor )) && return 0
    return 1
}

# fleet-ops#4723: ride the live AIMD ceiling instead of the fixed
# tick_spawn_cap when this is the only usable provider, AIMD has admitted
# a raise, and there is no recent fast death. Must not raise an
# intentional_cap_zero seat and must not drop the burst guard when a
# fallback provider exists (#3690).
_tick_spawn_ride_aimd() {
    local p="$1"
    local cap="${SEAT_TICK_SPAWN_CAP[$p]:-0}"
    [[ "$cap" =~ ^[0-9]+$ ]] || cap=0
    (( cap > 0 )) || return 1
    [[ -z "${SEAT_CAP_ZERO_CLASS_INTENTIONAL[$p]:-}" ]] || return 1
    if _tick_spawn_has_other_usable "$p"; then return 1; fi
    if _provider_recent_fast_death "$p"; then return 1; fi
    if provider_has_recent_error "$p"; then return 1; fi
    _aimd_has_admitted_raise "$p"
}

# Echo the per-tick cap pick_seat honours for this provider. Default is
# tick_spawn_cap from seat-caps.json. When _tick_spawn_ride_aimd holds,
# the live AIMD ceiling (effective_provider_cap) is used if it is higher.
_tick_spawn_effective_cap() {
    local p="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    local cap="${SEAT_TICK_SPAWN_CAP[$p]:-0}"
    [[ "$cap" =~ ^[0-9]+$ ]] || cap=0
    if _tick_spawn_ride_aimd "$p"; then
        local aimd
        aimd=$(effective_provider_cap "$p")
        [[ "$aimd" =~ ^[0-9]+$ ]] || aimd=0
        (( aimd > cap )) && cap=$aimd
    fi
    echo "$cap"
}

# Compact "p/m until=ISO" list of seats whose usable_at or bench_until is
# still in the future. Intake prints this on the #3732 line so the next
# run can judge supply without a 66-file census (fleet-ops#4723).
seat_walled_breakdown() {
    local p m f ua bu wall
    local -a parts=()
    while IFS=$'\t' read -r p m _; do
        [[ -n "$p" && -n "$m" ]] || continue
        f=$(seat_ledger_path "$p" "$m")
        [[ -f "$f" ]] || continue
        IFS=$'\x1f'$'\n' read -r ua bu < <(
            jq -r '[(.usable_at//""),(.bench_until//"")] | join("\u001f")' "$f" 2>/dev/null || true
        )
        wall="$ua"
        [[ -z "$wall" ]] && wall="$bu"
        [[ -n "$wall" ]] && _seat_in_future "$wall" || continue
        parts+=("$p/$m until=$wall")
    done < <(enumerate_seats)
    (( ${#parts[@]} > 0 )) || return 0
    local -a shown=("${parts[@]:0:6}")
    local i
    printf '%s' "${shown[0]}"
    for (( i = 1; i < ${#shown[@]}; i++ )); do
        printf '; %s' "${shown[i]}"
    done
}

# Return 0 (exceeded) if the provider has hit its per-tick spawn cap, 1
# (not exceeded) otherwise. A provider without SEAT_TICK_SPAWN_CAP or with
# cap=0 is unlimited. fleet-ops#4723: the cap is the AIMD ceiling when this
# is the sole usable provider and it is demonstrably healthy. Args: provider
tick_spawn_cap_exceeded() {
    local p="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    local cap
    cap=$(_tick_spawn_effective_cap "$p")
    [[ "$cap" =~ ^[0-9]+$ ]] || cap=0
    (( cap > 0 )) || return 1
    local n
    n=$(_tick_spawn_count "$p")
    (( n >= cap )) && return 0
    return 1
}

# Increment the per-tick spawn counter for a provider after a successful
# pick. Best-effort: a write failure logs and continues. Args: provider
tick_spawn_cap_record() {
    local p="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    local cap="${SEAT_TICK_SPAWN_CAP[$p]:-0}"
    [[ "$cap" =~ ^[0-9]+$ ]] || cap=0
    (( cap > 0 )) || return 0
    local dir
    dir=$(dirname "$SEAT_TICK_SPAWN_COUNTS_JSON" 2>/dev/null || echo "$STATE_DIR")
    mkdir -p "$dir" 2>/dev/null || true
    local tmp="$SEAT_TICK_SPAWN_COUNTS_JSON.tmp.$$.$RANDOM"
    if [[ -f "$SEAT_TICK_SPAWN_COUNTS_JSON" ]] && jq -e . "$SEAT_TICK_SPAWN_COUNTS_JSON" >/dev/null 2>&1; then
        if jq --arg p "$p" '.[$p] = ((.[$p] // 0) + 1)' "$SEAT_TICK_SPAWN_COUNTS_JSON" >"$tmp" 2>/dev/null \
            && mv -f "$tmp" "$SEAT_TICK_SPAWN_COUNTS_JSON" 2>/dev/null; then
            return 0
        fi
    else
        if jq -nc --arg p "$p" '{($p): 1}' >"$tmp" 2>/dev/null \
            && mv -f "$tmp" "$SEAT_TICK_SPAWN_COUNTS_JSON" 2>/dev/null; then
            return 0
        fi
    fi
    rm -f "$tmp" 2>/dev/null || true
    seat_log "tick-spawn: record FAILED for $p — counter not incremented" 2>/dev/null || true
    return 0
}

# Effective cap pick_seat honours. Records backoff on a fresh 429.
# Order: hard_ceiling -> fresh 429 backoff -> bench in effect -> decay ->
# clamp learned to [declared, ceiling]. fleet-ops#3690: a ramp=true entry
# (seeded by install.sh when the provider's cap block changed) bypasses the
# declared floor clamp so the provider starts at floor/2 and climbs +1 per
# probe; graduating to declared clears the flag.
effective_provider_cap() {
    local p="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    if (( ! _seat_learned_loaded )); then load_learned_caps || true; fi
    local declared ceiling
    declared=$(provider_cap "$p")
    if provider_hard_ceiling "$p"; then
        echo "$declared"
        return
    fi
    ceiling=$(max_probe_ceiling "$p")
    local ramp="${LEARNED_RAMP[$p]:-0}"
    if provider_has_recent_error "$p"; then
        local backoff=$(( declared / 2 ))
        (( backoff < 1 )) && backoff=1
        local bench
        bench=$(_provider_bench_until "$p")
        bench=$(_provider_backoff_bench_until "$p" "$bench")
        local cur="${LEARNED_CAP[$p]:-}"
        local cur_bench="${LEARNED_BENCH_UNTIL[$p]:-}"
        if [[ "$cur" != "$backoff" || "$cur_bench" != "$bench" ]]; then
            # Preserve the ramp flag through a backoff: a provider still
            # ramping that hits a 429 backs off but stays in ramp mode so
            # it re-climbs from the backed-off value, not a burst to declared.
            _record_learned_cap "$p" "$backoff" "backoff" "$bench" "$ramp"
        fi
        echo "$backoff"
        return
    fi
    local bench="${LEARNED_BENCH_UNTIL[$p]:-}"
    if [[ -n "$bench" ]] && _seat_in_future "$bench"; then
        local backed="${LEARNED_CAP[$p]:-}"
        [[ "$backed" =~ ^[0-9]+$ ]] || backed="$declared"
        echo "$backed"
        return
    fi
    if [[ -n "$bench" ]] && ! _seat_in_future "$bench"; then
        local cur="${LEARNED_CAP[$p]:-}"
        if [[ "$cur" =~ ^[0-9]+$ ]] && (( cur != declared )); then
            # Bench expired in ramp mode: restart the ramp from floor/2
            # (fleet-ops#3690). In normal mode, decay to declared.
            if [[ "$ramp" == "1" ]]; then
                local restart=$(( declared / 2 ))
                (( restart < 1 )) && restart=1
                _record_learned_cap "$p" "$restart" "ramp" "" 1
                echo "$restart"
            else
                _record_learned_cap "$p" "$declared" "decay" ""
                echo "$declared"
            fi
            return
        elif [[ -n "$cur" ]]; then
            _record_learned_cap "$p" "$declared" "decay" ""
            echo "$declared"
            return
        fi
    fi
    local current="${LEARNED_CAP[$p]:-}"
    if [[ ! "$current" =~ ^[0-9]+$ ]]; then current="$declared"; fi
    local eff=$(( current < ceiling ? current : ceiling ))
    # fleet-ops#3690: only clamp to the declared floor when NOT ramping. A
    # ramp=true entry may sit below declared (floor/2 start) and must not be
    # bumped back to declared — that would defeat the slow start and burst.
    if [[ "$ramp" != "1" ]]; then
        (( eff < declared )) && eff=$declared
    else
        (( eff < 1 )) && eff=1
        # Graduation: once the ramp reaches declared, clear the flag and
        # resume normal AIMD (declared is now the floor again).
        if (( eff >= declared )); then
            _record_learned_cap "$p" "$eff" "decay" "" 0
        fi
    fi
    echo "$eff"
}

# Additive probe admission. Returns 0 (admit one extra) iff ALL of:
# not hard_ceiling, eff < ceiling, active == eff, zero provider errors,
# RAM governor headroom. Records learned_cap=eff+1 result=probe.
# Args: provider eff_cap active_count
_aimd_probe_admitted() {
    local p="$1" eff="$2" active="$3"
    if provider_hard_ceiling "$p"; then return 1; fi
    local ceiling
    ceiling=$(max_probe_ceiling "$p")
    (( eff < ceiling )) || return 1
    (( active == eff )) || return 1
    if provider_has_recent_error "$p"; then return 1; fi
    local ram_cap active_total
    ram_cap=$(ram_governor_cap) || ram_cap=0
    [[ "$ram_cap" =~ ^[0-9]+$ ]] || ram_cap=0
    active_total=$(active_ram_charge)
    # active_ram_charge is fractional (per-repo MemoryHigh / fallback), so
    # compare in awk, not bash integer math (fleet-ops#3679).
    awk -v cap="$ram_cap" -v act="$active_total" 'BEGIN{ exit !(cap > act) }' || return 1
    local new=$(( eff + 1 ))
    (( new > ceiling )) && new=$ceiling
    # fleet-ops#3690: a probe that reaches declared graduates the provider
    # out of ramp mode (clears the flag); below declared, keep ramping.
    local declared
    declared=$(provider_cap "$p")
    if [[ "${LEARNED_RAMP[$p]:-0}" == "1" ]] && (( new >= declared )); then
        _record_learned_cap "$p" "$new" "probe" "" 0
    else
        _record_learned_cap "$p" "$new" "probe" ""
    fi
    return 0
}

# --- Model-granularity AIMD (fleet-ops#3125) --------------------------------
# Same contract as the provider-level AIMD above, keyed on "provider/model".
# A model row that carries max_probe_ceiling (e.g. devin glm-5-2 declared 3 /
# probe to 6) may probe above its declared model cap; a model row without one
# keeps the declared cap as a hard ceiling (the pre-#3125 behaviour for every
# seat). Learned state is recorded under the "p/m" key in learned-caps.json —
# the providers map keys are opaque strings, so a "devin/glm-5-2" key sits
# next to "devin" without collision. install.sh resets learned-caps.json when
# a deploy changes seat-caps.json so a stale learned cap never pins a raised
# declared floor.
#
# effective_model_cap <p> <m> -> echoes the model cap pick_seat honours.
# Order: no ceiling declared -> declared; provider hard_ceiling -> declared;
# fresh provider error -> backoff (declared/2, floor 1); bench held ->
# learned; bench expired -> decay to declared; else learned clamped to
# [declared, ceiling].
effective_model_cap() {
    local p="$1" m="$2"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    if (( ! _seat_learned_loaded )); then load_learned_caps || true; fi
    local declared ceiling
    declared=$(model_cap "$p" "$m")
    ceiling="${SEAT_MODEL_PROBE_CEILING[$p/$m]:-}"
    # No declared model probe ceiling (or one at/below the declared cap)
    # means the declared model cap is the binding value exactly as before.
    if [[ ! "$ceiling" =~ ^[0-9]+$ ]] || (( ceiling <= declared )); then
        echo "$declared"
        return
    fi
    if provider_hard_ceiling "$p"; then
        echo "$declared"
        return
    fi
    local key="$p/$m"
    if provider_has_recent_error "$p"; then
        local backoff=$(( declared / 2 ))
        (( backoff < 1 )) && backoff=1
        local bench
        bench=$(_provider_bench_until "$p")
        bench=$(_provider_backoff_bench_until "$p" "$bench")
        local cur="${LEARNED_CAP[$key]:-}"
        local cur_bench="${LEARNED_BENCH_UNTIL[$key]:-}"
        if [[ "$cur" != "$backoff" || "$cur_bench" != "$bench" ]]; then
            _record_learned_cap "$key" "$backoff" "backoff" "$bench"
        fi
        echo "$backoff"
        return
    fi
    local bench="${LEARNED_BENCH_UNTIL[$key]:-}"
    if [[ -n "$bench" ]] && _seat_in_future "$bench"; then
        local backed="${LEARNED_CAP[$key]:-}"
        [[ "$backed" =~ ^[0-9]+$ ]] || backed="$declared"
        echo "$backed"
        return
    fi
    if [[ -n "$bench" ]] && ! _seat_in_future "$bench"; then
        _record_learned_cap "$key" "$declared" "decay" ""
        echo "$declared"
        return
    fi
    local current="${LEARNED_CAP[$key]:-}"
    if [[ ! "$current" =~ ^[0-9]+$ ]]; then current="$declared"; fi
    local eff=$(( current < ceiling ? current : ceiling ))
    (( eff < declared )) && eff=$declared
    echo "$eff"
}

# Model-level probe admission. Returns 0 (admit one extra on this seat) iff
# ALL of: provider not hard_ceiling, the model row declares a probe ceiling,
# eff < ceiling, active == eff, zero provider errors, RAM governor headroom.
# Records learned_cap=eff+1 under the "p/m" key with result=probe.
# Args: provider model eff_cap active_count
_model_probe_admitted() {
    local p="$1" m="$2" eff="$3" active="$4"
    if provider_hard_ceiling "$p"; then return 1; fi
    local ceiling="${SEAT_MODEL_PROBE_CEILING[$p/$m]:-}"
    [[ "$ceiling" =~ ^[0-9]+$ ]] || return 1
    (( eff < ceiling )) || return 1
    (( active == eff )) || return 1
    if provider_has_recent_error "$p"; then return 1; fi
    local ram_cap active_total
    ram_cap=$(ram_governor_cap) || ram_cap=0
    [[ "$ram_cap" =~ ^[0-9]+$ ]] || ram_cap=0
    active_total=$(active_ram_charge)
    # active_ram_charge is fractional (per-repo MemoryHigh / fallback), so
    # compare in awk, not bash integer math (fleet-ops#3679).
    awk -v cap="$ram_cap" -v act="$active_total" 'BEGIN{ exit !(cap > act) }' || return 1
    local new=$(( eff + 1 ))
    (( new > ceiling )) && new=$ceiling
    _record_learned_cap "$p/$m" "$new" "probe" ""
    return 0
}

# RAM governor: max concurrent workers = floor(MemAvailable_GB / RAM_PER_WORKER).
# If /proc/meminfo can't be read, returns 9999 (effectively unbounded) and logs.
# If a unit slip makes the computed cap >= 64, the function logs and returns 1
# so callers cannot silently dispatch to a five-digit lane count.
ram_governor_cap() {
    # Lazy-load the cap map FIRST. Without this, SEAT_RAM_GB_PER_WORKER keeps
    # its hardcoded 1.5 default and ram_gb_per_worker in seat-caps.json is
    # silently ignored - every other consumer (provider_cap, model_cap,
    # class_of, pick_seat) does this and ram_governor_cap did not, so the RAM
    # governor was the ONE function that never read its own config. Measured
    # 2026-08-26: reported 5 lanes on the 1.5 default where the configured
    # 0.75 gives 10. Half the fleet's capacity was invisible.
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    local mem_avail_kb ram_budget
    mem_avail_kb=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)
    if (( mem_avail_kb <= 0 )); then
        seat_log "ram_governor: /proc/meminfo unavailable — returning 9999 (unbounded)"
        echo 9999
        return
    fi
    # floor(MemAvailable_GB / per_worker). per_worker may be a decimal, so do
    # the division in awk — bash integer math can't, and `${x%.*}` turns "1.5"
    # into "1", inflating the cap ~1.5x.
    # Launch FLOOR, restored from the pre-2026-08-23 lane-manager design
    # (MIN_FREE_RAM_MB = 2500): reserve headroom for the rest of the host
    # FIRST, then divide what is genuinely spare. Keep every conversion step
    # explicit (kB->GB, MB->GB, GB/per) so an MB/GB slip fails the sanity
    # check instead of silently emitting a five-digit lane count.
    local floor_mb=${SEAT_MIN_FREE_RAM_MB:-2500}
    ram_budget=$(awk -v mem_kb="$mem_avail_kb" -v per="$SEAT_RAM_GB_PER_WORKER" -v floor_mb="$floor_mb" 'BEGIN {
        if (per + 0 <= 0) per = 1.5
        # Explicit unit conversions: all quantities in GB before the final division.
        mem_gb   = mem_kb / 1024 / 1024
        floor_gb = floor_mb / 1024
        spare = mem_gb - floor_gb
        if (spare < 0) spare = 0
        r = int(spare / per)
        if (r < 1) r = 1
        print r
    }')
    if [[ ! "$ram_budget" =~ ^[0-9]+$ ]]; then
        seat_log "ram_governor: computed non-numeric cap '$ram_budget' — failing loud"
        return 1
    fi
    if (( ram_budget >= 64 )); then
        seat_log "ram_governor: sanity fail — computed cap $ram_budget >= 64 (MB/GB unit slip?); failing loud"
        return 1
    fi
    echo "$ram_budget"
}

# Effective fleet ceiling = min(sum_of_provider_caps, ram_governor).
seat_max_concurrent() {
    local caps_sum ram_cap
    caps_sum=$(total_seat_cap)
    ram_cap=$(ram_governor_cap)
    if (( caps_sum <= 0 )); then
        echo "$ram_cap"
    else
        echo $(( caps_sum < ram_cap ? caps_sum : ram_cap ))
    fi
}

# fleet-ops#1558: light-workload target concurrent (defaults 25). Loaded from
# seat-caps.json target_concurrent; callers that have not load_seat_caps yet
# get the default.
target_concurrent() {
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    echo "${SEAT_TARGET_CONCURRENT:-25}"
}

# Admit ceiling = min(target_concurrent, ram_governor_cap). Undersaturation
# floor and "25 when supply exists" semantics use this, not a hard 25 — so a
# browser-heavy mix that drops MemAvailable does not page as a fault.
admit_ceiling() {
    local tgt ram_cap
    tgt=$(target_concurrent)
    ram_cap=$(ram_governor_cap) || ram_cap=0
    if (( ram_cap <= 0 )); then
        echo "$tgt"
    elif (( tgt < ram_cap )); then
        echo "$tgt"
    else
        echo "$ram_cap"
    fi
}

# Convert a systemd memory quantity (1536M, 1G, 1.25G, 2G) to GB (decimal).
# Prints 0 if the string is not a plain <number><K|M|G> quantity.
_systemd_quantity_gb() {
    local q="$1" num unit
    [[ "$q" =~ ^([0-9]+(\.[0-9]+)?)([KMG])$ ]] || { echo 0; return; }
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[3]}"
    case "$unit" in
        K) awk -v n="$num" 'BEGIN{ printf "%.3f", n/1024/1024 }' ;;
        M) awk -v n="$num" 'BEGIN{ printf "%.3f", n/1024 }' ;;
        G) awk -v n="$num" 'BEGIN{ printf "%.3f", n }' ;;
    esac
}

# Per-repo RAM charge in GB for a worker of <repo> at <difficulty>.
# heavy|keystone -> 1.0 GB (fleet-ops#3495). Else the repo's MemoryHigh
# from worker_memory.<repo> (0509/fleet-ops no longer set MemoryHigh after
# fleet-ops#3930 dropped the throttle band, so they fall back to 1.0), converted
# to GB. Repos without a row fall back to ram_gb_per_worker (1.0, fleet-ops#4164).
# This is what admission charges each active worker, so a browser worker
# consumes its real share of MemAvailable instead of the flat 1.0 GB.
ram_charge_gb_for() {
    local repo="$1" difficulty="$2" high gb
    if [[ "$difficulty" == "heavy" || "$difficulty" == "keystone" ]]; then
        echo "1.0"
        return
    fi
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    high=$(jq -r --arg r "$repo" '.worker_memory[$r].MemoryHigh // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    if [[ -n "$high" ]]; then
        gb=$(_systemd_quantity_gb "$high")
        if awk -v g="$gb" 'BEGIN{ exit !(g > 0) }'; then
            echo "$gb"
            return
        fi
    fi
    echo "$SEAT_RAM_GB_PER_WORKER"
}

# Per-repo MemoryMax/MemoryHigh from seat-caps.json worker_memory.<repo>.
# Prints "MemoryMax\tMemoryHigh" or empty if the repo has no row (caller keeps
# the template defaults). systemd quantity strings pass through unchanged.
worker_memory_for_repo() {
    local repo="$1" max high
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    [[ -f "$SEAT_CAPS_JSON" ]] || return 0
    max=$(jq -r --arg r "$repo" '.worker_memory[$r].MemoryMax // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    high=$(jq -r --arg r "$repo" '.worker_memory[$r].MemoryHigh // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    [[ -n "$max" || -n "$high" ]] || return 0
    printf '%s\t%s\n' "$max" "$high"
}

# Per-difficulty MemoryMax/MemoryHigh from seat-caps.json worker_memory.
# heavy|keystone -> the "heavy" class (MemoryMax=3G/MemoryHigh=2G, fleet-ops#3281)
# so a manager worker running 8 parallel scouts + 1 implementer is bounded;
# any other difficulty falls back to worker_memory_for_repo. Prints
# "MemoryMax\tMemoryHigh" or empty (caller keeps the template defaults).
worker_memory_for_difficulty() {
    local repo="$1" difficulty="$2" max high
    if [[ "$difficulty" == "heavy" || "$difficulty" == "keystone" ]]; then
        if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
        [[ -f "$SEAT_CAPS_JSON" ]] || return 0
        max=$(jq -r '.worker_memory["heavy"].MemoryMax // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
        high=$(jq -r '.worker_memory["heavy"].MemoryHigh // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
        [[ -n "$max" || -n "$high" ]] || return 0
        printf '%s\t%s\n' "$max" "$high"
        return
    fi
    worker_memory_for_repo "$repo"
}

# Per-repo Environment variables from seat-caps.json worker_env.<repo>.
# Prints "KEY=VALUE" lines (one per env var) or nothing if the repo has no row.
# Caller writes these into a systemd drop-in Environment file.
worker_env_for_repo() {
    local repo="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    [[ -f "$SEAT_CAPS_JSON" ]] || return 0
    jq -r --arg r "$repo" '.worker_env[$r] // empty | to_entries[] | "\(.key)=\(.value)"' "$SEAT_CAPS_JSON" 2>/dev/null || true
}

# --- seat enumeration from models.json (never hardcode) ----------------------
# Emit lines: <provider>\t<model>\t<free:1|0>\t<capable:1|0>
# A seat is "capable" (safe for a heavy code-editing packet) iff ANY of:
#   - the model has reasoning=true
#   - contextWindow >= 200000 AND the provider is NOT cursor
#   - the provider is one of the known flagship lanes (devin, opencode-anthropic)
#     whose cheapest seat is already a real coder
#
# cursor is NOT in the capable whitelist (2026-08-25): cursor flakes on long
# jobs (spawnSync ETIMEDOUT, and cursor-grok-4.6-high itself exits 143 on
# heavy 14-minute packets — fleet-ops-239 2026-08-26). It still works fine
# for short probes, so heavy-task routing skips cursor — devin/cline carry
# the heavy load and cursor only fills in when the task is light and the
# higher-priority seats are full. The contextWindow branch now explicitly
# excludes cursor so cursor-grok-4.6-high is never picked for heavy code.
# OVERRULED for grok-4.6-high only (Nish, 2026-08-27: "grok 4.6 on cursor is
# solid tbh"): cursor-grok-4.6-high is re-admitted to the heavy-capable class;
# composer and every other cursor model stay light-only. Flake mitigation for
# the ETIMEDOUT/143 class stays with the reap/retry machinery, not exclusion.
#
# Filtering rules:
#   - zenmux is hard-skipped (free tier exhausted; standing constraint).
#   - Per-cap-map allowlist is applied in pick_seat (not here), because
#     bash associative-array lookups are the source of truth and a stray
#     awk env-var marshalling step would be brittle. enumerate_seats emits
#     the WHOLE model list from models.json; pick_seat filters against the
#     loaded cap map.
enumerate_seats() {
    jq -r '
      .providers | to_entries[] | .key as $p |
      (
        (.value.models // [])[] |
        [ $p, .id,
          (if ((.cost.input // 1) == 0) then "1" else "0" end),
          (if ( ((.reasoning // false) == true)
                or (((.contextWindow // 0) >= 200000) and (($p != "cursor") or (.id == "cursor-grok-4.6-high")))
                or ($p | IN("devin","opencode-anthropic")) )
           then "1" else "0" end)
        ]
      ),
      (
        (.value.modelOverrides // {}) | to_entries[] |
        [ $p, .key, "0",
          (if ( ((.value.reasoning // false) == true)
                or (((.value.contextWindow // 0) >= 200000) and (($p != "cursor") or (.key == "cursor-grok-4.6-high")))
                or ($p | IN("devin","opencode-anthropic")) )
           then "1" else "0" end)
        ]
      )
      | @tsv
    ' "$MODELS_JSON" 2>/dev/null || true
}

# Crude, explainable task weight. "heavy" means the packet is likely to edit
# substantial code and needs a capable seat; "light" is a small probe/answer.
# Heavy iff the packet is large (>HEAVY_PKT_BYTES) OR its text asks to
# edit/refactor/fix/rewrite a file. Returns "heavy" or "light" on stdout.
task_weight() {
    local pkt="$1" sz
    if [[ ! -f "$pkt" ]]; then
        echo "light"; return
    fi
    sz=$(wc -c < "$pkt" 2>/dev/null || echo 0)
    sz=${sz//[^0-9]/}; sz=${sz:-0}
    # fleet-ops#3238 (2026-09-05): the packet carries the whole worker prompt
    # (~32 KB); subtract it so the fallback measures the issue-specific part.
    local base="${PI_PACKET_BASE_PROMPT:-$HOME/.pi/agent/prompts/worker.md}" bsz=0
    if [[ -f "$base" ]]; then bsz=$(wc -c < "$base" 2>/dev/null || echo 0); bsz=${bsz//[^0-9]/}; fi
    (( sz > ${bsz:-0} )) && sz=$((sz - bsz))
    if (( sz > HEAVY_PKT_BYTES )); then
        echo "heavy"; return
    fi
    if grep -qiE '(edit|refactor|rewrite|fix|implement|modify|update|patch)[[:space:]]+.*(file|\.py|\.sh|\.ts|\.tsx|\.js|\.jsx|\.go|\.rs|\.rb|/home/|src/|lib/)' "$pkt" 2>/dev/null; then
        echo "heavy"; return
    fi
    echo "light"
}

# fleet-ops#1133: explicit difficulty marker on a packet. Scans the packet
# for a manifest line:
#   difficulty: keystone|senior-review|heavy|light
#   keystone: true
#   senior-review: true
# First match wins. Falls back to task_weight() when no marker is present.
# Missing file -> light.
packet_difficulty() {
    local pkt="$1" line lowered
    if [[ ! -f "$pkt" ]]; then
        echo "light"
        return
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        lowered="${line,,}"
        if [[ "$lowered" =~ ^difficulty:[[:space:]]*(keystone|senior-review|heavy|light)[[:space:]]*$ ]]; then
            echo "${BASH_REMATCH[1]}"
            return
        fi
        if [[ "$lowered" =~ ^keystone:[[:space:]]*(true|yes|1)[[:space:]]*$ ]]; then
            echo "keystone"
            return
        fi
        if [[ "$lowered" =~ ^senior-review:[[:space:]]*(true|yes|1)[[:space:]]*$ ]]; then
            echo "senior-review"
            return
        fi
    done < "$pkt"
    task_weight "$pkt"
}

# fleet-ops#1167: keystone and senior-review share the cursor gate and
# reliability-first walk. Volume packets do not.
_is_keystone_class() {
    [[ "${1:-}" == "keystone" || "${1:-}" == "senior-review" ]]
}

# fleet-ops#1167: cursor is keystone-only even if the config list is omitted.
# fleet-ops#3121: keystone_only_providers config key deleted; the hardcoded
# cursor check is the sole gate (one mechanism, not two).
_provider_is_keystone_only() {
    local p="$1"
    [[ "$p" == "cursor" ]] && return 0
    return 1
}

# fleet-ops#3121: resolve the senior (judge/orchestrator/reviewer) role seat.
# Returns the FIRST usable seat from senior_seats_in_order (priority order);
# a walled seat is skipped, never a unit failure. If the whole ladder is
# walled, falls through to any usable capable seat (the "walled role resolves
# to its fallback" rule). Fail-closed: prints nothing and returns 1 only when
# NO seat anywhere is usable in this moment — callers treat that as a lane
# fault (exit 0, no vote, retry next tick), not a crash.
#
# Prints "provider<TAB>model" on stdout. Re-entrant safe: this is a plain
# read of the already-loaded SEAT_SENIOR_ORDER; load_seat_caps must have run
# (pick_seat / callers force-load it).
find_senior_seat() {
    local sn p m _tk
    for sn in "${SEAT_SENIOR_ORDER[@]}"; do
        [[ -n "$sn" ]] || continue
        p="${sn%%/*}"
        m="${sn#*/}"
        [[ -n "$p" && -n "$m" ]] || continue
        [[ "$(model_cap "$p" "$m" 2>/dev/null || echo 0)" -gt 0 ]] 2>/dev/null || continue
        # fleet-ops#4220: respect pick_seat's per-cycle tried map so a
        # Restart= cycle walks past a seat that already failed this cycle.
        # Standalone callers have no assoc `tried`. An unset or scalar
        # `tried` is NOT associative, so `$p/$m` would be arithmetic
        # (`cursor` unbound under `set -u`). Honor the map only when it
        # is actually `declare -A`.
        if [[ "$(declare -p tried 2>/dev/null || true)" == *"declare -A"* ]]; then
            _tk="$p/$m"
            [[ -n "${tried[$_tk]:-}" ]] && continue
        fi
        # fleet-ops#3121: cursor weekly ceiling. When cursor's prepaid-usage
        # count for the week hits SEAT_SENIOR_CURSOR_CEILING, skip cursor and
        # fall through to the next seat in the ladder (xai-oauth/grok-4.6).
        if [[ "$p" == "cursor" && "${SEAT_SENIOR_CURSOR_CEILING:-0}" -gt 0 ]]; then
            local _cu
            _cu=$(_prepaid_usage cursor 2>/dev/null || echo 0)
            if [[ "$_cu" -ge "${SEAT_SENIOR_CURSOR_CEILING}" ]]; then
                seat_log "find_senior_seat: cursor weekly usage $_cu >= ceiling $SEAT_SENIOR_CURSOR_CEILING; skipping to next senior seat"
                continue
            fi
        fi
        seat_usable "$p" "$m" 2>/dev/null || continue
        printf '%s\t%s\n' "$p" "$m"
        return 0
    done
    # Whole senior ladder walled — fall through to any usable capable seat.
    seat_log "find_senior_seat: senior ladder exhausted/walled; falling through to any capable seat"
    local ep em ec
    while IFS=$'\t' read -r ep em _ ec; do
        [[ -n "$ep" && -n "$em" ]] || continue
        [[ "$ec" == "1" ]] || continue
        seat_usable "$ep" "$em" 2>/dev/null || continue
        printf '%s\t%s\n' "$ep" "$em"
        return 0
    done < <(enumerate_seats)
    return 1
}

# fleet-ops#3709: is ANY entry of senior_seats_in_order usable right now?
# Returns 0 when at least one senior seat is usable, 1 when the whole
# senior ladder is walled. This is the reviewer-round fallback gate: when
# no senior seat is usable, the worker opens the product PR WITHOUT the
# auto-merge arm and marks the body `review: skipped, no capable seat` so
# the loose-ends surface it. Unlike find_senior_seat, this does
# NOT fall through to a non-senior capable seat — the reviewer must run on
# a senior seat or not at all (never armed unreviewed, never skipped
# silently). Re-entrant safe: a plain read of the already-loaded
# SEAT_SENIOR_ORDER; load_seat_caps must have run.
senior_seat_available() {
    local sn p m
    for sn in "${SEAT_SENIOR_ORDER[@]}"; do
        [[ -n "$sn" ]] || continue
        p="${sn%%/*}"
        m="${sn#*/}"
        [[ -n "$p" && -n "$m" ]] || continue
        [[ "$(model_cap "$p" "$m" 2>/dev/null || echo 0)" -gt 0 ]] 2>/dev/null || continue
        seat_usable "$p" "$m" 2>/dev/null && return 0
    done
    return 1
}

# fleet-ops#1133: JSONL ledger the metrics exporter heartbeats on.
# Fail-open: a write error must never brick pick_seat.
keystone_record_event() {
    local event="${1:-}" p="${2:-}" m="${3:-}"
    local ledger="${KEYSTONE_LEDGER:-$STATE_DIR/keystone-routing.jsonl}"
    event="${event//[^A-Za-z0-9._-]/}"
    p="${p//[^A-Za-z0-9._/-]/}"
    m="${m//[^A-Za-z0-9._/-]/}"
    mkdir -p "$(dirname "$ledger")" 2>/dev/null || return 0
    printf '{"ts":"%s","event":"%s","provider":"%s","model":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$p" "$m" >>"$ledger" 2>/dev/null || true
}

# fleet-ops#1167: every pick is a 24h selection event. Fail-open.
# Also refreshes fleet_seat_selection_24h{provider=} via the node_exporter
# textfile collector (same pattern as pi-packet-verdict writing fleet-verdict.prom).
# Args: provider model difficulty
# Fail-open: a write error must never brick pick_seat.
record_seat_selection() {
    local p="${1:-}" m="${2:-}" difficulty="${3:-light}"
    local ledger="${SEAT_SELECTION_LEDGER:-$STATE_DIR/seat-selection.jsonl}"
    p="${p//[^A-Za-z0-9._/-]/}"
    m="${m//[^A-Za-z0-9._/-]/}"
    difficulty="${difficulty//[^A-Za-z0-9._-]/}"
    mkdir -p "$(dirname "$ledger")" 2>/dev/null || return 0
    printf '{"ts":"%s","provider":"%s","model":"%s","difficulty":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$p" "$m" "$difficulty" >>"$ledger" 2>/dev/null || true
    export_seat_selection_prom
}

# Rewrite fleet_seat_selection_24h{provider=} from the JSONL ledger.
# Fail-open: a missing dir or jq failure must never brick pick_seat.
# Default file is under STATE_DIR so tests cannot poison the live
# node_exporter dir. Production also copies there when that dir is writable
# (same collector fleet-verdict.prom already uses).
export_seat_selection_prom() {
    local ledger="${SEAT_SELECTION_LEDGER:-$STATE_DIR/seat-selection.jsonl}"
    local out="${SEAT_SELECTION_PROM:-$STATE_DIR/fleet-seat-selection.prom}"
    local cutoff tmp dir pub
    dir=$(dirname "$out")
    mkdir -p "$dir" 2>/dev/null || return 0
    cutoff=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")
    tmp="$out.$$.$RANDOM.tmp"
    {
        echo "# HELP fleet_seat_selection_24h pick_seat choices in the trailing 24h by provider (fleet-ops#1167)."
        echo "# TYPE fleet_seat_selection_24h gauge"
        if [[ -f "$ledger" ]]; then
            jq -r --arg c "$cutoff" 'select(.ts >= $c) | .provider // empty' "$ledger" 2>/dev/null \
              | awk 'NF {c[$0]++} END {for (p in c) printf "fleet_seat_selection_24h{provider=\"%s\"} %d\n", p, c[p]}'
        fi
    } >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    mv "$tmp" "$out" 2>/dev/null || { rm -f "$tmp"; return 0; }
    if [[ -z "${SEAT_SELECTION_PROM:-}" && "$STATE_DIR" == "${HOME}/.local/state/pi-packet" ]]; then
        pub="/var/lib/prometheus/node-exporter/fleet-seat-selection.prom"
        if [[ -d "$(dirname "$pub")" && -w "$(dirname "$pub")" ]]; then
            cp "$out" "$pub" 2>/dev/null || true
        fi
    fi
}

# fleet-ops#3661: reject a provider/model pair that is not a real seat in
# seat-caps.json (providers.<p>.models.<m>). A phantom key (e.g. a probe
# output filename fragment like "swe-1-7-.out") must never be written to
# the ledger, probed, or dispatched. Returns 0 when the pair is a real
# seat (or the caps file is missing — fail-open so a missing caps file
# never bricks the ladder); 1 when the pair is not in the caps map.
#
# fleet-ops#4018: a model whose id carries a `\.out` suffix is a probe-output
# filename fragment, NEVER a real seat model. It is rejected BEFORE the
# caps-missing fail-open: a phantom model read back from pi-seat-health.json
# / a stray ledger would otherwise pass the fail-open and be re-dispatched,
# so the seat-health extension re-writes the phantom `<model>-.out.json`
# ledger and splits the reactive bench off the real ledger (self-
# perpetuation: live devin__glm-5-2-.out.json / xai-oauth__grok-4-6-.out.json).
_seat_key_in_caps() {
    local p="$1" m="$2"
    # Never a real model id — reject regardless of the caps fail-open.
    [[ "$m" != *.out ]] || return 1
    [[ -f "$SEAT_CAPS_JSON" ]] || return 0
    jq -e --arg p "$p" --arg m "$m" \
        '.providers[$p].models[$m] != null' "$SEAT_CAPS_JSON" >/dev/null 2>&1
}

# fleet-ops#3661: LOUD reject a phantom seat key. Logs the SEAT-KEY-INVALID
# line naming the writer and returns 1 (so the caller skips the write /
# probe / dispatch). The writer field is the calling function name so the
# next phantom names its author.
_seat_key_guard() {
    local p="$1" m="$2" writer="$3"
    if _seat_key_in_caps "$p" "$m"; then
        return 0
    fi
    seat_log "LOUD SEAT-KEY-INVALID $p/$m writer=$writer"
    return 1
}

# Mirror of seat-health.ts seatLedgerPath: sanitise provider/model so model
# ids containing '/' (e.g. deepseek/deepseek-v4.1-flash) survive on disk.
seat_ledger_path() {
    local p="$1" m="$2" ps ms
    ps="${p//[^A-Za-z0-9._-]/_}"
    ms="${m//[^A-Za-z0-9._-]/_}"
    printf '%s/%s__%s.json\n' "$LEDGER_DIR" "$ps" "$ms"
}

# fleet-ops#3723: OpenRouter's free-model request budget is per ACCOUNT, not
# per key (openrouter.ai/docs/api-reference/limits: "Making additional accounts
# or API keys will not affect your rate limits, as we govern capacity globally").
# The documented daily cap (50 req/day with < $10 credits, 1000 with >= $10) is
# shared across every *:free model on the provider. seat-lib counts assistant
# turns (each turn = one model request) across the provider's *:free sessions
# today (UTC) and benches every free model on the provider once the shared
# counter hits the configured budget, until 00:00 UTC. The bench is NOT charged
# to the work item: no consecutive_failure_count increment, no yield penalty
# (it is an account-wide external limit, not a seat fault). Reuses the existing
# quota_bench/usable_at ledger fields; no new state file.
#
# Pi session files live under $FLEET_SESSIONS_DIR (default ~/.pi/agent/sessions)
# as pi-issue-*/<timestamp>_<id>.jsonl. Each assistant message in a session =
# one model request. A session's provider/model is the first model_change event.
# We count only sessions whose model id ends in ":free" on the given provider
# and whose session timestamp is in the current UTC day.
#
# Args: provider
# Prints: integer request count for today (UTC). 0 on any error (fail-open).
_provider_free_daily_request_count() {
    local p="$1"
    local sessions_dir="${FLEET_SESSIONS_DIR:-$HOME/.pi/agent/sessions}"
    [[ -d "$sessions_dir" ]] || { printf '0'; return 0; }
    # Today's UTC date prefix (YYYY-MM-DD). Session timestamps are ISO 8601 UTC
    # like 2026-09-06T05:11:27.532Z, so a prefix match on the filename's date
    # is exact and cheap (no per-line parse for the date).
    local today
    today=$(date -u +%Y-%m-%d)
    [[ -n "$today" ]] || { printf '0'; return 0; }
    # Count assistant messages across every pi-issue session file whose name
    # starts with today's UTC date. We grep for the provider in model_change
    # and the :free suffix on the modelId to decide whether the session counts,
    # then count "role":"assistant" lines in it. A single jq pass per file
    # would be cleaner but ~hundreds of files per day makes a streaming grep
    # far cheaper; the assistant-role line is structurally unique per turn.
    local count=0
    local f provider model has_free=0
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        has_free=0
        # First model_change with this provider and a :free model id marks the
        # session as counting. A session is single-provider (pi pins one model),
        # so the first match is authoritative.
        while IFS= read -r line; do
            [[ "$line" == *'"type":"model_change"'* || "$line" == *'"type": "model_change"'* ]] || continue
            provider=$(printf '%s' "$line" | jq -r '.provider // ""' 2>/dev/null || true)
            model=$(printf '%s' "$line" | jq -r '.modelId // ""' 2>/dev/null || true)
            if [[ "$provider" == "$p" && "$model" == *":free" ]]; then
                has_free=1
                break
            fi
        done < "$f" 2>/dev/null || continue
        (( has_free )) || continue
        # Count assistant turns in this session. Each assistant message = one
        # request to the model. grep -c is a fast byte scan; the role field is
        # structurally unique per assistant turn.
        local n
        n=$(grep -c '"role":"assistant"' "$f" 2>/dev/null || true)
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        count=$((count + n))
    done < <(find "$sessions_dir" -maxdepth 2 -type f -name "${today}T*.jsonl" 2>/dev/null || true)
    printf '%s' "$count"
}

# fleet-ops#3723: bench every free model on a provider for the rest of the
# UTC day when the shared daily request counter hits the configured budget.
# Writes a quota_bench ledger entry (reuses the existing fields — no new
# state file) with bench_until = next 00:00 UTC. NOT charged to the work
# item: consecutive_failure_count stays at 0 and no yield penalty is applied
# (the bench writer for daily-budget is separate from mark_seat_quota_bench,
# which escalates the count). Best-effort: a write failure fails open (the
# counter re-evaluates next pick).
# Args: provider model
_mark_seat_free_daily_budget_bench() {
    local p="$1" m="$2"
    local path now_utc now_s midnight_s bench_until
    path=$(seat_ledger_path "$p" "$m")
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true
    now_s=$(date -u +%s)
    now_utc=$(date -u -d "@$now_s" +%Y-%m-%dT%H:%M:%SZ)
    # Next 00:00 UTC. If we are exactly at midnight, bench for the full day
    # (the counter just rolled, so this is defensive; the next pick re-counts).
    midnight_s=$(date -u -d "$(date -u -d "@$now_s" +%Y-%m-%d) tomorrow" +%s 2>/dev/null || echo $((now_s + 86400)))
    (( midnight_s <= now_s )) && midnight_s=$((now_s + 86400))
    bench_until=$(date -u -d "@$midnight_s" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")
    local tmp="$path.bench.$$.$RANDOM.tmp"
    # consecutive_failure_count is 0 — this is an account-wide external limit,
    # not a seat fault, so it must NOT escalate the bench or trip the failure
    # ceiling. The ledger's quota_bench branch in seat_usable holds the seat
    # until bench_until; once midnight passes the bench expires (fail-open) and
    # the counter restarts at 0 for the new UTC day.
    if jq -nc \
        --arg provider "$p" --arg model "$m" \
        --arg observed "$now_utc" --arg bench "$bench_until" --arg usable "$bench_until" \
        --argjson http_status 429 --argjson retry_after null \
        --argjson retryable true --argjson seat_dead false --argjson poison_ladder false \
        --argjson count 0 \
        '{
          provider:$provider, model:$model,
          http_status:$http_status, retry_after:$retry_after,
          health_class:"quota_bench",
          retryable:$retryable, seat_dead:$seat_dead, poison_ladder:$poison_ladder,
          observed_at:$observed,
          source:"free_daily_budget",
          failure_mode:"quota_cap",
          bench_until:$bench,
          usable_at:$usable,
          consecutive_failure_count:$count
        }' > "$tmp" 2>/dev/null; then
        chmod 0644 "$tmp" 2>/dev/null || true
        if mv "$tmp" "$path" 2>/dev/null; then
            seat_log "free-daily-budget: benched $p/$m until $bench_until (account-wide free-model daily cap reached; not charged to work item — fleet-ops#3723)"
            return 0
        fi
        rm -f "$tmp" 2>/dev/null || true
        seat_log "free-daily-budget: ledger rename FAILED for $p/$m — fail-open (counter re-evaluates next pick)"
        return 1
    fi
    rm -f "$tmp" 2>/dev/null || true
    seat_log "free-daily-budget: jq compose FAILED for $p/$m — marker NOT written"
    return 1
}

# fleet-ops#3723: true if the provider has a free-model daily request budget
# configured AND the shared counter of assistant turns across the provider's
# *:free sessions today (UTC) has reached it. When true, the caller benches
# every free model on the provider for the rest of the UTC day. Caches the
# count per pick (one scan per provider per pick_seat call).
# Args: provider
# Returns: 0 if budget reached (bench), 1 otherwise
_provider_free_daily_budget_reached() {
    local p="$1"
    local budget="${SEAT_FREE_DAILY_REQUEST_BUDGET[$p]:-0}"
    [[ "$budget" =~ ^[0-9]+$ ]] || return 1
    (( budget > 0 )) || return 1
    # Per-pick cache so the candidate loop does not re-scan sessions per model.
    local cache_key="_FRDB_COUNT_$p"
    local count="${!cache_key:-}"
    if [[ -z "$count" ]]; then
        count=$(_provider_free_daily_request_count "$p")
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
        printf -v "$cache_key" '%s' "$count"
    fi
    (( count >= budget ))
}

# fleet-ops#3724: today's (UTC) spend in USD on one seat, measured from Pi
# session usage.cost — the same field the fleet-ops#3283 fleet_seat_spend_usd
# export aggregates. We scan session jsonl files that can carry today's spend
# (named today OR modified today — a session started before midnight keeps
# appending after it, so the filename prefix alone would miss it), keep the
# sessions pinned to this seat (first model_change provider+modelId match),
# and sum message.usage.cost.total on messages timestamped today.
#
# Args: provider model
# Prints: today's spend in USD (float). 0 on any error (fail-open).
_seat_daily_spend_usd() {
    local p="$1" m="$2"
    local sessions_dir="${FLEET_SESSIONS_DIR:-$HOME/.pi/agent/sessions}"
    [[ -d "$sessions_dir" ]] || { printf '0'; return 0; }
    command -v jq >/dev/null 2>&1 || { printf '0'; return 0; }
    local today today_s
    today=$(date -u +%Y-%m-%d)
    today_s=$(date -u -d "${today}T00:00:00Z" +%s 2>/dev/null || true)
    [[ -n "$today" && -n "$today_s" ]] || { printf '0'; return 0; }
    local total=0
    local f spend hit line provider model
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        # Session pinned to this seat? A session is single-model, so the
        # first model_change event is authoritative (same rule as the
        # free-model daily budget counter, fleet-ops#3723).
        hit=0
        while IFS= read -r line; do
            [[ "$line" == *'"type":"model_change"'* || "$line" == *'"type": "model_change"'* ]] || continue
            provider=$(printf '%s' "$line" | jq -r '.provider // ""' 2>/dev/null || true)
            model=$(printf '%s' "$line" | jq -r '.modelId // ""' 2>/dev/null || true)
            [[ "$provider" == "$p" && "$model" == "$m" ]] && hit=1
            break
        done < "$f" 2>/dev/null || continue
        (( hit )) || continue
        # Sum usage.cost.total over message lines timestamped today (UTC).
        # grep '"cost"' prefilters so jq only parses cost-bearing lines.
        spend=$(grep '"cost"' "$f" 2>/dev/null \
            | jq -s --arg d "$today" \
                '[.[] | select(.type == "message" and ((.timestamp // "") | startswith($d))) | (.message.usage.cost.total // 0)] | add // 0' \
                2>/dev/null || true)
        if [[ "$spend" =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
            total=$(awk -v a="$total" -v b="$spend" 'BEGIN{printf "%.6f", a+b}')
        fi
    done < <(find "$sessions_dir" -type f -name '*.jsonl' \
                \( -name "${today}T*.jsonl" -o -newermt "@${today_s}" \) 2>/dev/null || true)
    printf '%s' "$total"
}

# fleet-ops#3724: true when the seat's configured daily_spend_cap_usd has
# been reached by today's (UTC) Pi usage.cost on the seat. Caches the sum per
# pick (one scan per seat per pick_seat call).
# Args: provider model
# Returns: 0 if the cap is reached (bench), 1 otherwise.
_seat_daily_spend_cap_reached() {
    local p="$1" m="$2"
    local cap="${SEAT_DAILY_SPEND_CAP_USD[$p/$m]:-0}"
    [[ "$cap" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
    local cache_key="_SDSC_${p//[^A-Za-z0-9_]/_}__${m//[^A-Za-z0-9_]/_}"
    local spend="${!cache_key:-}"
    if [[ -z "$spend" ]]; then
        spend=$(_seat_daily_spend_usd "$p" "$m")
        [[ "$spend" =~ ^[0-9] ]] || spend=0
        printf -v "$cache_key" '%s' "$spend"
    fi
    awk -v s="$spend" -v c="$cap" 'BEGIN{exit !(s+0 >= c+0)}'
}

# fleet-ops#3724: bench a seat for the rest of the UTC day when its
# daily_spend_cap_usd is reached. Reuses the quota_bench/usable_at ledger
# shape (same as the free-model daily budget, fleet-ops#3723): the entry is a
# money wall (health_class=quota_bench, failure_mode=quota_cap) so the
# seat-floor fail-open never lifts it, consecutive_failure_count stays 0 (an
# external budget limit, not a seat fault — never charged to the work item),
# and the ledger carries a dated `reason` naming the day the cap fired.
# Best-effort: a write failure fails open (the counter re-evaluates next pick).
# Args: provider model
_mark_seat_spend_cap_bench() {
    local p="$1" m="$2"
    local cap="${SEAT_DAILY_SPEND_CAP_USD[$p/$m]:-0}"
    local path now_utc now_s midnight_s bench_until
    path=$(seat_ledger_path "$p" "$m")
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true
    now_s=$(date -u +%s)
    now_utc=$(date -u -d "@$now_s" +%Y-%m-%dT%H:%M:%SZ)
    midnight_s=$(date -u -d "$(date -u -d "@$now_s" +%Y-%m-%d) tomorrow" +%s 2>/dev/null || echo $((now_s + 86400)))
    (( midnight_s <= now_s )) && midnight_s=$((now_s + 86400))
    bench_until=$(date -u -d "@$midnight_s" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")
    local reason="${now_utc%%T*} daily spend cap USD ${cap}/day reached (Pi usage.cost, fleet-ops#3283 source); seat benched until 00:00 UTC — fleet-ops#3724"
    local tmp="$path.bench.$$.$RANDOM.tmp"
    if jq -nc \
        --arg provider "$p" --arg model "$m" \
        --arg observed "$now_utc" --arg bench "$bench_until" --arg usable "$bench_until" \
        --arg reason "$reason" \
        --argjson http_status 429 --argjson retry_after null \
        --argjson retryable true --argjson seat_dead false --argjson poison_ladder false \
        --argjson count 0 \
        '{
          provider:$provider, model:$model,
          http_status:$http_status, retry_after:$retry_after,
          health_class:"quota_bench",
          retryable:$retryable, seat_dead:$seat_dead, poison_ladder:$poison_ladder,
          observed_at:$observed,
          source:"daily_spend_cap",
          failure_mode:"quota_cap",
          bench_until:$bench,
          usable_at:$usable,
          reason:$reason,
          consecutive_failure_count:$count
        }' > "$tmp" 2>/dev/null; then
        chmod 0644 "$tmp" 2>/dev/null || true
        if mv "$tmp" "$path" 2>/dev/null; then
            seat_log "daily-spend-cap: benched $p/$m until $bench_until (USD ${cap}/day cap reached; not charged to work item — fleet-ops#3724)"
            return 0
        fi
        rm -f "$tmp" 2>/dev/null || true
        seat_log "daily-spend-cap: ledger rename FAILED for $p/$m — fail-open (counter re-evaluates next pick)"
        return 1
    fi
    rm -f "$tmp" 2>/dev/null || true
    seat_log "daily-spend-cap: jq compose FAILED for $p/$m — marker NOT written"
    return 1
}

# fleet-ops#4453: today's (UTC) spend in USD on one provider, measured from
# Pi session TOKENS x the provider's own pi-models cost map (per 1M tokens),
# NOT from usage.cost — ParetoInference's Pareto Pass reports usage.cost=0
# (the $3/wk pass credits bill off the rate card, not per-call cost), so the
# usage.cost-based meter (_seat_daily_spend_usd, fleet-ops#3283) reads 0
# forever and would never hit a $/day cap. The token formula is provider-
# generic: USD = usage.input*in/1e6 + usage.output*out/1e6 +
# usage.cacheRead*cache/1e6. For paretoinference the cost map is input 0.081,
# output 0.162, cacheRead 0.016 -> exactly the issue's
# prompt_tokens*0.081 + cached*0.016 + completion*0.162.
#
# Same scanner shape as _provider_free_daily_request_count / _seat_daily_
# spend_usd: a session is pinned to its provider by the first model_change
# event; only messages timestamped today (UTC) count; a session started
# before midnight keeps appending after it, so a session file named today OR
# modified today is considered.
#
# Args: provider
# Prints: today's token-derived spend in USD (float, 0 on any error / fail-open).
_provider_daily_spend_usd_tokens() {
    local p="$1"
    local sessions_dir="${FLEET_SESSIONS_DIR:-$HOME/.pi/agent/sessions}"
    [[ -d "$sessions_dir" ]] || { printf '0'; return 0; }
    command -v jq >/dev/null 2>&1 || { printf '0'; return 0; }
    # Model cost map for this provider from pi-models. Fail-open to zero prices
    # if the provider block is absent (nothing then spends, the gate no-ops).
    local input_p output_p cache_p
    input_p=$(jq -r --arg p "$p" '.providers[$p].models[0].cost.input // 0' "$MODELS_JSON" 2>/dev/null || echo 0)
    output_p=$(jq -r --arg p "$p" '.providers[$p].models[0].cost.output // 0' "$MODELS_JSON" 2>/dev/null || echo 0)
    cache_p=$(jq -r --arg p "$p" '.providers[$p].models[0].cost.cacheRead // 0' "$MODELS_JSON" 2>/dev/null || echo 0)
    [[ "$input_p" =~ ^[0-9]+(\.[0-9]+)?$ ]] || input_p=0
    [[ "$output_p" =~ ^[0-9]+(\.[0-9]+)?$ ]] || output_p=0
    [[ "$cache_p" =~ ^[0-9]+(\.[0-9]+)?$ ]] || cache_p=0
    local today today_s
    today=$(date -u +%Y-%m-%d)
    today_s=$(date -u -d "${today}T00:00:00Z" +%s 2>/dev/null || true)
    [[ -n "$today" && -n "$today_s" ]] || { printf '0'; return 0; }
    local total=0
    local f hit line provider model
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        hit=0
        while IFS= read -r line; do
            [[ "$line" == *'"type":"model_change"'* || "$line" == *'"type": "model_change"'* ]] || continue
            provider=$(printf '%s' "$line" | jq -r '.provider // ""' 2>/dev/null || true)
            model=$(printf '%s' "$line" | jq -r '.modelId // ""' 2>/dev/null || true)
            [[ "$provider" == "$p" ]] && hit=1
            break
        done < "$f" 2>/dev/null || continue
        (( hit )) || continue
        # Sum token-derived USD over message lines timestamped today (UTC).
        local spend
        spend=$(grep '"usage"' "$f" 2>/dev/null \
            | jq -s --arg d "$today" --argjson in "$input_p" --argjson out "$output_p" --argjson ca "$cache_p" \
                '[.[] | select(.type == "message" and ((.timestamp // "") | startswith($d))) | (((.message.usage.input // 0) * $in) + ((.message.usage.output // 0) * $out) + ((.message.usage.cacheRead // 0) * $ca)) / 1000000] | add // 0' \
                2>/dev/null || true)
        if [[ "$spend" =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
            total=$(awk -v a="$total" -v b="$spend" 'BEGIN{printf "%.6f", a+b}')
        fi
    done < <(find "$sessions_dir" -maxdepth 2 -type f -name '*.jsonl' \
                \( -name "${today}T*.jsonl" -o -newermt "@${today_s}" \) 2>/dev/null || true)
    printf '%s' "$total"
}

# fleet-ops#4453: true when the provider's token-derived daily spend has
# reached the configured stop. Cache the sum per pick (one scan per provider
# per pick_seat call).
# Args: provider
# Returns: 0 if the stop is reached (bench), 1 otherwise.
_provider_daily_budget_reached() {
    local p="$1"
    local stop="${SEAT_PROVIDER_DAILY_STOP_USD[$p]:-}"
    local budget="${SEAT_PROVIDER_DAILY_BUDGET_USD[$p]:-0}"
    [[ -n "${SEAT_PROVIDER_DAILY_BUDGET_USD[$p]:-}" ]] || return 1
    # No explicit stop -> stop at the budget itself.
    [[ -n "$stop" ]] || stop="$budget"
    [[ "$stop" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
    local cache_key="_PDBS_${p//[^A-Za-z0-9_]/_}"
    local spend="${!cache_key:-}"
    if [[ -z "$spend" ]]; then
        spend=$(_provider_daily_spend_usd_tokens "$p")
        [[ "$spend" =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]] || spend=0
        printf -v "$cache_key" '%s' "$spend"
    fi
    awk -v s="$spend" -v c="$stop" 'BEGIN{exit !(s+0 >= c+0)}'
}

# fleet-ops#4453: bench every model on a provider for the rest of the UTC day
# when the provider's token-derived daily USD spend reaches the stop. Reuses
# the quota_bench/usable_at ledger shape (same as the free-model daily budget
# fleet-ops#3723 and the per-seat daily spend cap fleet-ops#3724): health_class
# quota_bench, failure_mode quota_cap, bench_until = next 00:00 UTC,
# consecutive_failure_count 0 (an external budget wall, never charged to the
# work item), with a dated reason. Best-effort: a write failure fails open
# (the counter re-evaluates next pick).
# Args: provider model
_mark_seat_provider_daily_budget_bench() {
    local p="$1" m="$2"
    local budget="${SEAT_PROVIDER_DAILY_BUDGET_USD[$p]:-0}"
    local stop="${SEAT_PROVIDER_DAILY_STOP_USD[$p]:-$budget}"
    local path now_utc now_s midnight_s bench_until
    path=$(seat_ledger_path "$p" "$m")
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true
    now_s=$(date -u +%s)
    now_utc=$(date -u -d "@$now_s" +%Y-%m-%dT%H:%M:%SZ)
    midnight_s=$(date -u -d "$(date -u -d "@$now_s" +%Y-%m-%d) tomorrow" +%s 2>/dev/null || echo $((now_s + 86400)))
    (( midnight_s <= now_s )) && midnight_s=$((now_s + 86400))
    bench_until=$(date -u -d "@$midnight_s" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")
    local reason="${now_utc%%T*} provider daily budget USD ${budget}/day reached (token-derived spend; Pareto Pass rate card, fleet-ops#4453); seat benched until 00:00 UTC"
    local tmp="$path.bench.$$.$RANDOM.tmp"
    if jq -nc \
        --arg provider "$p" --arg model "$m" \
        --arg observed "$now_utc" --arg bench "$bench_until" --arg usable "$bench_until" \
        --arg reason "$reason" \
        --argjson http_status 429 --argjson retry_after null \
        --argjson retryable true --argjson seat_dead false --argjson poison_ladder false \
        --argjson count 0 \
        '{
          provider:$provider, model:$model,
          http_status:$http_status, retry_after:$retry_after,
          health_class:"quota_bench",
          retryable:$retryable, seat_dead:$seat_dead, poison_ladder:$poison_ladder,
          observed_at:$observed,
          source:"provider_daily_budget",
          failure_mode:"quota_cap",
          bench_until:$bench,
          usable_at:$usable,
          reason:$reason,
          consecutive_failure_count:$count
        }' > "$tmp" 2>/dev/null; then
        chmod 0644 "$tmp" 2>/dev/null || true
        if mv "$tmp" "$path" 2>/dev/null; then
            seat_log "provider-daily-budget: benched $p/$m until $bench_until (USD ${budget}/day budget reached; not charged to work item — fleet-ops#4453)"
            return 0
        fi
        rm -f "$tmp" 2>/dev/null || true
        seat_log "provider-daily-budget: ledger rename FAILED for $p/$m — fail-open (counter re-evaluates next pick)"
        return 1
    fi
    rm -f "$tmp" 2>/dev/null || true
    seat_log "provider-daily-budget: jq compose FAILED for $p/$m — marker NOT written"
    return 1
}

# fleet-ops#4453: return 0 if this provider already logged the first
# 429-after-budget (a quota/concurrency wall observed while the daily budget
# is exhausted) so seat-lib only logs the first one. Persisted in the same
# prepaid-usage counter file as provider_daily_logged_429. Args: provider
_provider_daily_429_logged() {
    local p="$1" f
    f=$(_prepaid_usage_path "$p")
    [[ -f "$f" ]] || return 1
    jq -e '.provider_daily_logged_429 == true' "$f" >/dev/null 2>&1
}

# fleet-ops#4453: record that this provider's first 429-after-budget was seen
# (or that the first 200-after-reset was seen). Both are one-time day flags in
# the counter file and carry the UTC date they were observed, so a
# 429-after-budget on one day is distinguishable from a 200-after-reset on the
# next (the allowance resets daily; the reset hour is undocumented).
# Args: provider flag(429|200)
_provider_daily_set_log() {
    local p="$1" flag="$2" f tmp today
    today=$(date -u +%Y-%m-%d)
    f=$(_prepaid_usage_path "$p")
    mkdir -p "$STATE_DIR/prepaid-usage"
    tmp="$f.log.$$"
    if [[ "$flag" == "429" ]]; then
        jq -nc --arg d "$today" --argjson v true '{provider_daily_logged_429:$v,provider_daily_logged_429_date:$d}' >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    else
        jq -nc --arg d "$today" --argjson v true '{provider_daily_logged_200:$v,provider_daily_logged_200_date:$d}' >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    fi
    # Merge into an existing counter file if one exists (the counter is the
    # canonical per-provider state file; write the flag alongside usd_today).
    if [[ -f "$f" ]]; then
        jq -s '.[0] + .[1]' "$f" "$tmp" >"$f.logmerged.$$" 2>/dev/null \
            && mv "$f.logmerged.$$" "$f" 2>/dev/null \
            && { rm -f "$tmp"; return 0; }
        rm -f "$f.logmerged.$$" 2>/dev/null || true
    fi
    if mv "$tmp" "$f" 2>/dev/null; then return 0; fi
    rm -f "$tmp" 2>/dev/null || true
    return 0
}


# ledger is co-written by the pi seat-health.ts extension (after_provider_response
# / cli_spawn) AND by these wrapper-side mark_seat_* functions. A seat that is
# HTTP-200 with a non-empty body but functionally dead for an agentic packet
# (tools=0 / no diagnosis block) gets benched by mark_seat_spawn_fail as
# transient_fault + future usable_at — but a LATER healthy observation from
# seat-health.ts (a different worker's simple packet that produced output)
# clobbers the ledger back to health_class:"healthy" + null usable_at, so
# seat_usable re-admits the dead seat on the next trip and the organ fails
# again. This marker file is written ONLY by the wrapper (mark_seat_spawn_fail
# / mark_seat_empty_run) and never by seat-health.ts, so the bench survives the
# clobber. seat_usable checks it before trusting a stale healthy ledger entry.
#
# fleet-ops#2627: the marker ALSO carries the wrapper-side consecutive_failure_
# count and failure_mode (empty_run / spawn_fail / unknown). The ledger's
# count is reset to 0 by seat-health.ts's healthy clobber, so the wrapper's
# escalating backoff and the failure-ceiling park MUST NOT depend on the
# clobberable ledger. Merging count INTO the marker on every writer call
# lets the count survive the clobber and the #1362 park actually engage for
# a CHRONIC no-op'ing seat (the live 18 empty runs in 2h on healthy-reporting
# seats: opencode/nemotron-3-ultra-free, openrouter/deepseek/deepseek-v4.1-flash).
seat_spawn_bench_path() {
    local p="$1" m="$2" ps ms
    ps="${p//[^A-Za-z0-9._-]/_}"
    ms="${m//[^A-Za-z0-9._-]/_}"
    printf '%s/%s__%s.spawn-bench.json\n' "$LEDGER_DIR" "$ps" "$ms"
}

# Write the spawn-fail/empty-run bench marker. Best-effort: a write failure
# must not block the ledger write or the exit-0 quiet contract. The marker
# carries usable_at (the field seat_usable checks) + provenance + the
# wrapper-side consecutive_failure_count and failure_mode. The count makes
# the marker the DURABLE count authority for the bench class: seat-health.ts
# clobbers the ledger back to health_class=healthy/count=0 on a later 200
# observation, so a wrapper bench's escalating backoff and the failure-ceiling
# park MUST NOT depend on the clobberable ledger. Merging count INTO the
# marker on every writer call lets the count survive the clobber and the
# failure-ceiling park actually engage for a CHRONIC no-op'ing seat (the live
# 18 empty runs in 2h on healthy-reporting seats — fleet-ops#2627).
# Args: provider model usable_at reason backoff_s count failure_mode [seat_dead] [source]
# fleet-ops#3889: the trailing [seat_dead] (optional, default false) lets the
# spawn_fail writer project a durable corpse (seat_dead=true) onto the
# clobber-proof marker. seat-health.ts resets the LEDGER's seat_dead to false
# on every transport 200 (the false-healthy clobber the live
# xkiro/<retired-V4-flash> at 47 spawn_fail showed) — the marker is the only
# record seat-health.ts never touches, so a spawn_fail corpse must live there
# to survive the clobber.
# fleet-ops#4640: a wall length is a claim about the PROVIDER; a wrapper
# exit code is evidence about the LANE. Never the former from the latter.
_seat_wall_source_justified() {
    case "${1:-}" in
        money_boundary|provider_quota_window) return 0 ;;
        # fleet-ops#5274: a permanent corpse from an OpenRouter 404
        # "unavailable for free" is a provider retirement, not a lane fault —
        # the provider's own 404 body is the evidence, and the seat-caps.json
        # intentional_cap_zero=corpse entry is the standing declaration. The
        # corpse marker's usable_at is far-future by design (terminal wall).
        free_retired_corpse) return 0 ;;
    esac
    return 1
}

_seat_text_is_money_wall() {
    local text="$1"
    [[ -n "$text" ]] || return 1
    grep -qiE '\b402\b|insufficient[[:space:]]+credits|credit_insufficient|budget_exceeded|budget_error|usage[[:space:]]+balance[[:space:]]+exhausted|credit[[:space:]]+balance[[:space:]]+depleted|out[[:space:]]+of[[:space:]]+credits|money_boundary' <<<"$text"
}

_seat_clamp_non_money_window_s() {
    local window="${1:-0}" source="${2:-}" declared="${3:-}"
    local max="${SEAT_NON_MONEY_WALL_MAX_S:-21600}"
    [[ "$window" =~ ^[0-9]+$ ]] || window=0
    [[ "$max" =~ ^[0-9]+$ ]] || max=21600
    # fleet-ops#4640/#4800: quota_bench_default_s in seat-caps.json is the
    # operator-declared provider reset window (cline = the 604800 s ClinePass
    # weekly reset). Clamping THAT to 6 h would release a seat that is provably
    # walled for a week, and the next tick would smoke it — re-anchoring
    # observed_at and re-firing FleetProviderQuotaExhausted. Only the declared
    # window is exempt: a geometric escalation or a 24 h failure-ceiling park
    # built ON TOP of it is still clamped, and a wrapper rc=1 with no declared
    # window keeps #4640's 6 h ceiling.
    if [[ "$declared" =~ ^[0-9]+$ ]] && (( declared > max )); then
        max="$declared"
    fi
    if _seat_wall_source_justified "$source"; then
        printf '%s' "$window"
        return 0
    fi
    if (( window > max )); then
        printf '%s' "$max"
        return 0
    fi
    printf '%s' "$window"
}

_seat_write_spawn_bench() {
    local p="$1" m="$2" usable="$3" reason="$4" backoff="$5"
    local count="${6:-0}" mode="${7:-unknown}" seat_dead="${8:-false}"
    local source="${9:-}"
    local path now_utc tmp usable_s now_s remain max_s
    # fleet-ops#3661: never write a spawn-bench marker for a phantom seat key.
    if ! _seat_key_guard "$p" "$m" "_seat_write_spawn_bench"; then return 1; fi
    # fleet-ops#4640: a wrapper exit code is a LANE fault, never a provider wall.
    if [[ "$reason" == no_block:rc=* ]]; then
        seat_log "LANE-FAULT: $p/$m reason=$reason has no provider HTTP status — spawn-bench not written (fleet-ops#4640)"
        return 1
    fi
    now_s=$(date -u +%s)
    usable_s=$(date -u -d "$usable" +%s 2>/dev/null || echo 0)
    max_s="${SEAT_NON_MONEY_WALL_MAX_S:-21600}"
    [[ "$max_s" =~ ^[0-9]+$ ]] || max_s=21600
    if [[ "$usable_s" =~ ^[0-9]+$ ]] && (( usable_s > now_s )); then
        remain=$(( usable_s - now_s ))
        if (( remain > max_s )) && ! _seat_wall_source_justified "$source"; then
            seat_log "WALL-REFUSED: $p/$m usable_at=$usable remain=${remain}s > ${max_s}s without source in {money_boundary,provider_quota_window} writer=_seat_write_spawn_bench reason=$reason (fleet-ops#4640)"
            return 1
        fi
    fi
    path=$(seat_spawn_bench_path "$p" "$m")
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    [[ "$seat_dead" == "true" || "$seat_dead" == "false" ]] || seat_dead=false
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # fleet-ops#4819: a wrapper bench (empty_run / spawn_fail) is a LANE fault
    # that seat-health.ts clobbers back to healthy on the next transport 200
    # (after_provider_response carries status+headers only, never the body).
    # The marker is the durable disqualifying evidence, so it must carry the
    # release contract inline: `release_requires: real-work-probe` tells the
    # next judge (human or automated) that the standing smoke (a tools=0
    # inline reply) can NEVER release this seat — only a real-work probe
    # (tools > 0 AND non-empty stdout) may. The citation names the issue that
    # documents the empty-run churn the bench guards against.
    local release_requires="real-work-probe" citation="fleet-ops#3737"
    tmp="$path.$$.$RANDOM.tmp"
    if jq -nc \
        --arg provider "$p" --arg model "$m" --arg usable "$usable" \
        --arg reason "$reason" --arg written "$now_utc" --argjson backoff "$backoff" \
        --arg mode "$mode" --argjson count "$count" --argjson seat_dead "$seat_dead" \
        --arg writer "_seat_write_spawn_bench" --arg source "$source" \
        --arg release_requires "$release_requires" --arg citation "$citation" \
        '{provider:$provider, model:$model, usable_at:$usable,
          reason:$reason, written_at:$written, backoff_s:$backoff,
          failure_mode:$mode, consecutive_failure_count:$count,
          seat_dead:$seat_dead, writer:$writer, source:$source,
          release_requires:$release_requires, citation:$citation}' \
        > "$tmp" 2>/dev/null; then
        chmod 0644 "$tmp" 2>/dev/null || true
        mv "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 1; }
        _seat_co_write_sidecar "$p" "$m" "$mode" "$usable" "$now_utc" || true
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# fleet-ops#3559: co-write the legacy single-record seat-health sidecar
# (pi-seat-health.json) when the WRAPPER benches a seat. seat-health.ts writes
# this file on every observation and, on a later simple packet's healthy 200,
# reports the benched seat as health_class=healthy/http 200 — the sidecar probe
# and the wrapper's empty_run/spawn_fail bench disagree, so the seat keeps being
# re-selected and burning issues. The wrapper owns the bench (it ran the packet
# that no-op'ed), so it projects the bench to the sidecar the same way the
# per-seat spawn-bench marker is written. Best-effort: a sidecar write failure
# must not fail the bench (the marker is the routing authority; this is the
# record).
# Args: provider model failure_mode usable_at observed_at_utc
_seat_co_write_sidecar() {
    local p="$1" m="$2" mode="$3" usable="$4" observed="$5"
    local http_status retryable source
    [[ -n "$SEAT_HEALTH_SIDECAR" ]] || return 0
    case "$mode" in
        empty_run)  http_status=200; source="cli_spawn" ;;
        spawn_fail) http_status=0;   source="cli_timeout" ;;
        *)          http_status=0;   source="cli_timeout" ;;
    esac
    retryable=true
    local tmp="$SEAT_HEALTH_SIDECAR.$$.$RANDOM.tmp"
    mkdir -p "$(dirname "$SEAT_HEALTH_SIDECAR")" 2>/dev/null || return 1
    if jq -nc \
        --arg provider "$p" --arg model "$m" \
        --argjson http_status "$http_status" --argjson retry_after_null null \
        --arg health_class "transient_fault" --argjson retryable "$retryable" \
        --argjson seat_dead false --argjson poison_ladder false \
        --arg observed "$observed" --arg source "$source" --arg mode "$mode" \
        --arg usable "$usable" \
        '{provider:$provider, model:$model, http_status:$http_status,
          retry_after:$retry_after_null, health_class:$health_class,
          retryable:$retryable, seat_dead:$seat_dead, poison_ladder:$poison_ladder,
          observed_at:$observed, source:$source, failure_mode:$mode, usable_at:$usable}' \
        > "$tmp" 2>/dev/null; then
        chmod 0644 "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$SEAT_HEALTH_SIDECAR" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 1; }
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# True if observed_at is within STALE_SECS of now (i.e. fresh enough to trust).
_seat_observed_fresh() {
    local obs="$1" now obs_s
    [[ -n "$obs" ]] || return 1
    now=$(_seat_now_epoch)
    obs_s=$(date -u -d "$obs" +%s 2>/dev/null || echo 0)
    [[ "$obs_s" =~ ^[0-9]+$ ]] || return 1
    (( obs_s > 0 && now - obs_s <= STALE_SECS ))
}

# True if observed_at is within RATE_LIMIT_FRESH_SECS of now. A rate_limited
# marker older than this is treated as stale: the seat is retried (the rate
# limit may have reset), which is the P15 retry-after-window semantics.
_seat_rate_limit_fresh() {
    local obs="$1" now obs_s
    [[ -n "$obs" ]] || return 1
    now=$(_seat_now_epoch)
    obs_s=$(date -u -d "$obs" +%s 2>/dev/null || echo 0)
    [[ "$obs_s" =~ ^[0-9]+$ ]] || return 1
    (( obs_s > 0 && now - obs_s <= RATE_LIMIT_FRESH_SECS ))
}

# True if the given ISO timestamp is strictly in the future relative to now.
_seat_in_future() {
    local ts="$1" now ts_s
    [[ -n "$ts" ]] || return 1
    now=$(_seat_now_epoch)
    ts_s=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
    [[ "$ts_s" =~ ^[0-9]+$ ]] || return 1
    (( ts_s > now ))
}

# Seconds until an ISO timestamp, or return 1 if it is missing / not future.
# Used by the #3324 minimum-usable floor to pick the shortest remaining bench.
_seat_remaining_s() {
    local ts="$1" now ts_s
    [[ -n "$ts" ]] || return 1
    now=$(_seat_now_epoch)
    ts_s=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
    [[ "$ts_s" =~ ^[0-9]+$ ]] || return 1
    (( ts_s > now )) || return 1
    printf '%s\n' "$((ts_s - now))"
}

# True if a corpse-retired copy of this seat exists in a dated
# seats-corpse-retired-<UTC-ts>/ audit dir from the last 7 days.
# fleet-ops#3669: the corpse-retirement caller (bin/fleet-seat-comeback-release)
# physically MOVES a terminal corpse ledger out of the live roster into a
# dated audit dir. Before this check, a seat whose ledger was moved away fell
# through to the "NO HEALTH DATA (no ledger file) — assuming usable" fail-open
# and pick_seat re-picked the deliberately-retired dead seat, burning claims
# (hetzner 2 claims in 6 min, 2026-09-05). A corpse-retired copy within the
# last 7 days means the seat was deliberately retired; it must stay UNPICKABLE.
# (The primary fix is write_parked_ledger leaving a seat_dead=true parked
# ledger in the live roster; this is the read-side fence for seats retired
# before that writer existed.)
_seat_has_recent_corpse_retired() {
    local p="$1" m="$2" ps ms base now_e cutoff d ts
    ps="${p//[^A-Za-z0-9._-]/_}"
    ms="${m//[^A-Za-z0-9._-]/_}"
    base="$(dirname "$LEDGER_DIR")"
    now_e=$(_seat_now_epoch)
    cutoff=$(( now_e - 604800 ))  # 7 days
    for d in "$base"/seats-corpse-retired-*; do
        [[ -d "$d" ]] || continue
        [[ -f "$d/${ps}__${ms}.json" ]] || continue
        ts=$(date -u -d "${d##*seats-corpse-retired-}" +%s 2>/dev/null || echo 0)
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        (( ts >= cutoff )) && return 0
    done
    return 1
}

# Seat health: read the per-seat ledger and decide if a SPECIFIC seat is usable
# right now. Returns 0 if usable, non-zero otherwise.
#
# Authority: $LEDGER_DIR/<provider>__<sanitised-model>.json, written by the pi
# seat-health extension. No polling, no network — file reads only.
#
# Decision:
#   - no file / unparseable / stale observed_at (> STALE_SECS) -> USABLE, but
#     log a loud "no health data" line (do not brick the ladder). EXCEPTIONS:
#     a seat_dead=true corpse is UNUSABLE regardless of observed_at staleness
#     (fleet-ops#2327 — death is not a freshness question; only a probe
#     success writes a healthy observation and clears the corpse); a
#     quota_exhausted seat whose usable_at (or bench_until) is still in the
#     future is UNUSABLE for the same reason quota_bench is — the advertised
#     reset window outlives STALE_SECS (live 2026-09-02: two cline-pass 402s
#     with usable_at 16d out; the 6h fail-open re-offered them, they 402'd
#     again, and FleetProviderQuotaExhausted never aged out of its 1h window).
#   - seat_dead=true                              -> unusable (corpse, terminal)
#   - health_class in {credentials_bad, quota_exhausted} -> unusable WHILE
#     the observation is fresh; quota_exhausted with a future usable_at is
#     also unusable when the observation is stale (see above).
#   - quota_bench (fleet-ops#90): a hard-capped seat benched for its advertised
#     reset window. UNUSABLE while bench_until is in the future (one log line
#     per skip: "benched until <ts>"); once bench_until passes the seat is
#     RETRIED (fail-open) — a walled seat is a lane fault, never charged to the
#     work item. Evaluated BEFORE the stale-observed_at fail-open: a weekly
#     cap's bench_until is days in the future, but observed_at goes stale
#     after STALE_SECS (6h). No bench_until -> unusable (defensive; the writer
#     always sets one).
#   - rate_limited: excluded while the marker is FRESH (observed_at <
#     RATE_LIMIT_FRESH_SECS=30min) and usable_at is in the future; once the
#     marker ages past 30min the seat is RETRIED (rate limit may have reset).
#     fleet-ops#3586: past SEAT_FAILURE_CEILING consecutive 429s (the live
#     xkiro c=48-63 shape) a rate_limited seat is NOT a transient rate limit
#     — it is unusable — and the read-side park fence holds it behind the
#     long wall instead of the endless 15-min re-wall loop.
#   - transient_fault past SEAT_FAILURE_CEILING consecutive failures -> unusable
#     (parked behind the long wall until observed_at + SEAT_PARK_WALL_S, then
#     fail-opens — the fleet-ops#2288 read-side fence for extension-written
#     flat-window markers whose write-side escalation lives in the out-of-repo
#     extension).
#   - otherwise                                   -> usable.
seat_usable() {
    local p="$1" m="$2" f hc dead observed usable_at bench_until fail_count
    # fleet-ops#4690: hold every devin seat while IPv4 localhost is
    # unresolvable. Checked BEFORE spawn-bench/ledger so a healthy probe
    # or 900s empty-run expiry cannot re-offer the seat. The class IS the
    # missing /etc/hosts line; restoring it is the release.
    if [[ "$p" == "devin" ]] && ! sandbox_localhost_resolves; then
        (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: UNUSABLE (sandbox-localhost-unresolvable — /etc/hosts missing 127.0.0.1 localhost)"
        return 1
    fi
    # fleet-ops#1512: clobber-proof spawn-fail/empty-run bench marker. The
    # ledger is co-written by seat-health.ts, which can flip a benched seat
    # back to health_class:"healthy" + null usable_at on a later healthy HTTP
    # observation (a different worker's simple packet that produced output).
    # That clobber re-admits a seat the wrapper benched for being functionally
    # dead for agentic work (tools=0 / no diagnosis block), so the organ
    # re-picks it and fails again. This marker is written ONLY by the wrapper
    # (mark_seat_spawn_fail / mark_seat_empty_run) and never by seat-health.ts,
    # so the bench survives the clobber. Checked FIRST, before the ledger is
    # even read: a fresh marker wins regardless of what the ledger says (or
    # whether the ledger file exists at all).
    local sb_path sb_usable sb_written sb_written_s sb_lf sb_obs sb_obs_s
    local sb_corpse_dead sb_corpse_src
    sb_path=$(seat_spawn_bench_path "$p" "$m")
    if [[ -f "$sb_path" ]]; then
        # fleet-ops#3889: a spawn_fail CORPSE (marker seat_dead=true) is held
        # TERMINALLY and DURABLY, regardless of the clock (usable_at) and
        # regardless of the #3737 marker-age fail-open — that fail-open exists
        # to bound a stalled comeback organ's hold on a RECOVERABLE bench, but a
        # marker-declared corpse is the writer's verdict that the seat cannot
        # even spawn, and it survives the false-healthy 200 that clobbers the
        # ledger to seat_dead=false. Only a real recovery probe (the comeback
        # organ writing source="comeback_release" + seat_dead=false to the
        # ledger) re-proves the seat; until then it stays unpickable.
        sb_corpse_dead=$(jq -r '.seat_dead // false' "$sb_path" 2>/dev/null || echo false)
        if [[ "$sb_corpse_dead" == "true" ]]; then
            sb_corpse_src=""
            sb_lf=$(seat_ledger_path "$p" "$m")
            [[ -f "$sb_lf" ]] && sb_corpse_src=$(jq -r '.source // ""' "$sb_lf" 2>/dev/null || true)
            if [[ "$sb_corpse_src" != "comeback_release" ]]; then
                (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: UNUSABLE (marker-declared spawn-fail corpse seat_dead=true — held durably for a recovery probe, fleet-ops#3889)"
                return 1
            fi
            # Recovered corpse: a comeback probe succeeded and re-wrote the
            # ledger (fresh observed_at, source=comeback_release, seat_dead=
            # false). The corpse marker is now stale — drop its clock/age holds
            # so the (healthy) ledger decides.
            sb_usable=""
            sb_written=""
        fi
        # Non-corpse markers re-read their own usable_at below. A marker-
        # corpse that survives to here has ALREADY been released as a real
        # recovery (the held-corpse branch returned 1 above), so its clock is
        # cleared (sb_usable="") and the ledger decides — no future-hold.
        if [[ "$sb_corpse_dead" != "true" ]]; then
            sb_usable=$(jq -r '.usable_at // ""' "$sb_path" 2>/dev/null || true)
            if [[ -n "$sb_usable" ]] && _seat_in_future "$sb_usable"; then
                seat_log "seat $p/$m: UNUSABLE (spawn-bench until $sb_usable — wrapper bench held)"
                return 1
            fi
        fi
        # fleet-ops#3737: an expired (or clockless) wrapper bench must NOT
        # silently fail-open while the marker is still the latest evidence
        # for the seat. seat-health.ts records a transport 200 as healthy
        # during the very run that then exits 0 with 0-byte stdout —
        # pi's after_provider_response event carries status+headers only,
        # never the body, so an empty completion is indistinguishable from
        # a healthy response — and that healthy write clobbers the ledger's
        # copy of the bench. Before this change an expired marker fell
        # through to the clobbered ledger and the next work item became the
        # de-facto probe (live: ollama/<retired-V4-flash>, 12 empty
        # runs in 2h — every bench expiry re-admitted a still-dead seat).
        #
        # Hold while ALL of these are true:
        #   - the marker is FRESH: written within EMPTY_RUN_COUNT_WINDOW_S
        #     (the same 24 h window the count-merge uses). Older than that
        #     is archaeology — fail-open so a stalled comeback organ cannot
        #     strand the seat forever;
        #   - the ledger carries NO observation newer than the marker's
        #     written_at. A newer entry is post-bench evidence: a run that
        #     produced output writes healthy with no following marker, so
        #     observed_at > written_at means a real run already paid the
        #     discovery cost — fall through and let the ledger decide.
        # The hold is released by fleet-seat-comeback-release: its
        # tool-using probe writes a fresh healthy observation on success
        # (observed_at > written_at lifts this check) and re-benches the
        # marker on failure. Re-admission is probe-gated, not clock-gated,
        # so a dead-weight seat never costs a work item a turn.
        sb_written=$(jq -r '.written_at // ""' "$sb_path" 2>/dev/null || true)
        sb_written_s=$(date -u -d "$sb_written" +%s 2>/dev/null || echo 0)
        if [[ "$sb_written_s" =~ ^[0-9]+$ ]] && (( sb_written_s > 0 )) \
            && (( $(_seat_now_epoch) - sb_written_s <= ${EMPTY_RUN_COUNT_WINDOW_S:-86400} )); then
            sb_lf=$(seat_ledger_path "$p" "$m")
            sb_obs=""
            [[ -f "$sb_lf" ]] && sb_obs=$(jq -r '.observed_at // ""' "$sb_lf" 2>/dev/null || true)
            sb_obs_s=$(date -u -d "$sb_obs" +%s 2>/dev/null || echo 0)
            [[ "$sb_obs_s" =~ ^[0-9]+$ ]] || sb_obs_s=0
            if (( sb_obs_s <= sb_written_s )); then
                (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: UNUSABLE (wrapper bench ${sb_usable:-none} expired, marker is latest evidence — held for comeback-release probe, fleet-ops#3737)"
                return 1
            fi
            # fleet-ops#3826: a seat whose marker count is past the failure
            # ceiling is CHRONICALLY spawn-failing. seat-health.ts logs a
            # transport 200 as healthy during the very run that then exits 0
            # with 0-byte stdout (after_provider_response carries status+
            # headers only, never the body), so its healthy write
            # (observed_at > marker written_at) is NOT recovery evidence —
            # it is the same false-healthy #3737 guards against. Without this
            # fence the seat is re-offered to a work item every park-wall
            # expiry (24h), spawn-fails again (no_block:rc=1), and the count
            # climbs forever while the ledger stays health_class=healthy /
            # http 200 (live: xkiro/<retired-V4-flash> at 47 consecutive
            # spawn_fail). Only a comeback-release tool-using probe
            # (source="comeback_release") is real recovery for a
            # ceiling-parked seat; hold until then. The marker age gate
            # above (>24h fail-open) still bounds a dead comeback organ.
            local sb_mcount sb_mmode sb_ceil sb_lsrc
            sb_mcount=$(jq -r '.consecutive_failure_count // 0' "$sb_path" 2>/dev/null || echo 0)
            [[ "$sb_mcount" =~ ^[0-9]+$ ]] || sb_mcount=0
            sb_mmode=$(jq -r '.failure_mode // ""' "$sb_path" 2>/dev/null || true)
            sb_ceil="${SEAT_FAILURE_CEILING:-20}"
            [[ "$sb_mmode" == "empty_run" ]] && sb_ceil="${EMPTY_RUN_FAILURE_CEILING:-5}"
            if _seat_parked_by_ceiling "$sb_mcount" "$sb_ceil"; then
                sb_lsrc=""
                [[ -f "$sb_lf" ]] && sb_lsrc=$(jq -r '.source // ""' "$sb_lf" 2>/dev/null || true)
                if [[ "$sb_lsrc" != "comeback_release" ]]; then
                    (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: UNUSABLE (marker count=$sb_mcount >= ${sb_ceil} ceiling, ledger healthy write source=${sb_lsrc:-none} is not comeback_release — held for tool-using probe, fleet-ops#3826)"
                    return 1
                fi
            fi
        fi
    fi
    f=$(seat_ledger_path "$p" "$m")
    if [[ ! -f "$f" ]]; then
        # fleet-ops#3669: a seat whose corpse ledger was physically moved into a
        # dated seats-corpse-retired-<ts>/ audit dir must NOT fall through to
        # the fail-open below — that re-picked the deliberately-retired dead
        # seat and burned claims. A corpse-retired copy within the last 7 days
        # means the seat was retired on purpose; keep it UNPICKABLE.
        if _seat_has_recent_corpse_retired "$p" "$m"; then
            (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: UNUSABLE (corpse-retired copy within last 7 days — deliberately retired, fleet-ops#3669)"
            return 1
        fi
        (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: NO HEALTH DATA (no ledger file) — assuming usable"
        return 0
    fi
    # Unit-separator join (not TSV): bash `read` treats tab as IFS whitespace
    # and collapses consecutive tabs, which would shift bench_until left when
    # usable_at is empty (the 9d fixture and any ledger without usable_at).
    # \x1f is not whitespace, so empty fields survive. Include newline in IFS
    # so the trailing jq newline is not glued onto bench_until.
    IFS=$'\x1f'$'\n' read -r hc dead observed usable_at bench_until fail_count fail_mode < <(
        jq -r '[(.health_class//""),(.seat_dead|tostring),(.observed_at//""),(.usable_at//""),(.bench_until//""),(.consecutive_failure_count//0),(.failure_mode//"")] | join("\u001f")' "$f" 2>/dev/null || true
    )
    if [[ -z "$hc" ]]; then
        (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: NO HEALTH DATA (ledger unparseable) — assuming usable"
        return 0
    fi
    # quota_bench BEFORE stale-observed_at: bench_until is the source of truth
    # for the advertised reset window, which can outlive STALE_SECS.
    if [[ "$hc" == "quota_bench" ]]; then
        # fleet-ops#2563: the read side caps too. quota_bench markers are also
        # written by the OUT-OF-REPO seat-health extension straight from the
        # vendor's Retry-After (live: 1530000s = 17.7d on a weekly-resetting
        # provider), so the write-side geometric cap cannot reach them. Same
        # fence shape as the #2288 transient_fault park: hold the seat only to
        # the provider's reset horizon, then fail open and re-probe.
        if [[ -n "$bench_until" ]]; then
            local capped_bench
            capped_bench=$(_wall_capped_at_horizon "$p" "$observed" "$bench_until")
            if [[ "$capped_bench" != "$bench_until" ]]; then
                seat_log "seat $p/$m: quota_bench wall $bench_until CAPPED to $capped_bench (provider reset horizon from quota_window — re-probe cadence, fleet-ops#2563)"
                bench_until="$capped_bench"
            fi
        fi
        if [[ -n "$bench_until" ]] && _seat_in_future "$bench_until"; then
            (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: benched until $bench_until (quota_bench)"
            return 1
        fi
        if [[ -n "$bench_until" ]]; then
            seat_log "seat $p/$m: bench expired ($bench_until passed) — assuming usable (fail-open)"
            return 0
        fi
        (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: UNUSABLE (quota_bench with no bench_until — defensive block)"
        return 1
    fi
    # fleet-ops #652 hot-patch: overload_bench (503 / upstream-overload) is
    # the transient sibling of quota_bench. Same fail-open semantics, same
    # observed_at-vs-bench_until ordering — the 503 storm can outlive the
    # 6h stale window, so bench_until wins. Without this branch the seat
    # would fall through to the backoff / usable_at path with a less
    # informative log line and pick_seat would still skip it (usable_at
    # == bench_until), but the auditor's post-mortem rollup loses the
    # overload_bench distinction.
    if [[ "$hc" == "overload_bench" ]]; then
        if [[ -n "$bench_until" ]] && _seat_in_future "$bench_until"; then
            (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: benched until $bench_until (overload_bench)"
            return 1
        fi
        if [[ -n "$bench_until" ]]; then
            seat_log "seat $p/$m: bench expired ($bench_until passed) — assuming usable (fail-open)"
            return 0
        fi
        (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: UNUSABLE (overload_bench with no bench_until — defensive block)"
        return 1
    fi
    # Auditor 2026-08-27: hang_bench (model accepted request but never
    # finalised before TimeoutStartSec / PI_HANG_TIMEOUT_S). Same fail-open
    # semantics as overload_bench; a 180s default is short so the ladder
    # is not starved if the hang self-clears.
    if [[ "$hc" == "hang_bench" ]]; then
        if [[ -n "$bench_until" ]] && _seat_in_future "$bench_until"; then
            (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: benched until $bench_until (hang_bench)"
            return 1
        fi
        if [[ -n "$bench_until" ]]; then
            seat_log "seat $p/$m: hang bench expired ($bench_until passed) — assuming usable (fail-open)"
            return 0
        fi
        (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: UNUSABLE (hang_bench with no bench_until — defensive block)"
        return 1
    fi
    # fleet-ops#2327: a corpse (seat_dead=true) is TERMINALLY excluded. The
    # stale-observed_at fail-open below must NOT resurrect it: a seat that
    # failed past the corpse threshold stays off the ladder until a healthy
    # observation (seat_dead=false, count=0, class back to healthy) is
    # recorded. Before this change a corpse whose observed_at aged past
    # STALE_SECS was
    # "assumed usable" again — workers re-picked the guaranteed-failing seat
    # and the consecutive_failure_count kept climbing (muse-spark:
    # 80 -> 150 straight 500s while it sat cap=0 in the map). Death is not a
    # freshness question; no fleet mechanism auto-writes the healthy
    # observation anymore (the seat-walled-probe weekly probe was deleted,
    # fleet-ops#2394) — a corpse re-enters only after manual intervention
    # (re-auth / provider recovery), surfaced by the FleetDeadCredentialSeats
    # alert.
    if [[ "$dead" == "true" ]]; then
        (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: UNUSABLE (seat_dead=true, class=$hc)"
        return 1
    fi
    # quota_exhausted BEFORE stale-observed_at: usable_at (fallback:
    # bench_until) is the advertised reset, which outlives STALE_SECS
    # the same way quota_bench's bench_until does. Live 2026-09-02:
    # cline-pass/deepseek-v4.1-flash + cline-pass/minimax-m3 both 402 with
    # usable_at 16d out (retry_after ~1.4e6s from parseCliRetryAfter
    # "resets in Nd Nh"). After 6h the stale fail-open re-offered them,
    # they 402'd again, consecutive_failure_count climbed, and the
    # fleet-ops#2712 1h window never emptied so FleetProviderQuotaExhausted
    # stayed firing. Honour the wall until usable_at; once it passes,
    # fail-open exactly once (one probe, not a 6h re-offer loop).
    if [[ "$hc" == "quota_exhausted" ]]; then
        local qe_until="$usable_at"
        [[ -z "$qe_until" ]] && qe_until="$bench_until"
        if [[ -n "$qe_until" ]] && _seat_in_future "$qe_until"; then
            (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: UNUSABLE (quota_exhausted until $qe_until)"
            return 1
        fi
        if [[ -n "$qe_until" ]]; then
            seat_log "seat $p/$m: quota_exhausted wall expired ($qe_until passed) — assuming usable (fail-open)"
            return 0
        fi
        # No usable_at/bench_until: keep the existing unconditional hold
        # while the observation is fresh; if it is stale, fall through to
        # the 6h fail-open (no advertised reset to honour).
        if _seat_observed_fresh "$observed"; then
            (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: UNUSABLE (health_class=quota_exhausted)"
            return 1
        fi
        seat_log "seat $p/$m: NO HEALTH DATA (observed_at ${observed:-<empty>} stale >${STALE_SECS}s, quota_exhausted with no usable_at) — assuming usable"
        return 0
    fi
    # fleet-ops#2288: extension-written transient_fault markers (source
    # provider_fetch / after_provider_response) carry a FLAT usable_at window
    # from the seat-health extension; the write-side escalation lives in that
    # OUT-OF-REPO extension (#1422/#2145) and the bash fences (#1362/#1408)
    # cover bash-written markers only. So a seat whose ledger shows
    # transient_fault with a runaway consecutive_failure_count (live:
    # opencode/muse-spark-1.2-contributor-free at 149 straight HTTP 500s)
    # was re-offered every flat-window cycle (30s), even from a stale pre-fix
    # ledger. Park the READ side with the same long wall the marker writers
    # use: past the failure ceiling a transient_fault ledger is held until
    # observed_at + SEAT_PARK_WALL_S, then fail-opens (one probe per park
    # wall, not per flat window). Same contract as #1362: a healthy write
    # resets count to 0, so a recovered seat is never walled permanently.
    # fleet-ops#3727: empty runs use a lower EMPTY_RUN_FAILURE_CEILING (default
    # 3 per fleet-ops#3760) so a chronic no-op'er parks on the read side at the
    # same threshold the writer parks at, not the generic 20.
    # fleet-ops#3586: rate_limited is the SAME flat/re-walled class as
    # transient_fault — a seat that keeps answering http 429 with a short
    # usable_at (~15min) gets re-walled every cycle and its count climbs
    # (live: xkiro/<retired-V4-flash> c=63, deepseek-v4-pro c=52,
    # minimax-m3:free c=48 all 429 rate_limited). A seat that has failed
    # N>=SEAT_FAILURE_CEILING times consecutively is not rate-limited (a
    # 1-15min wall would have cleared long ago), it is unusable. So the
    # read-side park fence below covers rate_limited too: past the ceiling
    # it is held behind the long wall instead of the flat re-offer loop.
    local _park_ceil="${SEAT_FAILURE_CEILING:-20}"
    [[ "$fail_mode" == "empty_run" ]] && _park_ceil="${EMPTY_RUN_FAILURE_CEILING:-3}"
    if [[ ( "$hc" == "transient_fault" || "$hc" == "rate_limited" ) && -n "$observed" ]] && _seat_parked_by_ceiling "$fail_count" "$_park_ceil"; then
        local park_end_s park_end_iso
        park_end_s=$(($(date -u -d "$observed" +%s 2>/dev/null || echo 0) + $(_park_wall_s "$fail_count" "$_park_ceil")))
        park_end_iso=$(date -u -d "@$park_end_s" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$observed")
        if _seat_in_future "$park_end_iso"; then
            (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: UNUSABLE ($hc count=$fail_count >= ${_park_ceil}, parked until $park_end_iso — long wall, not flat re-offer)"
            return 1
        fi
    fi
    if ! _seat_observed_fresh "$observed"; then
        seat_log "seat $p/$m: NO HEALTH DATA (observed_at ${observed:-<empty>} stale >${STALE_SECS}s) — assuming usable"
        return 0
    fi
    if [[ "$hc" == "credentials_bad" ]]; then
        (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: UNUSABLE (health_class=$hc)"
        return 1
    fi
    # rate_limited: the authoritative signal is usable_at. If usable_at is in
    # the future, the seat is still benched — regardless of marker freshness.
    # Only when usable_at has passed (or is empty) do we consider marker freshness:
    #   - fresh marker + no usable_at -> still unusable (conservative)
    #   - stale marker + usable_at passed/empty -> retry (rate limit may have reset)
    if [[ "$hc" == "rate_limited" ]]; then
        if [[ -n "$usable_at" ]] && _seat_in_future "$usable_at"; then
            (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: UNUSABLE (rate_limited until $usable_at, observed ${observed:-<empty>})"
            return 1
        fi
        if _seat_rate_limit_fresh "$observed"; then
            (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: UNUSABLE (rate_limited, observed ${observed:-<empty>}, no usable_at or usable_at passed)"
            return 1
        fi
        seat_log "seat $p/$m: retrying after rate_limited (observed ${observed:-<empty>} aged past ${RATE_LIMIT_FRESH_SECS}s, usable_at passed or empty) — assuming usable"
        return 0
    fi
    if [[ -n "$usable_at" ]] && _seat_in_future "$usable_at"; then
        (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: UNUSABLE (backoff until $usable_at, class=$hc)"
        return 1
    fi
    return 0
}

# --- credential precheck (fleet-ops#36) ------------------------------------
# A provider that PASSES the cap-map allowlist can still have NO usable
# credential — its env file was deleted, it was added to the cap map by
# mistake, or its apiKey command returns nothing. The reactive seat-health
# ledger only records credentials_bad AFTER a real attempt has burned a
# retry slot (~1s each). On 2026-08-25 the fleet burned every tick on
# groq/openai/gpt-oss-20b ("No API key found for openrouter") because the
# cap map was the only gate and the ledger had no failure recorded yet.
#
# This precheck resolves the provider's apiKey the SAME way pi does
# (custom-provider.md: "!command" executes, "$VAR"/"${VAR}" interpolate,
# anything else is a literal) and rejects the seat up-front when no key can
# be obtained — defence in depth ON TOP of the cap map, not a replacement.
#
# A provider with NO apiKey field (OAuth-only providers, or test fixtures)
# is NOT rejected here: credential status cannot be determined from
# models.json alone, and bricking OAuth seats would be wrong. The reactive
# ledger remains the backstop for those. Fail open, log loud.
#
# Security: the resolved key is captured into a variable and NEVER printed
# or logged — only its non-emptiness is tested. The apiKey commands in
# models.json are Nish's own trusted config (pi itself runs them).
PI_SEAT_CREDENTIAL_PRECHECK="${PI_SEAT_CREDENTIAL_PRECHECK:-1}"
# Per-pick_seat call cache: provider -> "1" (has key) | "0" (no key).
# Declared in pick_seat so the cache lives exactly one selection pass and
# a provider with several models is resolved once, not once per model.
declare -A _cred_cache=()

# Per-pick_seat call cache for active-seats counts (fleet-ops#1297).
# count_active_on_provider and count_active_on_seat are called PER non-
# excluded seat in the pick_seat loop, and each re-read the entire
# active-seats registry (jq + systemctl per file) plus the legacy unit
# list (systemctl per unit). At 7 registry files + 8 live units and ~10
# non-excluded seats that is ~690 subprocess spawns per pick_seat call
# (~4.4s measured), and pick_seat runs thousands of times per 2h window
# under a seat storm — the direct cause of load1=148 on 2026-08-29 with
# 13520 at-capacity skips in 2h. The registry does not change during a
# single pick_seat pass, so _build_pick_active_cache reads it ONCE and
# the count functions below consult these cached counts instead of
# re-spawning jq/systemctl per seat.
declare -A _PICK_REG_PROVIDER_COUNT=()
declare -A _PICK_REG_SEAT_COUNT=()
declare -A _PICK_LEG_PROVIDER_COUNT=()
declare -A _PICK_LEG_SEAT_COUNT=()
declare -A _PICK_REG_SEEN_BASE=()
_PICK_REG_ISSUE_N=0
_PICK_REG_ORG_N=0
_PICK_LEG_ISSUE_N=0
_PICK_LEG_ORG_N=0
_PICK_ACTIVE_CACHE_BUILT=0

# Returns 0 if provider $1 has a resolvable credential, 1 if it positively
# does not. See the block comment above for the resolution rules and the
# fail-open policy for providers with no apiKey field.
provider_has_credential() {
    local p="$1" ak key vname
    (( PI_SEAT_CREDENTIAL_PRECHECK )) || return 0
    # Per-call cache (set up by pick_seat). A provider appears once per
    # model in enumerate_seats; the credential is per-provider, so cache.
    if [[ -n "${_cred_cache[$p]+x}" ]]; then
        [[ "${_cred_cache[$p]}" == 1 ]] && return 0 || return 1
    fi
    ak=$(jq -r --arg p "$p" '.providers[$p].apiKey // ""' "$MODELS_JSON" 2>/dev/null || true)
    if [[ -z "$ak" ]]; then
        # No apiKey field: cannot precheck from models.json. Fail open so
        # OAuth/subscription providers and test fixtures are not bricked;
        # the reactive ledger catches a real credentials_bad. Not cached
        # (a key could appear mid-pass in theory) — cheap jq only.
        seat_log "credential precheck: $p has no apiKey field — skipping precheck (reactive ledger is backstop)"
        return 0
    fi
    key=""
    if [[ "$ak" == !* ]]; then
        # Leading "!": execute the rest as a shell command, key = stdout.
        # Capture stdout only; NEVER log it. Errors swallowed (|| true) so
        # a missing env file resolves to empty -> rejected, not a crash.
        key=$(bash -c "${ak#!}" 2>/dev/null || true)
    elif [[ "$ak" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$ ]] || [[ "$ak" =~ ^\$([A-Za-z_][A-Za-z0-9_]*)$ ]]; then
        # Pure "$VAR" / "${VAR}" reference: resolve the env var directly.
        vname="${BASH_REMATCH[1]}"
        key="${!vname:-}"
    else
        # Literal key, or a mixed "$VAR"-interpolated literal. pi would
        # interpolate the env refs and use the result; a missing var yields
        # a partial key that the live request rejects — not our call to
        # pre-reject a non-empty literal here.
        key="$ak"
    fi
    if [[ -n "$key" ]]; then
        _cred_cache[$p]=1
        return 0
    fi
    _cred_cache[$p]=0
    seat_log "credential precheck: $p rejected (apiKey resolves to empty — no credential available)"
    return 1
}

# --- active seat accounting (P4-A) -----------------------------------------
# Two sources of truth, summed:
#   1. $ACTIVE_SEATS_DIR/<unit>.json — written by pi-issue-run / pi-packet-run
#      when they pick a seat, deleted when they exit. Source of truth for
#      workers spawned by the new path.
#   2. Legacy grep over running systemd units' ExecStart lines. Catches
#      pi-issue-* and pi-packet-* units spawned with hardcoded
#      --provider X --model Y in ExecStart (the old intake path and the
#      cutover window before all workers are on the new path).
#
# Both are read; the sum is reported. This means a cap is honoured the moment
# either path reports the seat taken, so a legacy worker on devin/glm-5-2
# blocks new picks to that seat even before the new path writes its own entry.

# Parse provider and model out of an ExecStart line. Sets globals _exec_p _exec_m.
# Empty if no match.
_exec_p=""; _exec_m=""
_parse_exec_provider_model() {
    _exec_p=""; _exec_m=""
    local line="$1"
    # strip newlines and collapse whitespace so the regex stays sane
    line="${line//$'\n'/ }"
    if [[ "$line" =~ --provider[[:space:]]+([^[:space:]\'\"]+) ]]; then
        _exec_p="${BASH_REMATCH[1]}"
    fi
    if [[ "$line" =~ --model[[:space:]]+([^[:space:]\'\"]+) ]]; then
        _exec_m="${BASH_REMATCH[1]}"
    fi
}

# Count currently active workers on a given provider/model seat.
# Aggregates state-dir + legacy grep. Used by pick_seat to honour per-model caps.

# True if the given `ExecStart` line from `systemctl show -p ExecStart`
# represents a pi worker. Matches the literal command sequence "pi --print"
# so ad-hoc `pi-systemd-run --unit <odd-name>` units count, not only units
# whose names start with `pi-` (fleet-ops#1155).
_exec_is_pi_worker() {
    local line="$1"
    [[ "$line" == *"pi --print"* ]]
}

# Echo the unit names of active/activating user services whose ExecStart
# contains the literal pattern "pi --print". Never filters by unit name.
#
# Note on iteration: `for u in $(list-units ...)` word-splits the multi-word
# output of each line (e.g. "unit.service loaded active running /bin/sh ..."),
# so we use `while IFS= read -r line` and parse the unit name from the first
# token. A line that does not end with .service is skipped.
_seat_list_pi_exec() {
    # Offline tests set PI_SEAT_LIB_CHECK_SYSTEMD=0 so pick_seat cannot bleed
    # live unit counts into a scratch cap map (fleet-ops#142).
    if (( ! ${PI_SEAT_LIB_CHECK_SYSTEMD:-1} )); then
        return 0
    fi
    local line u
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # First whitespace-delimited token is the unit name.
        u="${line%% *}"
        [[ "$u" == *.service ]] || continue
        local execstart
        execstart=$(systemctl --user show "$u" --property=ExecStart --value 2>/dev/null || true)
        _exec_is_pi_worker "$execstart" || continue
        echo "$u"
    done < <(systemctl --user list-units --type=service --state=active,activating --no-legend --plain 2>/dev/null || true)
}

# Active/activating worker units (legacy ExecStart path).
# fleet-ops#1155: enumerate by ExecStart content, not unit-name patterns.
_seat_list_unit() {
    _seat_list_pi_exec
}

# Org/repair packets: same ExecStart-based list. Ad-hoc `pi-systemd-run`
# units with odd names are included because their ExecStart contains
# "pi --print" (fleet-ops#1155).
_seat_list_org_unit() {
    _seat_list_pi_exec
}

org_reserve() {
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    echo "${SEAT_ORG_RESERVE:-2}"
}

# --- stale active-seat registry self-healing (2026-08-25) -----------------
# The active-seats registry is written by register_active_seat on start and
# cleared by clear_active_seat via `trap EXIT INT TERM` in the wrapper. The
# trap does NOT fire when a worker is SIGKILLed (OOM killer, systemctl -9,
# `systemd-oomd` kill), so a registry entry outlives its unit and then: (1)
# count_active_total() over-counts — the intake sees phantom workers eating
# capacity it could give to real work; (2) pick_seat() sees the phantom on
# the seat and blocks routing to it (cursor cap "reached" by a dead worker,
# devin blocked by a stale rate_limited marker). Live state beats memory:
# the unit table is the source of truth for what is running right now.
#
# Gate: env-guarded so unit tests that stub a scratch HOME (no real user
# session) keep working without a systemctl call. When 0, cap accounting
# uses only the scratch registry: no list-units and no is-active, so a
# host with a full live cap cannot starve pick_seat (fleet-ops#142). The
# installed wrapper defaults to 1.
PI_SEAT_LIB_CHECK_SYSTEMD="${PI_SEAT_LIB_CHECK_SYSTEMD:-1}"

# P15: a unit in `activating` for longer than its own bound is a wedge, not
# a worker. A Type=oneshot worker sits in `activating` for its ENTIRE run
# (systemd reports activating/start from ExecStart to exit — fleet-ops#5141),
# so the honest bound is the unit's own TimeoutStartUSec: exactly the time
# systemd itself allows the start to take. This constant is only the
# FALLBACK, used when systemd reports `infinity`, `0`, or an unparseable
# time span for that unit (_seat_liveness_bound_s). The wrapper watchdog
# (PI_HANG_TIMEOUT_S, default 42 min) normally kills a hung pi long before
# either bound (older wrapper, SIGKILL path, unit timeout race).
PI_SEAT_ACTIVATING_MAX_S="${PI_SEAT_ACTIVATING_MAX_S:-3300}"  # fallback: 55 min > unit 45 min

# fleet-ops#1361: shorter threshold for units stuck in activating without ever
# launching their process (ExecMainStartTimestampMonotonic=0). 5 min is enough
# to detect a unit that will never start its process.
PI_SEAT_ACTIVATING_NO_PROCESS_MAX_S="${PI_SEAT_ACTIVATING_NO_PROCESS_MAX_S:-300}"  # 5 min

# systemd timespan ("45min", "1h 30min", "500ms") -> integer seconds.
# Echoes nothing and returns 1 for "infinity", "", 0, or anything unparseable.
_seat_duration_to_s() {
    local v="${1:-}" total=0 tok n unit
    [[ -n "$v" && "$v" != "infinity" ]] || return 1
    # systemd prints space-separated components; read -ra splits on
    # whitespace without glob-expanding against the caller's cwd.
    local -a toks=()
    read -ra toks <<< "$v"
    for tok in "${toks[@]}"; do
        [[ "$tok" =~ ^([0-9]+)(ms|s|min|h|d|w)$ ]] || return 1
        n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
        case "$unit" in
            ms)  total=$(( total + n / 1000 )) ;;
            s)   total=$(( total + n )) ;;
            min) total=$(( total + n * 60 )) ;;
            h)   total=$(( total + n * 3600 )) ;;
            d)   total=$(( total + n * 86400 )) ;;
            w)   total=$(( total + n * 604800 )) ;;
        esac
    done
    (( total > 0 )) || return 1
    echo "$total"
}

# Liveness bound for an `activating` worker unit, in seconds: the unit's OWN
# TimeoutStartSec when systemd reports a finite one, else the
# PI_SEAT_ACTIVATING_MAX_S fallback (fleet-ops#5141; infinity/0/unparseable).
_seat_liveness_bound_s() {
    local sysunit="$1" raw parsed
    raw=$(systemctl --user show "$sysunit" --property=TimeoutStartUSec --value 2>/dev/null || true)
    parsed=$(_seat_duration_to_s "$raw" 2>/dev/null || true)
    if [[ "$parsed" =~ ^[0-9]+$ ]] && (( parsed > 0 )); then
        echo "$parsed"; return 0
    fi
    echo "${PI_SEAT_ACTIVATING_MAX_S:-3300}"
}

# --- why `activating` is normally LIVE (fleet-ops#83, #993, #1361, #5141) --
# P15 wedge probe: a unit stuck activating past its own bound is a wedged pi
# whose seat registration must be reaped so caps free up. A SIGKILLed wedged
# worker leaves `activating` (systemd -9 leaves the unit start state) — age is
# the only honest signal. This is the fleet-ops#83 blind spot: the probe
# treated every `activating` as live, so a wedged unit held its seat for the
# full 45-minute TimeoutStartSec and starved pick_seat.
#
# fleet-ops#993 (2026-08-27 outage): ActiveEnterTimestampMonotonic is 0 for
# EVERY Type=oneshot unit that is still `activating` (systemd only stamps it
# when the start completes). With a live worker that had run 30+ min that read
# 0 -> age_s = uptime - 0 = 1.4M s > max -> every live seat got reaped, cap
# accounting went blind, and pick_seat piled unbounded workers onto the first
# free seat (the 8-vCPU box saturating at load 87, SustainedLoadHigh alert,
# zero-tools repair failure). Measure age from ExecMainStartTimestampMonotonic
# instead — systemd stamps it when the worker's ExecStart pi process actually
# started, so it is nonzero for every activating oneshot with a live process —
# and treat an unparseable/0 timestamp as live (a young unit that systemd has
# not yet stamped is not wedged).
#
# fleet-ops#1361 (2026-08-29): when ExecMainStartTimestampMonotonic=0 (process
# never started), or when the unit waits between Restart= attempts in
# `activating/auto-restart`, there is no running process to bound, so both
# fail closed at the short PI_SEAT_ACTIVATING_NO_PROCESS_MAX_S threshold.
#
# fleet-ops#5141 (2026-09-10): for Type=oneshot, `activating/start` IS the
# normal running state from ExecStart to exit, so a hardcoded short bound on
# SubState=start reaped every live worker older than 300s (63 reaps in
# watch.log, all `(SubState=start, threshold=300s)`). The bound for a started
# process is the unit's own TimeoutStartSec. See _seat_liveness_bound_s.
#
# True if the registry file's unit is still a live pi worker unit.
# Non-zero (stale) when the unit is dead, missing, or not a pi unit name.
#
# The registry stores the bare instance name (e.g. "pi-issue-fleet-ops-21",
# matching the unit's %i / the active-seats filename), NOT the full unit
# name. The full systemd unit is "pi-issue@<instance>.service" (template
# unit) for issue workers and "pi-packet@<instance>.service" for packet
# workers. Translate here so systemctl queries the real unit.
_seat_registry_unit_live() {
    local f="$1" unit="" sysunit="" state=""
    unit=$(jq -r '.unit // ""' "$f" 2>/dev/null || true)
    [[ -n "$unit" ]] || return 1
    case "$unit" in
        pi-issue-*) sysunit="pi-issue@${unit#pi-issue-}.service" ;;
        pi-packet-*) sysunit="pi-packet@${unit#pi-packet-}.service" ;;
        *) return 1 ;;
    esac
    state=$(systemctl --user is-active "$sysunit" 2>/dev/null || true)
    [[ "$state" == "active" ]] && return 0
    [[ "$state" == "activating" ]] || return 1

    local sub_state exec_main ts bound now_s age_s
    sub_state=$(systemctl --user show "$sysunit" --property=SubState --value 2>/dev/null || true)
    exec_main=$(systemctl --user show "$sysunit" --property=ExecMainStartTimestampMonotonic --value 2>/dev/null || true)

    if [[ "$sub_state" == "auto-restart" ]]; then
        # Waiting between Restart= attempts: no process is running, so the
        # unit's own TimeoutStartSec does not bound it and the seat
        # registration is stale anyway — pi-issue-run re-picks the seat on
        # the next ExecStart. Fail closed at the 300s no-process bound
        # (fleet-ops#1361, #63).
        bound=${PI_SEAT_ACTIVATING_NO_PROCESS_MAX_S:-300}
    elif [[ "$exec_main" =~ ^[0-9]+$ ]] && (( exec_main > 0 )); then
        # SubState=start is the NORMAL state for the whole run of a
        # Type=oneshot worker (systemd reports activating/start from ExecStart
        # to exit), so `start` must never pick a shorter bound. A worker may
        # legitimately run up to the unit's own TimeoutStartSec
        # (fleet-ops#993, #1361, #5141).
        bound=$(_seat_liveness_bound_s "$sysunit")
    else
        # ExecMainStartTimestampMonotonic=0: the process never started.
        # Bound how long the unit has sat in activating (fleet-ops#1361).
        bound=${PI_SEAT_ACTIVATING_NO_PROCESS_MAX_S:-300}
    fi

    if [[ "$exec_main" =~ ^[0-9]+$ ]] && (( exec_main > 0 )); then
        ts=$exec_main
    else
        ts=$(systemctl --user show "$sysunit" --property=ActiveEnterTimestampMonotonic --value 2>/dev/null || true)
    fi
    # No usable timestamp (test stub, older systemd, young unit): fail live,
    # as before.
    [[ "$ts" =~ ^[0-9]+$ ]] && (( ts > 0 )) || return 0

    now_s=$(awk '{print int($1)}' /proc/uptime)
    age_s=$(( now_s - ts / 1000000 ))
    if (( age_s > bound )); then
        seat_log "seat registry: unit $sysunit stuck activating ${age_s}s (SubState=${sub_state:-unknown}, threshold=${bound}s) — wedged pi, reaping seat"
        return 1
    fi
    return 0
}

# True if a unit is in `activating/auto-restart` — the systemd sub-state
# for a worker that has crashed and is waiting for its next RestartSec
# window. fleet-ops#63: a unit in this state holds its claim branch,
# its agent-in-progress label, and its seat in the cap accounting; it
# does no work. The heartbeat publishes this as DEGRADED; the cap
# accounting treats it as still-occupying so pick_seat does not route a
# new worker onto a seat that might come back.
#
# Pure observability: callers that need to distinguish busy vs degraded
# use this. Cap enforcement (pick_seat, count_active_total) deliberately
# does NOT — the seat IS held until the unit gives up.
unit_is_degraded() {
    local sysunit="$1"
    [[ -n "$sysunit" ]] || return 1
    local sub state
    state=$(systemctl --user is-active "$sysunit" 2>/dev/null || true)
    sub=$(systemctl --user show "$sysunit" --property=SubState --value 2>/dev/null || echo unknown)
    [[ "$state" == "activating" && "$sub" == "auto-restart" ]]
}

# Reap one stale registry file (unit dead). Logged; best-effort.
_seat_reap_stale_registry() {
    local f="$1" unit
    unit=$(jq -r '.unit // "unknown"' "$f" 2>/dev/null || true)
    seat_log "seat registry: reaping stale entry $f (unit $unit not active)"
    rm -f "$f" 2>/dev/null || true
}

# Emit only the LIVE active-seats registry files (skip + reap stale).
# Uses PI_SEAT_LIB_CHECK_SYSTEMD=0 to disable the systemctl liveness probe
# (tests, explicit seeding). With the probe enabled, a file whose unit is
# dead is deleted here and excluded from all counts and cap checks.
_seat_live_registry_files() {
    local f
    for f in "$ACTIVE_SEATS_DIR"/pi-*.json; do
        [[ -f "$f" ]] || continue
        if (( PI_SEAT_LIB_CHECK_SYSTEMD )); then
            if ! _seat_registry_unit_live "$f"; then
                _seat_reap_stale_registry "$f"
                continue
            fi
        fi
        echo "$f"
    done
}

# Build the per-pick_seat active-seats count cache (fleet-ops#1297).
# Reads _seat_live_registry_files ONCE (jq per file) and _seat_list_pi_exec
# ONCE (systemctl show per unit), pre-computing the per-provider, per-seat,
# issue and org counts that count_active_on_provider / count_active_on_seat /
# count_active_issue / count_active_org consult below. Without this, each of
# those functions re-read the registry + legacy unit list on every call, and
# the two per-seat functions are called once per non-excluded seat in the
# pick_seat loop — the ~4.4s/call cost that drove load1=148. Called once at
# the start of pick_seat; _PICK_ACTIVE_CACHE_BUILT is reset there so a
# multi-call process (tests) rebuilds per pass.
_build_pick_active_cache() {
    _PICK_REG_PROVIDER_COUNT=()
    _PICK_REG_SEAT_COUNT=()
    _PICK_LEG_PROVIDER_COUNT=()
    _PICK_LEG_SEAT_COUNT=()
    _PICK_REG_SEEN_BASE=()
    _PICK_REG_ISSUE_N=0
    _PICK_REG_ORG_N=0
    _PICK_LEG_ISSUE_N=0
    _PICK_LEG_ORG_N=0

    local f p m unit base
    # Registry pass: ONE jq per file (was: jq per file PER count function).
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        IFS=$'\x1f'$'\n' read -r p m unit < <(
            jq -r '[(.provider//""),(.model//""),(.unit//"")] | join("\u001f")' "$f" 2>/dev/null || true
        )
        [[ -n "$p" ]] || continue
        base="${f##*/}"; base="${base%.json}"
        _PICK_REG_PROVIDER_COUNT[$p]=$(( ${_PICK_REG_PROVIDER_COUNT[$p]:-0} + 1 ))
        _PICK_REG_SEAT_COUNT[$p/$m]=$(( ${_PICK_REG_SEAT_COUNT[$p/$m]:-0} + 1 ))
        _PICK_REG_SEEN_BASE[$base]=1
        case "$base" in
            pi-packet-*) _PICK_REG_ORG_N=$((_PICK_REG_ORG_N + 1)) ;;
            *)           _PICK_REG_ISSUE_N=$((_PICK_REG_ISSUE_N + 1)) ;;
        esac
    done < <(_seat_live_registry_files)

    # Legacy pass: ONE systemctl show per unit (was: per count function).
    # _seat_list_unit == _seat_list_org_unit == _seat_list_pi_exec, so a
    # single read covers both count_active_issue and count_active_org.
    local u cmd instance
    declare -A _leg_seen=()
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        cmd=$(systemctl --user show "$u" --property=ExecStart --value 2>/dev/null || true)
        _parse_exec_provider_model "$cmd"
        # count_active_on_provider / count_active_on_seat legacy: NO dedup
        # against the registry (matches the uncached functions exactly).
        if [[ -n "$_exec_p" ]]; then
            _PICK_LEG_PROVIDER_COUNT[$_exec_p]=$(( ${_PICK_LEG_PROVIDER_COUNT[$_exec_p]:-0} + 1 ))
            [[ -n "$_exec_m" ]] && _PICK_LEG_SEAT_COUNT[$_exec_p/$_exec_m]=$(( ${_PICK_LEG_SEAT_COUNT[$_exec_p/$_exec_m]:-0} + 1 ))
        fi
        # count_active_issue legacy: pi-issue@* NOT already in the registry.
        case "$u" in
            pi-issue@*.service)
                instance="${u#pi-issue@}"; instance="${instance%.service}"
                [[ -f "$ACTIVE_SEATS_DIR/pi-issue-${instance}.json" ]] && continue
                _PICK_LEG_ISSUE_N=$((_PICK_LEG_ISSUE_N + 1))
                continue
                ;;
        esac
        # count_active_org legacy: non-pi-issue units, deduped against the
        # registry (pi-packet@* by seen-base + file check) and within the
        # loop (_leg_seen). Matches count_active_org's exact dedup logic.
        [[ -n "${_leg_seen[$u]:-}" ]] && continue
        case "$u" in
            pi-packet@*.service)
                instance="${u#pi-packet@}"; instance="${instance%.service}"
                [[ -n "${_PICK_REG_SEEN_BASE[pi-packet-${instance}]:-}" ]] && continue
                [[ -f "$ACTIVE_SEATS_DIR/pi-packet-${instance}.json" ]] && continue
                ;;
        esac
        _leg_seen[$u]=1
        _PICK_LEG_ORG_N=$((_PICK_LEG_ORG_N + 1))
    done < <(_seat_list_pi_exec)

    _PICK_ACTIVE_CACHE_BUILT=1
}

count_active_on_seat() {
    local prov="$1" mdl="$2"
    # fleet-ops#1297: O(1) lookup when the per-pick_seat cache is built.
    if (( _PICK_ACTIVE_CACHE_BUILT )); then
        echo $(( ${_PICK_REG_SEAT_COUNT[$prov/$mdl]:-0} + ${_PICK_LEG_SEAT_COUNT[$prov/$mdl]:-0} ))
        return
    fi
    local n=0
    # State-dir based (new path)
    local f fp fm
    while IFS= read -r f; do
        read -r fp fm < <(jq -r '[.provider // "", .model // ""] | @tsv' "$f" 2>/dev/null) || continue
        [[ "$fp" == "$prov" && "$fm" == "$mdl" ]] && n=$((n+1))
    done < <(_seat_live_registry_files)
    # Legacy grep (pi-issue-* / pi-packet-* with hardcoded --provider/--model in ExecStart)
    local u cmd
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        cmd=$(systemctl --user show "$u" --property=ExecStart --value 2>/dev/null || true)
        _parse_exec_provider_model "$cmd"
        if [[ -n "$_exec_p" && -n "$_exec_m" && "$_exec_p" == "$prov" && "$_exec_m" == "$mdl" ]]; then
            n=$((n+1))
        fi
    done < <(_seat_list_unit)
    echo "$n"
}

# Count currently active workers on a given provider (sum across models).
count_active_on_provider() {
    local prov="$1"
    # fleet-ops#1297: O(1) lookup when the per-pick_seat cache is built.
    if (( _PICK_ACTIVE_CACHE_BUILT )); then
        echo $(( ${_PICK_REG_PROVIDER_COUNT[$prov]:-0} + ${_PICK_LEG_PROVIDER_COUNT[$prov]:-0} ))
        return
    fi
    local n=0
    # State-dir based (new path) — sum all models for the provider
    local f fp
    while IFS= read -r f; do
        read -r fp _ < <(jq -r '[.provider // "", .model // ""] | @tsv' "$f" 2>/dev/null) || continue
        [[ "$fp" == "$prov" ]] && n=$((n+1))
    done < <(_seat_live_registry_files)
    # Legacy grep
    local u cmd
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        cmd=$(systemctl --user show "$u" --property=ExecStart --value 2>/dev/null || true)
        _parse_exec_provider_model "$cmd"
        if [[ -n "$_exec_p" && "$_exec_p" == "$prov" ]]; then
            n=$((n+1))
        fi
    done < <(_seat_list_unit)
    echo "$n"
}

# Issue-work units (pi-issue-*). These are what intake spends slots on.
count_active_issue() {
    # fleet-ops#1297: O(1) lookup when the per-pick_seat cache is built.
    if (( _PICK_ACTIVE_CACHE_BUILT )); then
        echo $(( _PICK_REG_ISSUE_N + _PICK_LEG_ISSUE_N ))
        return
    fi
    local n=0 f base u cmd instance
    while IFS= read -r f; do
        base=$(basename "$f" .json)
        case "$base" in
            pi-packet-*) continue ;;
            *) n=$((n+1)) ;;
        esac
    done < <(_seat_live_registry_files)
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        case "$u" in
            pi-issue@*.service)
                instance="${u#pi-issue@}"
                instance="${instance%.service}"
                [[ -f "$ACTIVE_SEATS_DIR/pi-issue-${instance}.json" ]] && continue
                ;;
            *) continue ;;
        esac
        cmd=$(systemctl --user show "$u" --property=ExecStart --value 2>/dev/null || true)
        _parse_exec_provider_model "$cmd"
        if [[ -n "$_exec_p" && -n "$_exec_m" ]]; then
            n=$((n+1))
        fi
    done < <(_seat_list_unit)
    echo "$n"
}

# Org/repair packets: pi-packet registry and any active/activating service
# whose ExecStart contains "pi --print" (pi-packet@, alert-repair-*,
# pi-job-*, and ad-hoc pi-systemd-run units with odd names).
# fleet-ops#1155: enumerated by ExecStart content, not unit-name patterns.
count_active_org() {
    # fleet-ops#1297: O(1) lookup when the per-pick_seat cache is built.
    if (( _PICK_ACTIVE_CACHE_BUILT )); then
        echo $(( _PICK_REG_ORG_N + _PICK_LEG_ORG_N ))
        return
    fi
    local n=0 f base u instance
    declare -A seen=()
    while IFS= read -r f; do
        base=$(basename "$f" .json)
        case "$base" in
            pi-packet-*)
                n=$((n+1))
                seen["$base"]=1
                ;;
        esac
    done < <(_seat_live_registry_files)
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        [[ -n "${seen[$u]:-}" ]] && continue
        # Issue workers are counted by count_active_issue, not here. This
        # only guards against a mis-classified legacy pi-issue@ with a
        # direct "pi --print" ExecStart; the new ExecStart enumerator would
        # otherwise count it as org (fleet-ops#1155).
        case "$u" in
            pi-issue@*.service) continue ;;
            pi-packet@*.service)
                instance="${u#pi-packet@}"
                instance="${instance%.service}"
                [[ -n "${seen[pi-packet-${instance}]:-}" ]] && continue
                [[ -f "$ACTIVE_SEATS_DIR/pi-packet-${instance}.json" ]] && continue
                ;;
        esac
        seen["$u"]=1
        n=$((n+1))
    done < <(_seat_list_org_unit)
    echo "$n"
}

# Intake capacity counter: issue workers at full value, org/repair
# packets against org_reserve (default 2). Four org packets cannot
# fill a 4-slot RAM cap and skip every ready issue.
count_active_total() {
    local issue org reserve charge
    issue=$(count_active_issue)
    org=$(count_active_org)
    reserve=$(org_reserve)
    charge=$org
    (( charge > reserve )) && charge=$reserve
    echo $(( issue + charge ))
}

# Count active pi-issue workers whose packet difficulty is heavy|keystone.
# The RAM governor charges these at 1.0 GB (2x the light 0.5 GB, fleet-ops#3281),
# so the intake slot computation and AIMD probe admission weight them double.
# Reads the packet's `difficulty:` line (written by intake) for each active
# unit; a missing/unreadable packet is treated as light (fail-open). Org/
# repair packets (pi-packet-*) are never heavy and are not counted here.
count_active_heavy() {
    local n=0 f unit inst pkt diff
    while IFS= read -r f; do
        unit=$(jq -r '.unit // ""' "$f" 2>/dev/null || true)
        [[ "$unit" == pi-issue-* ]] || continue
        inst="${unit#pi-issue-}"
        pkt="$PI_ISSUES_DIR/${inst}.in"
        diff=$(packet_difficulty "$pkt" 2>/dev/null || true)
        [[ "$diff" == "heavy" || "$diff" == "keystone" ]] && n=$((n+1))
    done < <(_seat_live_registry_files)
    # Legacy ExecStart path: pi-issue@<inst>.service units not already in the
    # registry (dedup matches count_active_issue).
    local u
    while IFS= read -r u; do
        [[ "$u" == pi-issue@*.service ]] || continue
        inst="${u#pi-issue@}"; inst="${inst%.service}"
        [[ -f "$ACTIVE_SEATS_DIR/pi-issue-${inst}.json" ]] && continue
        pkt="$PI_ISSUES_DIR/${inst}.in"
        diff=$(packet_difficulty "$pkt" 2>/dev/null || true)
        [[ "$diff" == "heavy" || "$diff" == "keystone" ]] && n=$((n+1))
    done < <(_seat_list_pi_exec)
    echo "$n"
}

# Total RAM charge of active workers in light-worker units (1 unit = the
# fallback ram_gb_per_worker). Each issue worker is charged its repo's
# MemoryHigh (heavy|keystone at 1.0 GB, fleet-ops#3495) divided by the
# fallback. 0509/fleet-ops no longer set MemoryHigh after fleet-ops#3930
# dropped the throttle band, so they fall back to the flat 1 unit each.
# Org/repair packets stay at 1x (capped at org_reserve).
# This is what the RAM governor's cap is compared against so heavy/browser
# workers consume their real share of MemAvailable.
active_ram_charge() {
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    local total=0 f unit inst pkt repo diff gb fallback
    fallback="$SEAT_RAM_GB_PER_WORKER"
    # Registry pass (new path).
    while IFS= read -r f; do
        unit=$(jq -r '.unit // ""' "$f" 2>/dev/null || true)
        [[ "$unit" == pi-issue-* ]] || continue
        inst="${unit#pi-issue-}"
        pkt="$PI_ISSUES_DIR/${inst}.in"
        repo=$(packet_repo "$pkt" 2>/dev/null || true)
        diff=$(packet_difficulty "$pkt" 2>/dev/null || true)
        gb=$(ram_charge_gb_for "$repo" "$diff")
        total=$(awk -v t="$total" -v g="$gb" -v f="$fallback" 'BEGIN{ printf "%.3f", t + g/f }')
    done < <(_seat_live_registry_files)
    # Legacy ExecStart pass (dedup matches count_active_issue).
    local u
    while IFS= read -r u; do
        [[ "$u" == pi-issue@*.service ]] || continue
        inst="${u#pi-issue@}"; inst="${inst%.service}"
        [[ -f "$ACTIVE_SEATS_DIR/pi-issue-${inst}.json" ]] && continue
        pkt="$PI_ISSUES_DIR/${inst}.in"
        repo=$(packet_repo "$pkt" 2>/dev/null || true)
        diff=$(packet_difficulty "$pkt" 2>/dev/null || true)
        gb=$(ram_charge_gb_for "$repo" "$diff")
        total=$(awk -v t="$total" -v g="$gb" -v f="$fallback" 'BEGIN{ printf "%.3f", t + g/f }')
    done < <(_seat_list_pi_exec)
    # Org/repair packets at 1x, capped at org_reserve.
    local org reserve
    org=$(count_active_org)
    reserve=$(org_reserve)
    (( org > reserve )) && org=$reserve
    total=$(awk -v t="$total" -v o="$org" 'BEGIN{ printf "%.3f", t + o }')
    echo "$total"
}

# Count workers in `activating/auto-restart` across all fleet worker units.
# fleet-ops#63: these are crash-loopers — the unit holds its seat and
# its claim branch but does no work. The heartbeat publishes this as
# DEGRADED. Cap enforcement (count_active_total) intentionally treats
# these as still-occupying; this counter is observability only.
#
# Like count_active_total, this counts BOTH the active-seats registry
# (new path) AND legacy ExecStart-grep units. A degraded registry entry
# (unit dead) is reaped by _seat_live_registry_files; the only thing
# this loop has to filter is SubState=auto-restart.
count_degraded_total() {
    local n=0
    local f unit sysunit
    while IFS= read -r f; do
        unit=$(jq -r '.unit // ""' "$f" 2>/dev/null || true)
        [[ -n "$unit" ]] || continue
        case "$unit" in
            pi-issue-*)  sysunit="pi-issue@${unit#pi-issue-}.service" ;;
            pi-packet-*) sysunit="pi-packet@${unit#pi-packet-}.service" ;;
            *) continue ;;
        esac
        if unit_is_degraded "$sysunit"; then
            n=$((n+1))
        fi
    done < <(_seat_live_registry_files)
    # Legacy grep path: scan active/activating worker units by ExecStart
    # content and filter by SubState=auto-restart. fleet-ops#1155: never
    # rely on unit-name patterns; any odd-named pi --print unit can crash-loop.
    local u sub state
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        state=$(systemctl --user is-active "$u" 2>/dev/null || true)
        [[ "$state" == "activating" ]] || continue
        sub=$(systemctl --user show "$u" --property=SubState --value 2>/dev/null || echo unknown)
        if [[ "$sub" == "auto-restart" ]]; then
            # Skip units already counted via the registry (matched by
            # their instance name).
            local instance="${u#pi-issue@}"
            instance="${instance%.service}"
            [[ -f "$ACTIVE_SEATS_DIR/pi-issue-${instance}.json" ]] && continue
            local instance2="${u#pi-packet@}"
            instance2="${instance2%.service}"
            [[ -f "$ACTIVE_SEATS_DIR/pi-packet-${instance2}.json" ]] && continue
            n=$((n+1))
        fi
    done < <(_seat_list_unit)
    echo "$n"
}

# --- prepaid weekly pacing + alternate-never-stack (fleet-ops#387) ----------
# Local counter of picks this ISO week, per provider. Not the provider's
# real meter — an estimate so a wall elsewhere cannot drain one prepaid
# seat to zero overnight. When weekly_budget is unset, pacing is a no-op
# and alternation still spreads the load.
_prepaid_iso_week() { date -u +%G-W%V; }

_prepaid_usage_path() {
    echo "$STATE_DIR/prepaid-usage/${1}.json"
}

_prepaid_usage() {
    local p="$1" f week count
    week=$(_prepaid_iso_week)
    f=$(_prepaid_usage_path "$p")
    [[ -f "$f" ]] || { echo 0; return; }
    local stored
    stored=$(jq -r '.week // ""' "$f" 2>/dev/null || true)
    [[ "$stored" == "$week" ]] || { echo 0; return; }
    count=$(jq -r '.count // 0' "$f" 2>/dev/null || echo 0)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    echo "$count"
}

_record_prepaid_pick() {
    local p="$1" f week count tmp today
    week=$(_prepaid_iso_week)
    f=$(_prepaid_usage_path "$p")
    mkdir -p "$STATE_DIR/prepaid-usage"
    count=$(_prepaid_usage "$p")
    count=$((count + 1))
    tmp="$f.tmp.$$"; today=$(date -u +%Y-%m-%d)
    # fleet-ops#4453: the counter is also the provider's daily spend meter.
    # usd_today is token-derived (per-message usage tokens x the provider's
    # own rate card) so an expiring-daily-allowance seat (Pareto Pass) can be
    # benchmarked against its $/day budget even though usage.cost reports 0.
    # Preserve the one-time 429-after-budget / 200-after-reset log flags and
    # their dates; when today has spend on a provider whose 429-after-budget
    # was logged on a PRIOR day, record the first 200-after-reset (the daily
    # allowance reset and the seat is back — learning the undocumented reset
    # hour, rule 2).
    local usd flags429="false" flags200="false" f9date="" f2date=""
    local cur_src="" cur_cycle="" cur_lane=""
    usd=$(_provider_daily_spend_usd_tokens "$p")
    [[ "$usd" =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]] || usd=0
    # fleet-ops#4621: cursor-cli sessions record 0 usage tokens and there is
    # no cursor cost card, so the token meter is structurally $0. The real
    # spend is Cursor GetCurrentPeriodUsage included-API-bucket 24h delta,
    # written into this same usd_today field by fleet-prepaid-util-canary.
    # A pick must not clobber a vendor figure with the token 0; keep the
    # existing usd_today when it is already a vendor number or UNAVAILABLE
    # label, and carry the provenance fields (source, cycle figure, billing
    # lane) so the judge can tell a vendor number from a token 0. Pareto
    # Pass and every other provider keep the token path.
    if [[ "$p" == "cursor" && -f "$f" ]]; then
        local _kept
        _kept=$(jq -r '.usd_today // empty' "$f" 2>/dev/null || true)
        if [[ -n "$_kept" && "$_kept" != "0" && "$_kept" != "0.000000" ]]; then
            usd="$_kept"
            cur_src=$(jq -r '.usd_today_source // empty' "$f" 2>/dev/null || true)
            cur_cycle=$(jq -r '.cursor_api_cycle_usd // empty' "$f" 2>/dev/null || true)
            cur_lane=$(jq -r '.billing_lane // empty' "$f" 2>/dev/null || true)
        fi
    fi
    # fleet-ops#4453 accept: usd_today never exceeds the declared daily budget.
    if [[ -n "${SEAT_PROVIDER_DAILY_BUDGET_USD[$p]:-}" ]]; then
        local cap_usd="${SEAT_PROVIDER_DAILY_BUDGET_USD[$p]}"
        usd=$(awk -v u="$usd" -v b="$cap_usd" 'BEGIN{printf "%.6f", (u+0>b+0)?b+0:u+0}')
    fi
    if [[ -f "$f" ]]; then
        flags429=$(jq -r '.provider_daily_logged_429 // false' "$f" 2>/dev/null || echo false)
        flags200=$(jq -r '.provider_daily_logged_200 // false' "$f" 2>/dev/null || echo false)
        f9date=$(jq -r '.provider_daily_logged_429_date // ""' "$f" 2>/dev/null || true)
        f2date=$(jq -r '.provider_daily_logged_200_date // ""' "$f" 2>/dev/null || true)
    fi
    # First 200-after-reset: spend today on a provider with a PRIOR-day 429.
    if [[ "$flags429" == "true" && "$flags200" != "true" && -n "$f9date" \
          && "$f9date" != "$today" && "$(awk -v u="$usd" 'BEGIN{print (u>0)?1:0}')" == "1" ]]; then
        flags200="true"; f2date="$today"
        seat_log "provider-daily-budget: first 200-after-reset on $p ($today, prior 429 on $f9date) — daily allowance reset observed"
    fi
    if [[ "$flags200" != "true" ]]; then f2date=""; fi
    if [[ "$flags429" != "true" ]]; then f9date=""; fi
    [[ "$flags429" == "true" || "$f9date" != "" ]] || f9date=""
    jq -nc --arg w "$week" --argjson c "$count" --arg ud "$usd" \
        --argjson f9 "$([[ "$flags429" == "true" ]] && echo true || echo false)" \
        --argjson f2 "$([[ "$flags200" == "true" ]] && echo true || echo false)" \
        --arg d9 "${f9date:-}" --arg d2 "${f2date:-}" \
        --arg src "${cur_src:-}" --arg cy "${cur_cycle:-}" --arg lane "${cur_lane:-}" \
        '{week:$w,count:$c,usd_today:$ud,provider_daily_logged_429:$f9,provider_daily_logged_429_date:$d9,provider_daily_logged_200:$f2,provider_daily_logged_200_date:$d2,
          usd_today_source:$src,cursor_api_cycle_usd:$cy,billing_lane:$lane}' >"$tmp" 2>/dev/null || {
        rm -f "$tmp"
        return 0
    }
    mv "$tmp" "$f"
}

# --- per-session USD spend into the prepaid-usage counter (fleet-ops#4459) ---
# At run end pi-issue-run records the session's USD (session usage tokens x the
# seat rate card) into the same prepaid-usage/<provider>.json counter that
# pacing reads. The counter file grows a `usd` field: {week,count,usd}. A seat
# with no rate card (and no flat plan) records usd=UNAVAILABLE:<why> — never a
# fabricated $0 (fleet-ops#4459 required). remote_agent seats (Devin) record
# usd=UNAVAILABLE:remote (their local session carries no meterable usage; the
# flat prepaid share is attributed separately, fleet-ops#4459 Do.2).
_session_usd_from_usage() {
    # $1=rate input $2=rate output $3=rate cached (USD per 1M); $4=input tokens
    # $5=output tokens $6=cacheRead tokens (int counts)
    awk -v ri="$1" -v ro="$2" -v rc="$3" -v it="${4:-0}" -v ot="${5:-0}" -v ct="${6:-0}" \
        'BEGIN { printf "%.6f\n", (it*ri + ot*ro + ct*rc)/1000000.0 }'
}

_record_prepaid_usd() {
    # $1=provider $2=session jsonl path. Reads the rate card from seat-caps and
    # sums usage tokens over the session, then merges usd into the counter.
    local p="$1" sess="$2" f week tmp
    [[ -f "$sess" ]] || return 0
    [[ -f "$SEAT_CAPS_JSON" ]] || { seat_log "prepaid-usd: no seat-caps at $SEAT_CAPS_JSON" >&2; return 0; }
    week=$(_prepaid_iso_week)
    f=$(_prepaid_usage_path "$p")
    mkdir -p "$STATE_DIR/prepaid-usage"
    local rate_in rate_out rate_cache flat
    rate_in=$(jq -r ".providers[\"$p\"].usd_per_1m_input // 0" "$SEAT_CAPS_JSON" 2>/dev/null || echo 0)
    rate_out=$(jq -r ".providers[\"$p\"].usd_per_1m_output // 0" "$SEAT_CAPS_JSON" 2>/dev/null || echo 0)
    rate_cache=$(jq -r ".providers[\"$p\"].usd_per_1m_cached // 0" "$SEAT_CAPS_JSON" 2>/dev/null || echo 0)
    flat=$(jq -r ".providers[\"$p\"].flat_usd_per_month // 0" "$SEAT_CAPS_JSON" 2>/dev/null || echo 0)
    remote=$(jq -r ".providers[\"$p\"].remote_agent // false" "$SEAT_CAPS_JSON" 2>/dev/null || echo false)
    local in_tok out_tok cache_tok usd prev_count
    in_tok=$(jq -s '[.[] | .message.usage.input? // 0] | add // 0' "$sess" 2>/dev/null || echo 0)
    out_tok=$(jq -s '[.[] | .message.usage.output? // 0] | add // 0' "$sess" 2>/dev/null || echo 0)
    cache_tok=$(jq -s '[.[] | .message.usage.cacheRead? // 0] | add // 0' "$sess" 2>/dev/null || echo 0)
    if [[ "$rate_in" == "0" && "$rate_out" == "0" && "$rate_cache" == "0" && "$flat" == "0" ]]; then
        # fleet-ops#4459 Do.2: remote-agent seats (Devin) leave no local usage
        # to meter; attribute the flat prepaid share only. Report UNAVAILABLE:remote
        # (never a fabricated $0; flat share is summed from flat_usd_per_month).
        if [[ "$remote" == "true" ]]; then
            usd="UNAVAILABLE:remote"
        else
            usd="UNAVAILABLE:no-rate-card"
        fi
    else
        usd=$(_session_usd_from_usage "$rate_in" "$rate_out" "$rate_cache" "$in_tok" "$out_tok" "$cache_tok")
    fi
    prev_count=$(_prepaid_usage "$p")
    tmp="$f.tmp.$$";
    if [[ "$usd" == UNAVAILABLE:* ]]; then
        jq -nc --arg w "$week" --argjson c "$prev_count" --arg u "$usd" \
            '{week:$w,count:$c,usd:$u}' >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    else
        jq -nc --arg w "$week" --argjson c "$prev_count" --argjson u "$usd" \
            '{week:$w,count:$c,usd:$u}' >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    fi
    mv "$tmp" "$f"
}

# Return 0 if this prepaid provider is over the weekly pace threshold.
_prepaid_paced() {
    local p="$1"
    local window="${SEAT_PROVIDER_QUOTA_WINDOW[$p]:-}"
    local budget="${SEAT_PROVIDER_WEEKLY_BUDGET[$p]:-0}"
    [[ "$window" == "weekly" ]] || return 1
    [[ "$budget" =~ ^[0-9]+$ ]] || return 1
    (( budget > 0 )) || return 1
    local usage thresh
    usage=$(_prepaid_usage "$p")
    thresh=$(( budget * SEAT_PACE_PCT / 100 ))
    (( usage >= thresh ))
}

# fleet-ops#4467: elapsed fraction of the current prepaid window (0..1).
# weekly   -> fraction of the ISO week elapsed since Monday 00:00 UTC
# monthly  -> fraction of the calendar month elapsed
# anything else / unparseable -> echoes 0 (no window -> no floor).
_prepaid_elapsed_fraction() {
    local p="$1" window dow hour min sec sod
    window="${SEAT_PROVIDER_QUOTA_WINDOW[$p]:-}"
    case "$window" in
        weekly)
            dow=$(date -u +%u)
            hour=$(date -u +%H)
            min=$(date -u +%M)
            sec=$(date -u +%S)
            sod=$(( 10#$hour * 3600 + 10#$min * 60 + 10#$sec ))
            awk -v d="$dow" -v s="$sod" 'BEGIN{printf "%.6f", ((d-1)*86400 + s) / 604800}'
            ;;
        monthly)
            awk -v d="$(date -u +%d)" 'BEGIN{printf "%.6f", (d-1) / 31}'
            ;;
        *) echo 0 ;;
    esac
}

# fleet-ops#4467: expiring prepaid seats (a reset window + a positive session
# target) lapse unused while devin+ollama absorb the fleet. Return 0 when this
# provider is an EXPIRING seat that is BEHIND PACE: its session meter for the
# current window is below the pace that `elapsed_fraction` of the window
# implies against its weekly_budget target. Such seats are picked FIRST,
# round-robin, so prepaid allowance does not roll over burned.
#
# meter  = the local prepaid-usage counter (_prepaid_usage, sessions this
#          ISO week). The dashboard scrape (#4232) / 7-day ledger are the
#          issue's richer meters; this is the counter seat-lib already keeps.
# pace   = budget * elapsed_fraction_of_window  (what the seat SHOULD have
#          used by now to be on track to burn its window fully).
# Flat non-expiring balances (no quota_window) and expiring seats with no
# positive target are never behind pace (unaffected).
_expiring_seat_behind_pace() {
    local p="$1" window budget
    window="${SEAT_PROVIDER_QUOTA_WINDOW[$p]:-}"
    [[ "$window" == "weekly" || "$window" == "monthly" ]] || return 1
    budget="${SEAT_PROVIDER_WEEKLY_BUDGET[$p]:-0}"
    [[ "$budget" =~ ^[0-9]+$ ]] || return 1
    (( budget > 0 )) || return 1
    local usage pace
    usage=$(_prepaid_usage "$p")
    pace=$(_prepaid_elapsed_fraction "$p")
    awk -v u="$usage" -v b="$budget" -v f="$pace" 'BEGIN{ exit (u >= b*f ? 1 : 0) }'
}

# fleet-ops#4467: assemble the list of expiring prepaid seats currently behind
# pace, and round-robin pick ONE (persisted index) so behind-pace seats are
# tried in rotation rather than the first one being drained. Echoes the picked
# "provider\tmodel" seat or nothing (no behind-pace expiring seat).
_pick_expiring_floor_seat() {
    local -a behind=()
    local fm p m
    for fm in ${prepaid_seats[@]+"${prepaid_seats[@]}"}; do
        [[ -n "$fm" ]] || continue
        p="${fm%%$'\t'*}"
        m="${fm#*$'\t'}"
        if _expiring_seat_behind_pace "$p"; then
            behind+=("$p"$'\t'"$m")
        fi
    done
    # fleet-ops#4507: an `if` whose condition is false and which has no else
    # branch exits 0, so without this explicit `return 1` the function
    # SUCCEEDS with empty stdout whenever no seat is behind pace — the call
    # site then "picks" the empty seat "/" and records a phantom prepaid use.
    (( ${#behind[@]} > 0 )) || return 1
    _rr_pick "$STATE_DIR/prepaid-floor-rr.idx" "${behind[@]}"
}

# Re-order a seat list (provider\tmodel entries) by a provider-order string.
_order_seats_by() {
    local order="$1"
    shift
    local -a src=("$@")
    local -a ordered=()
    local fprov fm in_ordered x
    for fprov in $order; do
        for fm in "${src[@]}"; do
            if [[ "$fm" == "$fprov"$'\t'* ]]; then
                ordered+=("$fm")
            fi
        done
    done
    for fm in "${src[@]}"; do
        in_ordered=0
        for x in ${ordered[@]+"${ordered[@]}"}; do
            [[ "$x" == "$fm" ]] && in_ordered=1 && break
        done
        (( in_ordered )) || ordered+=("$fm")
    done
    if (( ${#ordered[@]} > 0 )); then
        printf '%s\n' "${ordered[@]}"
    fi
}

# Round-robin pick from a seat list. Persists the index in STATE_DIR so
# successive pick_seat calls alternate instead of stacking the first seat.
_rr_pick() {
    local idx_file="$1"
    shift
    local -a seats=("$@")
    local n=${#seats[@]}
    (( n > 0 )) || return 1
    local idx=0
    if [[ -f "$idx_file" ]]; then
        idx=$(cat "$idx_file" 2>/dev/null || echo 0)
        [[ "$idx" =~ ^[0-9]+$ ]] || idx=0
    fi
    local pick=$(( idx % n ))
    printf '%s\n' "${seats[$pick]}"
    mkdir -p "$STATE_DIR"
    echo $(( idx + 1 )) >"$idx_file"
}

# Pre-compute the set of "definitively excluded" seats for the current
# cap-map + ledger state, so the per-seat selection loop does not re-log
# the same cap=0 / seat_dead line on every pass (fleet-ops#1449).
#
# Without this, pick_seat emits one log line per cap=0 / dead seat per
# call, and pick_seat runs many times per second on the worker intake
# loop. At 5 calls/sec and 6 cap=0 providers, that is ~30 cap=0 lines
# per second per worker, and the heartbeat's watch.log grep rolls them
# up to at_capacity_events_last_2h (4492 in the 2h window on
# 2026-08-28, 3936 in the previous window).
#
# Building the set is cheap: the cap map is already loaded into
# SEAT_PROVIDER_CAP/SEAT_MODEL_CAP, models.json is a small JSON, and
# the ledger is a directory listing. We do this once per pick_seat
# call and emit one summary line at the end, not N per-seat lines.
#
# Caching: the cap-map path is stable for the lifetime of the process
# (load_seat_caps only re-reads on explicit call). The ledger path may
# change as seat-health.ts writes new entries. We cache the COMBINED set
# keyed on (mtime of the ledger dir's newest file + cap map path), and
# re-build only when the key changes. This keeps per-call cost O(1) on
# the common path (no dead-set changes) and O(ledger) only on the
# transition.
#
# Args: _EXCLUDED_REASON_OUT _EXCLUDED_LIST_OUT
#   Sets two caller-declared associative arrays:
#     _EXCLUDED_REASON_OUT["provider/model"] = "cap=0:provider" | "cap=0:model" | "dead"
#     _EXCLUDED_LIST_OUT["provider/model"]   = 1
#   plus a stdout-derived count via the return value (the number of
#   excluded seats, written to stdout as a single integer).
# Side effects: none on disk; reads the ledger directory only.
declare -A _EXCLUDED_CACHE_ER=()
declare -A _EXCLUDED_CACHE_EL=()
_EXCLUDED_CACHE_KEY=""
_build_excluded_set() {
    local -n _er=$1 _el=$2
    _er=()
    _el=()
    local p m cap reason

    # Cache key: cap map path + newest ledger mtime. If the cap map
    # changes (load_seat_caps re-run) or any ledger file is rewritten,
    # the key changes and the cache is rebuilt. Within a stable
    # process (the common case), this is a single stat call.
    local _newest=0 _f _mtime _cur_key
    if [[ -d "$LEDGER_DIR" ]]; then
        while IFS= read -r _f; do
            [[ -f "$_f" ]] || continue
            _mtime=$(stat -c %Y "$_f" 2>/dev/null || echo 0)
            (( _mtime > _newest )) && _newest=$_mtime
        done < <(find "$LEDGER_DIR" -maxdepth 1 -type f -name '*__*.json' 2>/dev/null || true)
    fi
    _cur_key="${SEAT_CAPS_JSON}|${_newest}"
    if [[ "$_cur_key" == "$_EXCLUDED_CACHE_KEY" && ${#_EXCLUDED_CACHE_ER[@]} -gt 0 ]]; then
        # Cache hit — copy into caller's arrays.
        local _k
        for _k in "${!_EXCLUDED_CACHE_ER[@]}"; do
            _er["$_k"]="${_EXCLUDED_CACHE_ER[$_k]}"
        done
        for _k in "${!_EXCLUDED_CACHE_EL[@]}"; do
            _el["$_k"]="${_EXCLUDED_CACHE_EL[$_k]}"
        done
        printf '%d\n' "${#_er[@]}"
        return 0
    fi

    # 1) cap=0 providers/models AND not-in-allowlist seats -> exclude.
    # A seat is "not-in-allowlist" when its provider is absent from the
    # cap map entirely (e.g. mergegateway in models.json but not in
    # seat-caps.json), or when the provider IS in the cap map but the
    # specific model is not listed in its models map (e.g. ollama has
    # only <retired-V4-flash>, so kimi-k2.7-code is not allowlisted).
    # Both sub-cases were per-seat logged on every pick_seat pass
    # ("skipped (not in cap-map allowlist)") — the dominant remaining
    # flood after #1449's cap=0 fix (fleet-ops#1456: 1584 lines/16min).
    if [[ -f "$MODELS_JSON" ]] && command -v jq >/dev/null 2>&1; then
        while IFS=$'\t' read -r p m; do
            [[ -n "$p" && -n "$m" ]] || continue
            cap="${SEAT_PROVIDER_CAP[$p]:-}"
            if [[ -n "$cap" ]] && (( cap == 0 )); then
                _er["$p/$m"]="cap=0:provider"
                _el["$p/$m"]=1
                continue
            fi
            local m_cap="${SEAT_MODEL_CAP[$p/$m]:-}"
            if [[ -n "$m_cap" ]] && (( m_cap == 0 )); then
                _er["$p/$m"]="cap=0:model"
                _el["$p/$m"]=1
                continue
            fi
            # Provider not in cap map at all -> not allowlisted.
            if [[ -z "$cap" ]]; then
                _er["$p/$m"]="not-in-allowlist:provider"
                _el["$p/$m"]=1
                continue
            fi
            # Provider in cap map but model not in its models map ->
            # not allowlisted (the cap map's models map IS the allowlist).
            if [[ -z "$m_cap" ]]; then
                _er["$p/$m"]="not-in-allowlist:model"
                _el["$p/$m"]=1
                continue
            fi
        done < <(jq -r '
            .providers | to_entries[] | .key as $p |
            ((.value.models // [])[] | [$p, .id]),
            ((.value.modelOverrides // {}) | to_entries[] | [$p, .key])
            | @tsv
        ' "$MODELS_JSON" 2>/dev/null || true)
    fi

    # 2) seat_dead=true in the ledger -> exclude that seat.
    # Walk the ledger directory; for every JSON file with seat_dead=true,
    # mark the seat excluded. fleet-ops#2327: this is NOT freshness-gated —
    # between weekly probes a corpse's observed_at naturally ages past
    # STALE_SECS, and re-admitting it on staleness is the exact re-pick loop
    # that grew muse-spark's count 80 -> 150. The P4-A stale-retry inversion
    # applies to HEALTHY/transient markers (retry a seat that may have
    # recovered), never to a corpse: only a successful probe writes a
    # healthy observation and clears seat_dead. This mirrors seat_usable().
    if [[ -d "$LEDGER_DIR" ]] && command -v jq >/dev/null 2>&1; then
        local f dead
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            # Cheap pre-check: only files that contain a seat_dead=true
            # token get parsed in full. The grep keeps the per-tick cost
            # O(dead) rather than O(ledger). jq's --null-input output puts
            # a space after the colon ("seat_dead": true), so the pattern
            # tolerates optional whitespace.
            grep -qE '"seat_dead":[[:space:]]*true' "$f" 2>/dev/null || continue
            dead=$(jq -r '.seat_dead // false | tostring' "$f" 2>/dev/null || echo false)
            [[ "$dead" == "true" ]] || continue
            # Decode provider/model from the file name
            # "<sanitised-provider>__<sanitised-model>.json"
            local base="${f##*/}"
            base="${base%.json}"
            local ps="${base%%__*}"
            local ms="${base#*__}"
            # Keyed on sanitised form; the loop re-sanitises on lookup.
            _er["__dead__/$ps/$ms"]="dead"
            _el["__dead__/$ps/$ms"]=1
        done < <(find "$LEDGER_DIR" -maxdepth 1 -type f -name '*__*.json' 2>/dev/null || true)
    fi

    # Refresh the process-level cache so the next pick_seat call hits
    # the cache instead of re-doing the find+jq+grep work.
    _EXCLUDED_CACHE_ER=()
    _EXCLUDED_CACHE_EL=()
    local _k
    for _k in "${!_er[@]}"; do
        _EXCLUDED_CACHE_ER["$_k"]="${_er[$_k]}"
    done
    for _k in "${!_el[@]}"; do
        _EXCLUDED_CACHE_EL["$_k"]="${_el[$_k]}"
    done
    _EXCLUDED_CACHE_KEY="$_cur_key"

    printf '%d\n' "${#_el[@]}"
}

# Sanitise a provider/model the same way seat_ledger_path does, so the
# excluded set (which is keyed on sanitised names) can be looked up by
# the loop's provider/model pair. The double-underscore prefix mirrors
# the ledger file name's separator.
_sanitise_seat() {
    local p="$1" m="$2"
    local ps="${p//[^A-Za-z0-9._-]/_}"
    local ms="${m//[^A-Za-z0-9._-]/_}"
    printf '__dead__/%s/%s\n' "$ps" "$ms"
}

# True if the (raw) provider/model has a fresh seat_dead=true ledger
# entry. The cap-map / allowlist checks are inlined in the loop, not
# here, because those use the raw key and the dead path uses a
# sanitised key.
_seat_is_dead() {
    local p="$1" m="$2"
    local k
    k=$(_sanitise_seat "$p" "$m")
    [[ -n "${_EXCLUDED_REASON[$k]:-}" ]]
}

# Pick a different seat than the failed one(s).
# Args: fail_provider fail_model [need_capable:1|0] [tried_seats_file] [difficulty] [privacy:public|private]
# The tried_seats_file (optional) lists all already-tried "provider/model" pairs
# (one per line); all are excluded. If not given, only fail_provider/fail_model
# is excluded.
# difficulty (fleet-ops#1133): keystone forces need_capable=1, walks strongest
# class first (prepaid -> metered -> free), and returns empty after 2 strikes
# so the caller escalates to the senior conference instead of another cheap
# retry. heavy/light (default) keep the #387/#1178 walk (volume first).
# privacy (optional, default public, fleet-ops#520): "private" excludes every
# free-class seat (free-tier privacy line). Fail-closed: a private target with
# only free seats available returns rc=1 instead of leaking to a free lane.
# Dispatch wrappers derive this from config/repo-privacy.json via repo_privacy
# / packet_repo.
# fleet-ops#3324: health_class values the minimum-usable floor may fail-open.
# A money wall (402 / quota_exhausted / corpse / credentials_bad) is NEVER
# fail-opened; those stay on the loud-stall path. empty_run is a
# failure_mode on a transient_fault ledger (mark_seat_empty_run), so the
# floor matches it via failure_mode as well as health_class.
# fleet-ops#3675: empty_run / spawn_fail benches are NO LONGER floor-lifted
# (see _seat_floor_shortest_bench) — a no-op bench is a HOLD, not a
# recoverable stall, and lifting it re-burns issues on a seat that just
# no-op'ed. The classes below are the remaining recoverable benches the
# floor may lift.
SEAT_FLOOR_FAILOPEN_CLASSES="transient_fault rate_limited overload_bench"

# True if this ledger row is a money wall the floor must never lift.
# Args: health_class seat_dead [failure_mode]
_seat_floor_is_money_wall() {
    local hc="$1" dead="$2" fm="${3:-}" fail_count="${4:-0}"
    [[ "$dead" == "true" ]] && return 0
    # fleet-ops#3531: a seat parked past SEAT_FAILURE_CEILING is a corpse in
    # all but label. The ledger is co-written (wrapper bench writers + the
    # seat-health.ts extension), so a corpse's class/seat_dead flip back to a
    # recoverable bench on the next 503/429 while the count keeps climbing
    # (live 2026-09-05: hetzner/Qwen count=31 and xkiro count=84-99 were
    # floor-lifted 6x in 40s, each lift a burned claim + StartLimitBurst).
    # The count is the one field every writer merges, so it is the wall.
    _seat_parked_by_ceiling "$fail_count" && return 0
    case "$hc" in
        quota_exhausted|quota_bench|credentials_bad|corpse) return 0 ;;
    esac
    case "$fm" in
        quota_exhausted|quota_cap|credentials_bad) return 0 ;;
    esac
    return 1
}

# True if this ledger row is a recoverable bench the floor may lift.
# Args: health_class [failure_mode]
_seat_floor_is_failopen_class() {
    local hc="$1" fm="${2:-}"
    case " $SEAT_FLOOR_FAILOPEN_CLASSES " in
        *" $hc "*) return 0 ;;
    esac
    return 1
}

# Remaining seconds on a benched seat, or empty if it has no future wall.
# Prefers bench_until, then usable_at, then the spawn-bench marker, then
# the #2288 park wall (observed_at + SEAT_PARK_WALL_S) for a parked
# transient_fault. A missing future timestamp is treated as remaining=0
# so a class-matching seat with a stale/empty wall still wins over a stall.
# Prints the remaining seconds (0 if none). Always returns 0.
_seat_floor_remaining_s() {
    local p="$1" m="$2" hc="$3" observed="$4" usable_at="$5" bench_until="$6" fail_count="${7:-0}"
    local rem sb_path sb_usable park_end_iso
    rem=$(_seat_remaining_s "$bench_until" 2>/dev/null || true)
    if [[ -z "$rem" ]]; then
        rem=$(_seat_remaining_s "$usable_at" 2>/dev/null || true)
    fi
    if [[ -z "$rem" ]]; then
        sb_path=$(seat_spawn_bench_path "$p" "$m")
        if [[ -f "$sb_path" ]]; then
            sb_usable=$(jq -r '.usable_at // ""' "$sb_path" 2>/dev/null || true)
            rem=$(_seat_remaining_s "$sb_usable" 2>/dev/null || true)
        fi
    fi
    if [[ -z "$rem" && "$hc" == "transient_fault" && -n "$observed" ]] \
        && _seat_parked_by_ceiling "$fail_count"; then
        park_end_iso=$(date -u -d "@$(( $(date -u -d "$observed" +%s 2>/dev/null || echo 0) + $(_park_wall_s "$fail_count") ))" \
            +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
        rem=$(_seat_remaining_s "$park_end_iso" 2>/dev/null || true)
    fi
    printf '%s\n' "${rem:-0}"
    return 0
}

# Increment fleet_seat_floor_failopen_total in a node-exporter textfile.
# Counter semantics: read the current value, add 1, rewrite. Fail-open:
# a write error never bricks pick_seat. Default file is under STATE_DIR so
# tests cannot poison the live collector; production copies there when
# STATE_DIR is the live path (same pattern as export_seat_selection_prom).
_emit_seat_floor_failopen() {
    local out="${SEAT_FLOOR_FAILOPEN_PROM:-$STATE_DIR/fleet-seat-floor-failopen.prom}"
    local dir pub tmp cur
    dir=$(dirname "$out")
    mkdir -p "$dir" 2>/dev/null || return 0
    cur=0
    if [[ -f "$out" ]]; then
        cur=$(awk '/^fleet_seat_floor_failopen_total / {print $2; exit}' "$out" 2>/dev/null || echo 0)
        [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
    fi
    cur=$((cur + 1))
    tmp="$out.$$.$RANDOM.tmp"
    {
        echo "# HELP fleet_seat_floor_failopen_total pick_seat fail-opened the shortest remaining recoverable bench instead of stalling (fleet-ops#3324)."
        echo "# TYPE fleet_seat_floor_failopen_total counter"
        printf 'fleet_seat_floor_failopen_total %s\n' "$cur"
    } >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    mv "$tmp" "$out" 2>/dev/null || { rm -f "$tmp"; return 0; }
    if [[ -z "${SEAT_FLOOR_FAILOPEN_PROM:-}" && "$STATE_DIR" == "${HOME}/.local/state/pi-packet" ]]; then
        pub="/var/lib/prometheus/node-exporter/fleet-seat-floor-failopen.prom"
        if [[ -d "$(dirname "$pub")" && -w "$(dirname "$pub")" ]]; then
            cp "$out" "$pub" 2>/dev/null || true
        fi
    fi
    return 0
}

# Walk the seats that seat_usable just rejected and, if at least one is a
# recoverable (non-money) bench, return the one with the shortest remaining
# wall. Prints "provider\tmodel\tremaining_s" and returns 0 on a hit;
# returns 1 when nothing is eligible (money walls / corpses / cap=0 stay
# on the loud-stall path). Privacy: a private target never fail-opens a
# free-class seat. need_capable: a heavy pick never fail-opens a seat that
# is not capable. tried-file seats stay excluded. Credential, keystone-only,
# and quality-ban filters match the pick loop so the floor cannot route to
# a seat pick_seat would refuse even when healthy.
_seat_floor_shortest_bench() {
    local privacy="${1:-public}" need_capable="${2:-0}" tried_file="${3:-}" difficulty="${4:-light}"
    local p m class capable f hc dead observed usable_at bench_until fail_count fm
    local rem best_rem="" best_p="" best_m="" p_cap m_cap
    declare -A floor_tried=()
    if [[ -n "$tried_file" && -f "$tried_file" ]]; then
        local tp tm
        while IFS=/ read -r tp tm; do
            [[ -n "$tp" ]] && floor_tried["$tp/$tm"]=1
        done <"$tried_file"
    fi
    while IFS=$'\t' read -r p m _ capable; do
        [[ -n "$p" && -n "$m" ]] || continue
        [[ -n "${floor_tried[$p/$m]:-}" ]] && continue
        [[ -n "${_EXCLUDED_REASON[$p/$m]:-}" ]] && continue
        if _seat_is_dead "$p" "$m"; then
            continue
        fi
        [[ -z "${SEAT_PROVIDER_CAP[$p]:-}" ]] && continue
        p_cap=$(provider_cap "$p")
        (( p_cap == 0 )) && continue
        [[ -z "${SEAT_MODEL_CAP[$p/$m]:-}" ]] && continue
        m_cap=$(model_cap "$p" "$m")
        (( m_cap == 0 )) && continue
        if ! provider_has_credential "$p"; then
            continue
        fi
        if _provider_is_keystone_only "$p" && ! _is_keystone_class "$difficulty"; then
            continue
        fi
        if (( need_capable )) && [[ "$capable" != "1" ]]; then
            continue
        fi
        if (( need_capable )) && [[ -n "${QUALITY_HEAVY_BAN[$p/$m]:-}" ]]; then
            continue
        fi
        class=$(model_class_of "$p" "$m")
        if [[ "$privacy" == "private" && "$class" == "free" ]]; then
            continue
        fi
        f=$(seat_ledger_path "$p" "$m")
        hc="" dead="false" observed="" usable_at="" bench_until="" fail_count=0 fm=""
        if [[ -f "$f" ]]; then
            IFS=$'\x1f'$'\n' read -r hc dead observed usable_at bench_until fail_count fm < <(
                jq -r '[(.health_class//""),(.seat_dead|tostring),(.observed_at//""),(.usable_at//""),(.bench_until//""),(.consecutive_failure_count//0),(.failure_mode//"")] | join("\u001f")' "$f" 2>/dev/null || true
            )
        fi
        _seat_floor_is_money_wall "$hc" "$dead" "$fm" "$fail_count" && continue
        # fleet-ops#3675: a no-op bench (empty_run / spawn_fail) is meant to
        # HOLD the seat out of rotation. The floor must NOT lift it — running
        # on a no-op seat burns issues (live: ollama/<retired-V4-flash>
        # no-op'ed 30x/2h, floor-lifted every bench, count climbed to 13).
        # Let the bench hold so the count reaches the failure ceiling and
        # parks the seat.
        case "$fm" in
            empty_run|spawn_fail) continue ;;
        esac
        if ! _seat_floor_is_failopen_class "$hc" "$fm"; then
            # Wrapper spawn-bench can outlive a healthy ledger clobber
            # (fleet-ops#1512). A no-op bench (empty_run / spawn_fail) on the
            # marker is a HOLD, not a floor candidate (fleet-ops#3675) — the
            # floor must not lift it. Anything else is not a floor candidate.
            local sb_path sb_usable sb_mode
            sb_path=$(seat_spawn_bench_path "$p" "$m")
            [[ -f "$sb_path" ]] || continue
            sb_usable=$(jq -r '.usable_at // ""' "$sb_path" 2>/dev/null || true)
            sb_mode=$(jq -r '.failure_mode // ""' "$sb_path" 2>/dev/null || true)
            _seat_in_future "$sb_usable" || continue
            case "$sb_mode" in
                empty_run|spawn_fail) continue ;;
                unknown) fm="$sb_mode" ;;
                *) continue ;;
            esac
        fi
        rem=$(_seat_floor_remaining_s "$p" "$m" "$hc" "$observed" "$usable_at" "$bench_until" "$fail_count")
        [[ "$rem" =~ ^[0-9]+$ ]] || rem=0
        if [[ -z "$best_rem" ]] || (( rem < best_rem )); then
            best_rem="$rem"
            best_p="$p"
            best_m="$m"
        fi
    done < <(enumerate_seats)
    [[ -n "$best_p" ]] || return 1
    printf '%s\t%s\t%s\n' "$best_p" "$best_m" "$best_rem"
    return 0
}

# fleet-ops#4639: reserved repair-rung ladder. pick_seat calls this when
# PI_REPAIR_RUNG=1 after the normal walk is empty. Order: litellm judge
# group -> mergegateway audition seats -> cursor keystone at cap 1.
# Never a money-walled seat. Exempt from yield ranking, keystone-only,
# and audition light-only filters (those filters are why the reserved
# seats were idle while worker seats were dead).
# Args: tried keys (provider/model). Prints provider<TAB>model on success.
_repair_rung_offer() {
    local p="$1" m="$2" cursor_cap="${3:-}"
    local f hc dead fail_count fail_mode m_cap active
    [[ -n "$p" && -n "$m" ]] || return 1
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    m_cap=$(model_cap "$p" "$m" 2>/dev/null || echo 0)
    [[ "$m_cap" =~ ^[0-9]+$ ]] || m_cap=0
    (( m_cap > 0 )) || return 1
    if ! provider_has_credential "$p"; then
        return 1
    fi
    f=$(seat_ledger_path "$p" "$m")
    if [[ -f "$f" ]]; then
        IFS=$'\x1f'$'\n' read -r hc dead _ _ _ fail_count fail_mode < <(
            jq -r '[(.health_class//""),(.seat_dead|tostring),(.observed_at//""),(.usable_at//""),(.bench_until//""),(.consecutive_failure_count//0),(.failure_mode//"")] | join("\u001f")' "$f" 2>/dev/null || true
        )
        if _seat_floor_is_money_wall "${hc:-}" "${dead:-false}" "${fail_mode:-}" "${fail_count:-0}"; then
            seat_log "REPAIR-RUNG: skip $p/$m (money wall, fleet-ops#4639)"
            return 1
        fi
    fi
    if ! seat_usable "$p" "$m"; then
        return 1
    fi
    if [[ "$p" == "cursor" && -n "$cursor_cap" ]]; then
        active=$(count_active_on_provider "$p")
        [[ "$active" =~ ^[0-9]+$ ]] || active=0
        if (( active >= cursor_cap )); then
            seat_log "REPAIR-RUNG: skip $p/$m (cursor cap $cursor_cap already in use, fleet-ops#4639)"
            return 1
        fi
    fi
    printf '%s\t%s\n' "$p" "$m"
    return 0
}

_pick_repair_rung_seat() {
    local skip_key _p _m _key _line
    declare -A _rskip=()
    for skip_key in "$@"; do
        [[ -n "$skip_key" ]] && _rskip["$skip_key"]=1
    done
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi

    # 1. litellm judge group
    if [[ -z "${_rskip[litellm/judge]:-}" ]]; then
        if _line=$(_repair_rung_offer litellm judge); then
            printf '%s\n' "$_line"
            return 0
        fi
    fi

    # 2. mergegateway audition seats (model-level audition: true)
    for _key in "${!SEAT_AUDITION[@]}"; do
        [[ "$_key" == mergegateway/* ]] || continue
        _p=mergegateway
        _m="${_key#mergegateway/}"
        [[ -z "${_rskip[$_p/$_m]:-}" ]] || continue
        if _line=$(_repair_rung_offer "$_p" "$_m"); then
            printf '%s\n' "$_line"
            return 0
        fi
    done

    # 3. cursor keystone at cap 1 (prefer grok-4.6-high)
    for _m in cursor-grok-4.6-high composer-2.5; do
        [[ -z "${_rskip[cursor/$_m]:-}" ]] || continue
        if _line=$(_repair_rung_offer cursor "$_m" 1); then
            printf '%s\n' "$_line"
            return 0
        fi
    done
    for _key in "${!SEAT_MODEL_CAP[@]}"; do
        [[ "$_key" == cursor/* ]] || continue
        _m="${_key#cursor/}"
        [[ "$_m" == "cursor-grok-4.6-high" || "$_m" == "composer-2.5" ]] && continue
        [[ -z "${_rskip[cursor/$_m]:-}" ]] || continue
        if _line=$(_repair_rung_offer cursor "$_m" 1); then
            printf '%s\n' "$_line"
            return 0
        fi
    done
    return 1
}

# Prints: "provider\tmodel" or nothing if none available.
pick_seat() {
    local fail_p="$1" fail_m="$2" need_capable="${3:-0}" tried_file="${4:-}" difficulty="${5:-light}"
    # privacy (6th arg, default "public"): "private" excludes every free-class
    # seat — the free-tier privacy line (vault 2026-08-18, fleet-ops#520). Free
    # lanes train on prompts, so private-repo or sensitive work must route to
    # prepaid/metered lanes only. Fail-closed: a private target with ONLY free
    # seats available returns rc=1 (loud stall) rather than leaking to a free
    # lane. Dispatch wrappers derive this from config/repo-privacy.json via
    # repo_privacy / packet_repo.
    local privacy="${6:-public}"
    [[ "$privacy" == "private" ]] || privacy="public"

    # Ensure caps are loaded (P4-A).
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    if (( ! _quality_routing_loaded )); then load_quality_routing || true; fi
    # fleet-ops#3250: read the PR-yield ledger written by fleet-metrics-export.
    # The data is not used for gating in this issue; that lands in #3251.
    if (( ! _seat_yield_loaded )); then load_seat_yield || true; fi

    if _is_keystone_class "$difficulty"; then
        need_capable=1
    fi

    # Reset the per-call credential cache so a provider is resolved once
    # per selection pass (fleet-ops#36). A provider with several models
    # shares one credential; the cache stops us re-running its apiKey
    # command per model.
    # fleet-ops#3732: slot-count mode. PICK_SEAT_COUNT_SLOTS=1 walks the SAME
    # filter chain as a pick but never picks a seat, never admits an AIMD probe
    # and never logs a summary; it echoes the number of light slots this pick
    # would actually fill: per provider, min(sum over its accepted models of
    # max(0, eff_model_cap - active), max(0, eff_provider_cap - active)).
    # The intake tick bounds its claims by this so it never claims into a wall.
    local _count_mode="${PICK_SEAT_COUNT_SLOTS:-0}"
    local -A _count_model_head=() _count_prov_head=()

    _cred_cache=()

    # Build the set of tried seats for exclusion.
    declare -A tried=()
    tried["$fail_p/$fail_m"]=1
    local tried_count=0
    if [[ -n "$tried_file" && -f "$tried_file" ]]; then
        local tp tm _tried_pruned=0
        local -a _tried_kept=()
        # Silence per-seat UNUSABLE lines during the prune walk; one
        # drop line below is the operator-visible record.
        local _SEAT_USABLE_SILENT=1
        while IFS=/ read -r tp tm; do
            [[ -n "$tp" && -n "$tm" ]] || continue
            # fleet-ops#4220: senior-review tried-seats is the Restart=
            # skip list only while the bench holds. Once seat_usable is
            # true (bench expired or never written), the line is stale
            # and must not pin cursor past the bench. Keystone still
            # counts every tried line as a strike (fleet-ops#1133).
            if [[ "$difficulty" == "senior-review" ]] && seat_usable "$tp" "$tm"; then
                seat_log "pick_seat: dropping stale tried $tp/$tm (bench expired — fleet-ops#4220)"
                _tried_pruned=1
                continue
            fi
            tried["$tp/$tm"]=1
            tried_count=$((tried_count + 1))
            _tried_kept+=("$tp/$tm")
        done <"$tried_file"
        if ((_tried_pruned)); then
            if ((${#_tried_kept[@]} > 0)); then
                printf '%s\n' "${_tried_kept[@]}" >"$tried_file"
            else
                : >"$tried_file"
            fi
        fi
    fi

    # Pre-compute the "definitively excluded" set ONCE per call
    # (fleet-ops#1449). The selection loop consults _EXCLUDED_REASON
    # below instead of logging a per-seat skip line on every pass.
    # Counts are tracked in _excluded_cap0_n / _excluded_dead_n /
    # _excluded_allowlist_n and surfaced as one summary line.
    declare -A _EXCLUDED_REASON=()
    declare -A _EXCLUDED_LIST=()
    _build_excluded_set _EXCLUDED_REASON _EXCLUDED_LIST >/dev/null
    # The pre-compute adds the SAME seat under two keys if it is both
    # cap=0 (raw key) and dead (sanitised key). Count UNIQUE seats, not
    # raw entries, by walking enumerate_seats and tallying the
    # cap=0/dead reasons separately. The summary line then names the
    # unique counts.
    local _excluded_cap0_n=0 _excluded_dead_n=0 _excluded_allowlist_n=0
    # fleet-ops#1432: within the cap=0 excluded seats, how many are INTENTIONAL
    # (dead_decoy / money_only — by design, never re-audit) vs STALE (broken
    # endpoint / TPM ceiling / exhausted quota — re-audit when the external
    # condition clears). Surfaced in the summary so the operator sees at a
    # glance which cap=0 seats are by-design vs which warrant re-audition.
    local _excluded_cap0_intentional_n=0 _excluded_cap0_stale_n=0

    # fleet-ops#1409: fold seat_usable() per-seat UNUSABLE log lines into a
    # per-pick summary. A permanently-benched seat (e.g. cline-pass minimax-m3
    # quota_bench until Sep 19) was logged N times per pick_seat call by every
    # concurrent worker — the remaining flood source after #1449's cap=0/dead
    # fold and #1624's at-capacity fold (rate_limited, quota_bench,
    # overload_bench, hang_bench, quota_exhausted, credentials_bad, backoff).
    # When _SEAT_USABLE_SILENT is set, seat_usable() skips the per-seat log
    # and the caller tallies the count + sample for ONE per-pick summary.
    local _SEAT_USABLE_SILENT=1
    local _seat_unusable_n=0
    local -a _seat_unusable_sample=()
    local _p _m _er
    if [[ -f "$MODELS_JSON" ]] && command -v jq >/dev/null 2>&1; then
        while IFS=$'\t' read -r _p _m; do
            [[ -n "$_p" && -n "$_m" ]] || continue
            if [[ -n "${_EXCLUDED_REASON[$_p/$_m]:-}" ]]; then
                case "${_EXCLUDED_REASON[$_p/$_m]}" in
                    cap=0:*)
                        _excluded_cap0_n=$((_excluded_cap0_n + 1))
                        # A seat is keyed on the provider for a provider-level
                        # cap (e.g. opencode-anthropic) and on provider/model
                        # for a model-level cap (e.g. opencode/muse-*). Classify
                        # from the annotation loaded in load_seat_caps.
                        if [[ -n "${SEAT_CAP_ZERO_CLASS_INTENTIONAL[$_p]:-}" \
                              || -n "${SEAT_CAP_ZERO_CLASS_INTENTIONAL[$_p/$_m]:-}" ]]; then
                            _excluded_cap0_intentional_n=$((_excluded_cap0_intentional_n + 1))
                        elif [[ -n "${SEAT_CAP_ZERO_CLASS_STALE[$_p]:-}" \
                                || -n "${SEAT_CAP_ZERO_CLASS_STALE[$_p/$_m]:-}" ]]; then
                            _excluded_cap0_stale_n=$((_excluded_cap0_stale_n + 1))
                        fi
                        ;;
                    not-in-allowlist:*) _excluded_allowlist_n=$((_excluded_allowlist_n + 1)) ;;
                esac
            fi
            local _ds
            _ds=$(_sanitise_seat "$_p" "$_m")
            if [[ -n "${_EXCLUDED_REASON[$_ds]:-}" ]]; then
                case "${_EXCLUDED_REASON[$_ds]}" in
                    dead)          _excluded_dead_n=$((_excluded_dead_n + 1)) ;;
                esac
            fi
        done < <(jq -r '
            .providers | to_entries[] | .key as $p |
            ((.value.models // [])[] | [$p, .id]),
            ((.value.modelOverrides // {}) | to_entries[] | [$p, .key])
            | @tsv
        ' "$MODELS_JSON" 2>/dev/null || true)
    fi

    # fleet-ops#1133: two strikes on a keystone packet end cheap retries.
    # tried_count is lines already recorded by the wrapper BEFORE this pick,
    # so 0 = first attempt, 1 = one retry left, >=2 = escalate.
    if _is_keystone_class "$difficulty" && (( tried_count >= 2 )); then
        seat_log "pick_seat: KEYSTONE ESCALATION — ${tried_count} strikes; refusing further cheap retries (senior conference via OnFailure)"
        keystone_record_event escalated
        return 1
    fi

    # fleet-ops#1297: build the active-seats count cache ONCE for this pass.
    # count_active_on_provider / count_active_on_seat are called per non-
    # excluded seat in the loop below, and count_active_total (via the AIMD
    # probe) per at-capacity seat; without the cache each re-read the whole
    # registry + legacy unit list (~4.4s/call measured). Reset forces a
    # rebuild so a multi-call process (tests) sees fresh state per pass.
    _PICK_ACTIVE_CACHE_BUILT=0
    _build_pick_active_cache

    # Buckets (fleet-ops#387):
    #   1) free lanes first (true free — never a prepaid seat mislabeled free)
    #   2) prepaid-quota, alternating across live prepaid so one weekly-quota
    #      seat cannot be drained dry while others sit idle
    #   3) metered last (per-token; spend after prepaid/free)
    local -a free_seats=() prepaid_seats=() metered_seats=()
    # fleet-ops#3724: seats flagged product_only in seat-caps.json are kept
    # out of every class bucket and appended at the very end of whichever
    # order this pick uses, so a paid last-resort seat is offered only when
    # no free/prepaid (or other) seat is usable — and only to a packet whose
    # repo carries the product flag in config/intake-repos.json.
    local -a product_only_seats=()
    # last_resort-flagged product_only seats are collected apart and merged
    # onto the bucket tail after enumeration, so they are the absolute last
    # pick of every order (Nish 2026-09-10 ds41 amendment).
    local -a product_only_last_seats=()

    # fleet-ops#1624: at-capacity (cap reached, seat busy not broken) skip
    # counter + sample. The per-seat "skipped (provider/model cap=N reached)"
    # lines were the remaining at_capacity_events flood source after #1449
    # silenced cap=0/dead (1006 events/2h on 2026-08-29 against cap=1 seats).
    # Folded into one per-pick summary line below, same pattern as #1449.
    # A busy seat is NOT benched — it frees the instant its worker exits, so
    # we keep re-evaluating it (count_active is cheap) but stop LOGGING it
    # per-seat per-pick. A literal cooldown would hide a seat that frees in
    # seconds and starve a cap=1 lane for the whole window.
    local _at_capacity_n=0
    local -a _at_capacity_sample=()
    # fleet-ops#1379: remember providers whose effective cap is reached this
    # pick so the remaining models are not re-polled.
    local -A _at_cap_provider=()

    # fleet-ops#1297: fold the STATIC heavy-pick skip classes too. A model's
    # `capable` flag for a given difficulty and the quality-routing ban do not
    # change while a heavy pick runs, so re-logging each per-seat line on every
    # pick is pure churn (28,243 "not capable for heavy task" lines in 2h on
    # 2026-08-29 while the fleet was heavy-only with no capable seat). Count
    # them into ONE per-pick summary, same pattern as #1449/#1624. Unlike
    # at-capacity (a busy seat frees), these are static for the pick, so the
    # skip is genuinely cheap — the per-seat detail adds nothing.
    local _notcap_n=0 _qban_n=0
    local -a _notcap_sample=()

    local p m free capable p_cap m_cap p_active m_active class eff_cap
    # `free` is emitted by enumerate_seats for parity with the legacy contract;
    # the new bucketing uses class_of() instead. Unused but stable in the pipe.
    # shellcheck disable=SC2034
    while IFS=$'\t' read -r p m free capable; do
        [[ -n "$p" ]] || continue
        # must differ from all tried seats
        [[ -n "${tried[$p/$m]:-}" ]] && continue
        # fleet-ops#1449/#1456: pre-computed excluded set. cap=0 providers
        # and models, not-in-allowlist seats (provider not in cap map or
        # model not in its models map), plus fresh seat_dead=true ledger
        # entries, are SILENTLY skipped here — they were already counted
        # in the summary line emitted at the end of pick_seat, and
        # re-logging each on every pass is the source of the
        # at_capacity_events flood (4492 events/2h on 2026-08-28) and the
        # not-in-allowlist flood (1584 lines/16min after #1449's cap=0
        # fix). The summary replaces N per-seat lines with 1 per-pick line.
        if [[ -n "${_EXCLUDED_REASON[$p/$m]:-}" ]]; then
            continue
        fi
        if _seat_is_dead "$p" "$m"; then
            # Dead ledger entry — skip the per-seat UNUSABLE log line.
            # seat_usable() would have logged it on every pass without
            # this guard. The summary at the end of pick_seat covers
            # the count.
            continue
        fi
        # Zenmux is routed to again (Nish, 2026-08-25): it carries FREE lanes
        # AND credits, so the old "free tier exhausted" hard-skip is stale. It
        # is governed by the cap map like every other provider now.
        # P4-A cap-map ALLOWLIST (P15 hardening): the cap map is the ONLY
        # source of truth for what may be routed. enumerate_seats emits the
        # WHOLE models.json list (including modelOverrides), so a provider
        # with no cap-map entry must be rejected here — previously it fell
        # through as "free" and could be picked with no credential backing
        # (the groq/openai/gpt-oss-20b credentials_bad pick of 2026-08-25).
        # No entry == not approved, period.
        if [[ -z "${SEAT_PROVIDER_CAP[$p]:-}" ]]; then
            seat_log "seat $p/$m skipped (provider $p not in cap-map allowlist)"
            continue
        fi
        p_cap=$(provider_cap "$p")
        if (( p_cap == 0 )); then
            # Provider explicitly capped at 0 (e.g. zenmux via config, though the
            # zenmux hard-skip above already covers it; this is the catch-all).
            seat_log "seat $p/$m skipped (provider cap=0)"
            continue
        fi
        m_cap=$(model_cap "$p" "$m")
        if [[ -z "${SEAT_MODEL_CAP[$p/$m]:-}" ]]; then
            # Provider has a cap map but the model is not listed -> standing-rule
            # block (e.g. ollama DeepSeek-flash-only, openrouter/grok with no
            # models map). A provider cap alone is not an allowlist entry.
            seat_log "seat $p/$m skipped (not in cap-map allowlist for $p)"
            continue
        fi
        if (( m_cap == 0 )); then
            # Model explicitly capped at 0 in the map (e.g. devin/glm-5-2:0).
            seat_log "seat $p/$m skipped (model cap=0)"
            continue
        fi
        # fleet-ops#3690: per-tick per-provider spawn cap. Skip the provider's
        # seats once tick_spawn_cap new sessions have been routed to it this
        # tick. The intake tick resets the counter at the start of each tick.
        # Count mode (PICK_SEAT_COUNT_SLOTS=1) skips the gate so slot counting
        # still reflects raw seat availability.
        if (( ! _count_mode )) && tick_spawn_cap_exceeded "$p"; then
            seat_log "seat $p/$m skipped (per-tick spawn cap reached for $p — fleet-ops#3690)"
            continue
        fi
        if ! provider_has_credential "$p"; then
            # provider_has_credential already logged the rejection reason.
            # Defence in depth on top of the cap map (fleet-ops#36): an
            # allowlisted provider whose apiKey resolves to empty is never
            # a candidate, so a tick is not burned on a guaranteed 401/403.
            continue
        fi
        if _provider_is_keystone_only "$p"; then
            if ! _is_keystone_class "$difficulty"; then
                seat_log "seat $p/$m skipped (keystone/senior-review only — fleet-ops#1167)"
                continue
            fi
            if [[ "$p" == "cursor" && "${SEAT_CURSOR_INCLUDED_EXHAUSTED:-0}" == "1" \
                  && "$m" != "${SEAT_CURSOR_OVERAGE_MODEL:-cursor-grok-4.6-high}" ]]; then
                seat_log "seat $p/$m skipped (cursor overage model is ${SEAT_CURSOR_OVERAGE_MODEL:-cursor-grok-4.6-high} — fleet-ops#1167)"
                continue
            fi
        fi
        # fleet-ops#3322: audition lane. A seat carrying audition: true (injected
        # by the intake tick from config/model-candidates.json) is only eligible
        # for packet_difficulty light — cap 1, 10 sessions / 7d / $1 cost cap.
        # Skip it for heavy/keystone/senior-review so an unproven candidate
        # never lands high-stakes work. The count-mode walk honours the same
        # gate so intake does not claim into an audition-only pool for heavy.
        if seat_is_audition "$p" "$m" && [[ "$difficulty" != "light" ]]; then
            seat_log "seat $p/$m skipped (audition seat — light issues only, fleet-ops#3322)"
            continue
        fi
        # fleet-ops#4129: a stale cap=0 seat re-admitted for re-probe is
        # light-only until a probe proves it answers. Skip it for every
        # non-light difficulty so a freshly re-admitted dead free seat never
        # lands a heavy/keystone/senior-review packet. Same shape as the
        # audition gate above; count-mode honours it so intake does not claim
        # into a re-probe-only pool for heavy.
        if seat_is_reprobe_light_only "$p" "$m" && [[ "$difficulty" != "light" ]]; then
            seat_log "seat $p/$m skipped (cap0-stale re-probe seat — light issues only, fleet-ops#4129)"
            continue
        fi
        if (( need_capable )) && [[ "$capable" != "1" ]]; then
            # fleet-ops#1297: silence the per-seat "not capable for heavy task"
            # line — it was the dominant watch.log flood (28k/2h) when a heavy
            # pick had no capable seat. Counted into the per-pick summary below.
            _notcap_n=$((_notcap_n + 1))
            _notcap_sample+=("$p/$m")
            continue
        fi
        if (( need_capable )) && [[ -n "${QUALITY_HEAVY_BAN[$p/$m]:-}" ]]; then
            # fleet-ops#1297: same fold for the quality-routing ban line.
            _qban_n=$((_qban_n + 1))
            continue
        fi
        # fleet-ops#2661: escalation-lane provider-wedge check (gated). The
        # 503-storm lane isolation: only stop-escalation-dispatch (and the
        # Python mirror inside alert-repair-dispatch) set
        # FLEET_ESCALATION_WEDGE_CHECK=1, so only the escalation lanes refuse
        # a provider with >=2 seats recently in overload_bench (mid-storm).
        # Workers keep per-seat seat_usable() routing only — their benches are the
        # right granularity for them;the wedge is the escalation-only isolation.
        if [[ "${FLEET_ESCALATION_WEDGE_CHECK:-0}" == "1" ]] && provider_overload_wedged "$p"; then
            seat_log "seat $p/$m skipped (provider $p overload-wedged — ${PROVIDER_OVERLOAD_WEDGE_MIN:-2}+ overload_bench seats within ${PROVIDER_OVERLOAD_WEDGE_WINDOW_S:-1800}s; escalation lanes only)"
            continue
        fi
        if ! seat_usable "$p" "$m"; then
            # fleet-ops#1409: seat_usable runs silent (per-seat log suppressed)
            # when _SEAT_USABLE_SILENT=1. Count the UNUSABLE seat + keep a
            # sample for the per-pick summary emitted below.
            _seat_unusable_n=$((_seat_unusable_n + 1))
            _seat_unusable_sample+=("$p/$m")
            continue
        fi
        # fleet-ops#3723: per-account free-model daily request budget
        # (OpenRouter). The budget is shared across every *:free model on the
        # provider; once today's (UTC) assistant-turn count hits the cap, every
        # free model on the provider is benched until 00:00 UTC — NOT charged
        # to the work item (no consecutive_failure_count, no yield penalty).
        # Only applies to models whose id ends in :free on a provider with a
        # configured free_model_daily_request_budget. The bench writer is
        # separate from mark_seat_quota_bench so the count stays at 0 and the
        # failure ceiling never trips on an account-wide external limit.
        if [[ "$m" == *":free" ]] \
            && [[ -n "${SEAT_FREE_DAILY_REQUEST_BUDGET[$p]:-}" ]] \
            && _provider_free_daily_budget_reached "$p"; then
            _mark_seat_free_daily_budget_bench "$p" "$m" || true
            _seat_unusable_n=$((_seat_unusable_n + 1))
            _seat_unusable_sample+=("$p/$m")
            continue
        fi
        # fleet-ops#4453: provider-level daily USD budget for an expiring
        # daily allowance (Pareto Pass $20/day, unused $ lost at 23:59). When
        # today's token-derived spend on the provider reaches the stop, every
        # model on the provider is benched until 00:00 UTC — the SAME money
        # wall shape as the free-daily-budget bench (consecutive_failure_count
        # 0, never charged to the work item). Token-derived because
        # ParetoInference reports usage.cost=0 on the Pass (the rate card
        # bills the credits, not per-call cost). The bench is written once per
        # candidate model; seat_usable rejects it thereafter. First
        # 429-after-budget / first 200-after-reset are logged once per day in
        # the provider's prepaid-usage counter file (learning the undocumented
        # reset hour, rule 2).
        if [[ -n "${SEAT_PROVIDER_DAILY_BUDGET_USD[$p]:-}" ]] \
            && _provider_daily_budget_reached "$p"; then
            _mark_seat_provider_daily_budget_bench "$p" "$m" || true
            _seat_unusable_n=$((_seat_unusable_n + 1))
            _seat_unusable_sample+=("$p/$m")
            continue
        fi
        # fleet-ops#1379: once a provider is at effective cap for this pick,
        # all of its remaining models share that provider-wide cap. Back off
        # instead of re-running count_active / effective_provider_cap / AIMD
        # probe for each one. The per-pick at-capacity summary still counts them.
        if [[ -n "${_at_cap_provider[$p]:-}" ]]; then
            _at_capacity_n=$((_at_capacity_n + 1))
            _at_capacity_sample+=("$p/$m")
            continue
        fi
        # P4-A + AIMD (#217/#424): honour the learned effective cap, and
        # admit one additive probe when exactly saturated with room below
        # the ceiling. cap=0 walled rows stay skipped via provider_cap above.
        p_active=$(count_active_on_provider "$p")
        eff_cap=$(effective_provider_cap "$p")
        if (( eff_cap > 0 )) && (( p_active >= eff_cap )); then
            if (( _count_mode )); then
                # fleet-ops#3732 counting only: an at-cap provider contributes 0, no probe
                _at_cap_provider[$p]=1
                continue
            fi
            if _aimd_probe_admitted "$p" "$eff_cap" "$p_active"; then
                seat_log "seat $p/$m AIMD probe admitted (provider $p cap $eff_cap -> $((eff_cap + 1)): $p_active active, zero errors, RAM headroom)"
            else
                # fleet-ops#1624/#1379: silence the per-seat "skipped (provider
                # cap reached)" line — it was the at_capacity_events flood
                # source (1006/2h against cap=1 seats). Counted into the
                # per-pick at-capacity summary below instead, and the provider's
                # remaining models are not re-polled this pick. The seat is still
                # re-evaluated next pick (a busy seat frees when its worker
                # exits); only the per-seat log line is dropped. A literal
                # cooldown would hide a seat that frees in seconds and starve a
                # cap=1 lane for the whole window.
                _at_cap_provider[$p]=1
                _at_capacity_n=$((_at_capacity_n + 1))
                _at_capacity_sample+=("$p/$m")
                continue
            fi
        fi
        # fleet-ops#3125: model-level AIMD. effective_model_cap is the declared
        # cap unless the model row declares a max_probe_ceiling (devin seats);
        # when it does, the same AIMD rules apply at model granularity and a
        # saturated seat admits one additive probe below the ceiling.
        m_active=$(count_active_on_seat "$p" "$m")
        m_eff_cap=$(effective_model_cap "$p" "$m")
        if (( m_eff_cap > 0 )) && (( m_active >= m_eff_cap )); then
            if (( _count_mode )); then
                continue
            fi
            if _model_probe_admitted "$p" "$m" "$m_eff_cap" "$m_active"; then
                seat_log "seat $p/$m AIMD model probe admitted (model cap $m_eff_cap -> $((m_eff_cap + 1)): $m_active active, zero errors, RAM headroom)"
            else
                # fleet-ops#1624: same flood fix for the model-cap-reached branch.
                _at_capacity_n=$((_at_capacity_n + 1))
                _at_capacity_sample+=("$p/$m")
                continue
            fi
        fi

        class=$(model_class_of "$p" "$m")
        # Bucket by per-model CLASS (explicit class on the model row in
        # seat-caps, falling back to the provider class). prepaid-quota
        # includes the old "subscription" alias (normalized in class_of).
        # Free-tier privacy line (fleet-ops#520): a private target never
        # buckets a free-class seat — free lanes train on prompts. The seat
        # is skipped (logged) so a private repo can never leak to a free lane
        # even when free is the only class with capacity.
        if [[ "$privacy" == "private" && "$class" == "free" ]]; then
            seat_log "seat $p/$m skipped (free-tier privacy: private-repo target, free-class lane blocked)"
            continue
        fi
        if (( _count_mode )); then
            # fleet-ops#3732: seat accepted — accumulate headroom, do not pick.
            local _ph _mh
            if (( eff_cap > 0 )); then _ph=$(( eff_cap - p_active )); else _ph=999; fi
            if (( m_eff_cap > 0 )); then _mh=$(( m_eff_cap - m_active )); else _mh=999; fi
            (( _ph < 0 )) && _ph=0
            (( _mh < 0 )) && _mh=0
            _count_prov_head[$p]=$_ph
            _count_model_head[$p]=$(( ${_count_model_head[$p]:-0} + _mh ))
            continue
        fi
        # fleet-ops#3724: product_only seat gate. A seat flagged product_only
        # in seat-caps.json is a metered last-resort seat that may only ever
        # serve a packet whose repo carries the product flag in
        # config/intake-repos.json — fleet-ops is control plane and an
        # unclassified packet repo fails closed, so it can never land here.
        # The seat joins product_only_seats (appended after every class in
        # every order) so it is offered only when no free/prepaid seat is
        # usable. When a daily_spend_cap_usd is configured, reaching today's
        # (UTC) Pi usage.cost on the seat benches it until 00:00 UTC — a
        # money wall (quota_bench/quota_cap ledger entry, consecutive
        # failure count 0), never charged to the work item.
        if [[ -n "${SEAT_PRODUCT_ONLY[$p/$m]:-}" ]]; then
            if ! repo_is_product "${PI_PACKET_REPO:-}"; then
                seat_log "seat $p/$m skipped (product_only: packet repo '${PI_PACKET_REPO:-none}' is not a declared product repo — fleet-ops#3724)"
                continue
            fi
            if _seat_daily_spend_cap_reached "$p" "$m"; then
                _mark_seat_spend_cap_bench "$p" "$m" || true
                _seat_unusable_n=$((_seat_unusable_n + 1))
                _seat_unusable_sample+=("$p/$m")
                continue
            fi
            # last_resort (Nish 2026-09-10 ds41 amendment): the PAYG
            # api.deepseek.com seat sinks to the tail of the last-resort
            # bucket — offered only when every other seat of every class,
            # including other product_only seats, is unusable.
            if [[ -n "${SEAT_LAST_RESORT[$p/$m]:-}" ]]; then
                product_only_last_seats+=("$p"$'\t'"$m")
            else
                product_only_seats+=("$p"$'\t'"$m")
            fi
            continue
        fi
        case "$class" in
            prepaid-quota) prepaid_seats+=("$p"$'\t'"$m") ;;
            metered)       metered_seats+=("$p"$'\t'"$m") ;;
            *)             free_seats+=("$p"$'\t'"$m") ;;
        esac
    done < <(enumerate_seats)

    if (( _count_mode )); then
        local _ct=0 _cp _cph _cmh
        for _cp in "${!_count_prov_head[@]}"; do
            _cph=${_count_prov_head[$_cp]}
            _cmh=${_count_model_head[$_cp]:-0}
            (( _cmh < _cph )) && _cph=$_cmh
            _ct=$(( _ct + _cph ))
        done
        echo "$_ct"
        return 0
    fi

    # Merge last_resort-flagged product_only seats onto the bucket tail so
    # every pick site (product value-order fall-through, keystone ladder,
    # senior-review scan, normal ladder) sees them strictly last.
    if (( ${#product_only_last_seats[@]} > 0 )); then
        product_only_seats+=("${product_only_last_seats[@]}")
    fi

    # fleet-ops#1449: ONE summary line per pick_seat call for the seats
    # that the pre-computed excluded set silently filtered out. The
    # at_capacity_events metric in the heartbeat rolls up per-seat
    # "skipped (cap=0)" / "UNUSABLE (seat_dead)" lines from watch.log;
    # this summary replaces the N per-seat lines that were filling the
    # log, so the next 2h window should show the count drop. Format is
    # stable: "pick_seat: excluded N seats (cap=0: C; dead: D;
    # not-in-allowlist: A)" so a future grep can pin the count without
    # parsing the per-seat tail. The list is sorted and truncated to 6
    # to keep the line short even on a large fleet.
    if (( _excluded_cap0_n + _excluded_dead_n + _excluded_allowlist_n > 0 )); then
        local _sample=()
        local _k
        for _k in "${!_EXCLUDED_REASON[@]}"; do
            # Filter out the internal __dead__/* sanitised keys — the
            # summary line should show operator-readable "provider/model"
            # names, not the ledger-file-name hash.
            [[ "$_k" == __dead__/* ]] && continue
            _sample+=("$_k")
        done
        # Sort + truncate to 6 sample seats so the line stays short.
        # bash array slice (not head -n): fleet-token-efficiency-check rejects
        # head -n caps on any touched assembler file (fleet-ops#523).
        local _sorted
        if (( ${#_sample[@]} > 0 )); then
            mapfile -t _sorted < <(printf '%s\n' "${_sample[@]}" | sort)
            _sorted=("${_sorted[@]:0:6}")
        else
            _sorted=()
        fi
        local _sample_str=""
        if (( ${#_sorted[@]} > 0 )); then
            _sample_str=$(printf '%s\n' "${_sorted[@]}" | paste -sd, -)
        fi
        # fleet-ops#1432: fold the cap=0 classification into the summary so the
        # operator sees intentional vs stale cap=0 seats at a glance. Emitted
        # only when at least one cap=0 seat is annotated, so un-annotated
        # fixtures (and the legacy "devin: glm-5-2:0" shorthand rows) keep the
        # exact legacy summary shape.
        local _cap0_clause=""
        if (( _excluded_cap0_intentional_n + _excluded_cap0_stale_n > 0 )); then
            _cap0_clause=" [cap0-intentional: $_excluded_cap0_intentional_n; cap0-stale: $_excluded_cap0_stale_n]"
        fi
        seat_log "pick_seat: excluded $((_excluded_cap0_n + _excluded_dead_n + _excluded_allowlist_n)) seats (cap=0: $_excluded_cap0_n; dead: $_excluded_dead_n; not-in-allowlist: $_excluded_allowlist_n)${_cap0_clause} [${_sample_str}]"
    fi

    # fleet-ops#1624: ONE summary line per pick_seat call for the at-capacity
    # seats (cap reached — busy, not broken). The per-seat "skipped (provider/
    # model cap=N reached)" lines were the remaining at_capacity_events flood
    # source after #1449 (1006 events/2h on 2026-08-29 against cap=1 seats
    # like xai-oauth/grok-4.5+4.6 and commandcode/poolside/laguna-s-2.1-free).
    # This summary replaces the N per-seat lines so the next 2h window shows
    # the count drop, same pattern as the #1449 excluded summary above.
    # Distinct from the excluded summary: at-capacity is DYNAMIC (a seat frees
    # the instant its worker exits), so it is re-evaluated every pick — only
    # the per-seat LOG line is dropped, never the cap check. A literal
    # cooldown would hide a seat that frees in seconds and starve a cap=1
    # lane for the whole window. Format is stable: "pick_seat: at-capacity N
    # seats [sample]" so a future grep can pin the count.
    if (( _at_capacity_n > 0 )); then
        local _ac_sorted=()
        if (( ${#_at_capacity_sample[@]} > 0 )); then
            mapfile -t _ac_sorted < <(printf '%s\n' "${_at_capacity_sample[@]}" | sort | uniq)
            _ac_sorted=("${_ac_sorted[@]:0:6}")
        fi
        local _ac_sample_str=""
        if (( ${#_ac_sorted[@]} > 0 )); then
            _ac_sample_str=$(printf '%s\n' "${_ac_sorted[@]}" | paste -sd, -)
        fi
        seat_log "pick_seat: at-capacity ${_at_capacity_n} seats [${_ac_sample_str}]"
    fi

    # fleet-ops#1297: ONE summary line per pick_seat call for the folded STATIC
    # heavy-pick skips (not-capable-for-heavy and quality-routing-ban). Same
    # pattern as the #1449/#1624 summaries. The per-seat "skipped (not capable
    # for heavy task)" lines were the dominant watch.log flood source (28,243
    # lines in 2h on 2026-08-29) when a heavy-only fleet had no capable seat.
    # A model's capable flag and the routing ban are static for a pick, so no
    # information is lost by collapsing them. Format is stable: "pick_seat:
    # filtered-static N seats (not-capable: C; quality-ban: Q) [sample]" so a
    # future grep can pin the count.
    if (( _notcap_n + _qban_n > 0 )); then
        local _nc_sorted=()
        if (( ${#_notcap_sample[@]} > 0 )); then
            mapfile -t _nc_sorted < <(printf '%s\n' "${_notcap_sample[@]}" | sort | uniq)
            _nc_sorted=("${_nc_sorted[@]:0:6}")
        fi
        local _nc_sample_str=""
        if (( ${#_nc_sorted[@]} > 0 )); then
            _nc_sample_str=$(printf '%s\n' "${_nc_sorted[@]}" | paste -sd, -)
        fi
        seat_log "pick_seat: filtered-static $((_notcap_n + _qban_n)) seats (not-capable: $_notcap_n; quality-ban: $_qban_n) [${_nc_sample_str}]"
    fi

    if [[ -n "$SEAT_FREE_ORDER" ]] && (( ${#free_seats[@]} > 0 )); then
        mapfile -t free_seats < <(_order_seats_by "$SEAT_FREE_ORDER" "${free_seats[@]}")
    fi
    if [[ -n "$SEAT_PREPAID_ORDER" ]] && (( ${#prepaid_seats[@]} > 0 )); then
        mapfile -t prepaid_seats < <(_order_seats_by "$SEAT_PREPAID_ORDER" "${prepaid_seats[@]}")
    fi

    # Weekly-quota pacing: skip prepaid seats over the pace threshold when
    # another prepaid seat is still under it. All-paced fail-opens (work
    # must not stall).
    if (( ${#prepaid_seats[@]} > 0 )); then
        local -a prepaid_live=() prepaid_paced_seats=()
        local fm_p
        for fm_p in "${prepaid_seats[@]}"; do
            p="${fm_p%%$'\t'*}"
            if _prepaid_paced "$p"; then
                prepaid_paced_seats+=("$fm_p")
            else
                prepaid_live+=("$fm_p")
            fi
        done
        if (( ${#prepaid_live[@]} > 0 )); then
            prepaid_seats=("${prepaid_live[@]}")
        else
            prepaid_seats=("${prepaid_paced_seats[@]}")
        fi
    fi

    # fleet-ops#1133 keystone inverts cost-first: prepaid (strongest class)
    # first, then metered, free last. Skip prepaid round-robin so a hard
    # packet cannot rotate onto ollama-flash as "just another prepaid".
    # fleet-ops#3125: product_order=yield. Product picks (PI_PICK_ROLE=
    # product, exported by pi-issue-run / pi-packet-run) rank every candidate
    # seat by the rolling last-20-sessions PR yield in seat-yield.json (the
    # #3250 ledger, loaded via load_seat_yield/seat_yield_for), descending;
    # ties break by class (prepaid-quota -> metered -> free, so prepaid subs
    # still drain first among equal performers) then by each bucket's
    # existing order. A seat absent from the ledger, or provisional (<20
    # measured sessions), carries 0.5 — new seats are tried, not starved.
    # fleet-ops#3323: product_order=value. The ledger also carries
    # cost_per_session (rolling mean usage.cost per session); value =
    # yield / max(cost_per_session, 0.001). For packet_difficulty light the
    # key is value alone, so free seats (cost ~0, floored to 0.001) sort
    # first at equal yield. For heavy/keystone the key is yield first
    # (quality) then value, so a free seat with 2% yield still loses to a
    # paid seat with 70% yield on heavy work. The value order also covers
    # keystone-class product picks (the class ladder below only sees
    # non-product or product_order=yield picks).
    # fleet-ops#4558: on the LIGHT value key the buckets drain by class tier
    # before value is consulted across classes: free (costs nothing) first,
    # then prepaid-quota in prepaid_providers_in_order ladder order (Devin's
    # standing '4 devin seats always working' — a paid-for seat is drained
    # before any metered spend), then metered by value. Within a tier the
    # existing value/yield keys still apply. Heavy/keystone keep the
    # yield-first (quality) key across tiers unchanged — a free 2%-yield seat
    # still loses to a paid 70%-yield seat there.
    local -a product_seats=()
    if [[ "${PI_PICK_ROLE:-scout}" == "product" ]] \
        && [[ "$SEAT_PRODUCT_ORDER" == "value" ]]; then
        local _qfirst=0
        local _vsort="-k1,1nr -k2,2nr -k3,3n"
        if [[ "$difficulty" == "heavy" ]] || _is_keystone_class "$difficulty"; then
            _qfirst=1
        else
            # fleet-ops#4558: light drains by class tier (tier, in-tier order,
            # yield, ladder index). The awk emits 8 fields on this branch.
            _vsort="-k1,1n -k2,2n -k3,3n -k4,4n"
        fi
        local -a _vranked=()
        mapfile -t _vranked < <(
            _i=0
            for _fm in ${prepaid_seats[@]+"${prepaid_seats[@]}"} ${metered_seats[@]+"${metered_seats[@]}"} ${free_seats[@]+"${free_seats[@]}"}; do
                [[ -n "$_fm" ]] || continue
                _p="${_fm%%$'\t'*}"
                _m="${_fm#*$'\t'}"
                _yld=$(seat_yield_for "$_p" "$_m")
                _cost=$(seat_cost_for "$_p" "$_m")
                # fleet-ops#4558 class tier: free=0, prepaid-quota=1, metered=2.
                local _tier=0
                case "$(model_class_of "$_p" "$_m")" in
                    prepaid-quota) _tier=1 ;;
                    metered)       _tier=2 ;;
                esac
                printf '%s\t%s\t%s\t%s\t%s\n' "$_yld" "$_cost" "$_i" "$_tier" "$_fm"
                _i=$((_i + 1))
            done | awk -F'\t' -v q="$_qfirst" 'BEGIN{OFS="\t"} {
                y=$1+0; c=$2+0; if (c<0.001) c=0.001; v=y/c; t=$4+0;
                if (q) printf "%.6f\t%.6f\t%s\t%s\t%s\t%.6f\t%.6f\n", y, v, $3, $5, $6, y, v;
                else {
                    # prepaid drains in ladder order (the _i index over the
                    # ladder-ordered prepaid bucket); free/metered by value.
                    subk = (t == 1) ? $3 : -v;
                    printf "%.6f\t%.6f\t%.6f\t%s\t%s\t%s\t%.6f\t%.6f\n", t, subk, -y, $3, $5, $6, y, v;
                }
            }' | sort -t$'\t' ${_vsort:--k1,1nr -k2,2nr -k3,3n}
        )
        local _vline _vlog="" _vn=0
        for _vline in ${_vranked[@]+"${_vranked[@]}"}; do
            [[ -n "$_vline" ]] || continue
            local _k1 _k2 _vi _vp _vm _vy _vv
            if (( _qfirst )); then
                IFS=$'\t' read -r _k1 _k2 _vi _vp _vm _vy _vv <<<"$_vline"
            else
                # fleet-ops#4558 light branch: tier, sub, -yield, idx, p, m, y, v
                local _kt
                IFS=$'\t' read -r _kt _k1 _k2 _vi _vp _vm _vy _vv <<<"$_vline"
            fi
            product_seats+=("${_vp}"$'\t'"${_vm}")
            if (( _vn < 6 )); then
                _vlog+="${_vp}/${_vm}@y=${_vy},v=${_vv} "
                _vn=$((_vn + 1))
            fi
        done
        # One line per pick so the operator sees the computed value order.
        if (( ${#product_seats[@]} > 0 )); then
            seat_log "pick_seat: value-order (product,${difficulty}): ${_vlog% }"
        fi
    elif ! _is_keystone_class "$difficulty" \
        && [[ "${PI_PICK_ROLE:-scout}" == "product" ]] \
        && [[ "$SEAT_PRODUCT_ORDER" == "yield" ]]; then
        local -a _yranked=()
        mapfile -t _yranked < <(
            _i=0
            for _fm in ${prepaid_seats[@]+"${prepaid_seats[@]}"} ${metered_seats[@]+"${metered_seats[@]}"} ${free_seats[@]+"${free_seats[@]}"}; do
                [[ -n "$_fm" ]] || continue
                _p="${_fm%%$'\t'*}"
                _m="${_fm#*$'\t'}"
                _yld=$(seat_yield_for "$_p" "$_m")
                case "$(model_class_of "$_p" "$_m")" in
                    prepaid-quota) _rank=0 ;;
                    metered)       _rank=1 ;;
                    *)             _rank=2 ;;
                esac
                printf '%s\t%s\t%s\t%s\n' "$_yld" "$_rank" "$_i" "$_fm"
                _i=$((_i + 1))
            done | sort -t$'\t' -k1,1nr -k2,2n -k3,3n
        )
        local _yline _ylog="" _yn=0
        for _yline in ${_yranked[@]+"${_yranked[@]}"}; do
            [[ -n "$_yline" ]] || continue
            local _ys _yr _yi _yp _ym
            IFS=$'\t' read -r _ys _yr _yi _yp _ym <<<"$_yline"
            product_seats+=("${_yp}"$'\t'"${_ym}")
            if (( _yn < 6 )); then
                _ylog+="${_yp}/${_ym}@${_ys} "
                _yn=$((_yn + 1))
            fi
        done
        # One line per pick so the operator sees the computed yield order.
        if (( ${#product_seats[@]} > 0 )); then
            seat_log "pick_seat: yield-order (product): ${_ylog% }"
        fi
    fi

    local chosen="" chosen_p="" chosen_m=""
    # fleet-ops#3310: seat-class preference (PI_PICK_PREFER_CLASS). When the
    # WORK reclaim cap fires, intake writes a per-issue .prefer-class marker
    # and the next claim forces pick_seat onto a DIFFERENT seat CLASS instead
    # of blocking (prepaid -> metered -> senior ladder). Reuses the existing
    # class buckets from the loop above plus find_senior_seat (the #3121 senior
    # ladder). An empty preferred class (depleted bucket / walled senior) falls
    # through to the normal yield ladder below so a depleted class never stalls
    # the work item. Skipped for keystone (keystone already pins the strongest
    # class) and when the variable is empty (normal picks).
    if [[ -n "${PI_PICK_PREFER_CLASS:-}" ]] && ! _is_keystone_class "$difficulty"; then
        case "$PI_PICK_PREFER_CLASS" in
            senior)
                if _sl=$(find_senior_seat 2>/dev/null); then
                    chosen="$_sl"
                    chosen_p="${chosen%%$'\t'*}"
                    chosen_m="${chosen#*$'\t'}"
                    seat_log "pick_seat: prefer-class=senior routing to $chosen"
                fi
                ;;
            prepaid|metered|free)
                local -a _pref_bucket=()
                case "$PI_PICK_PREFER_CLASS" in
                    prepaid) _pref_bucket=(${prepaid_seats[@]+"${prepaid_seats[@]}"}) ;;
                    metered) _pref_bucket=(${metered_seats[@]+"${metered_seats[@]}"}) ;;
                    free)    _pref_bucket=(${free_seats[@]+"${free_seats[@]}"}) ;;
                esac
                if (( ${#_pref_bucket[@]} > 0 )); then
                    chosen="${_pref_bucket[0]}"
                    chosen_p="${chosen%%$'\t'*}"
                    chosen_m="${chosen#*$'\t'}"
                    if [[ "$PI_PICK_PREFER_CLASS" == "prepaid" \
                        && "$(model_class_of "$chosen_p" "$chosen_m")" == "prepaid-quota" ]]; then
                        _record_prepaid_pick "$chosen_p"
                    fi
                    seat_log "pick_seat: prefer-class=$PI_PICK_PREFER_CLASS routing to $chosen"
                fi
                ;;
        esac
    fi
    # The class ladder below runs only when the prefer-class override did not
    # already pick a seat (an empty preferred bucket / walled senior falls
    # through to the normal yield ladder).
    # fleet-ops#4220: senior-review packets route through the senior ladder
    # (SEAT_SENIOR_ORDER: cursor → xai-oauth → openrouter) BEFORE the keystone
    # class ladder. The class ladder walks prepaid_providers_in_order, which in
    # the live config leads with ollama — so without this gate a senior-review
    # packet landed on ollama instead of cursor. The buckets above already
    # passed all cap/bench/tried/credential checks, so walking the senior order
    # against them reuses the existing rails (no duplicated cap logic). Falls
    # through to the class ladder when no senior seat is in the buckets (walled
    # role resolves to its fallback, not a stall).
    if [[ -z "${chosen:-}" && "$difficulty" == "senior-review" ]]; then
        local _sn _sp _sm _bucket_seat
        for _sn in ${SEAT_SENIOR_ORDER[@]+"${SEAT_SENIOR_ORDER[@]}"}; do
            [[ -n "$_sn" ]] || continue
            _sp="${_sn%%/*}"
            _sm="${_sn#*/}"
            [[ -n "$_sp" && -n "$_sm" ]] || continue
            for _bucket_seat in ${prepaid_seats[@]+"${prepaid_seats[@]}"} ${metered_seats[@]+"${metered_seats[@]}"} ${free_seats[@]+"${free_seats[@]}"} ${product_only_seats[@]+"${product_only_seats[@]}"}; do
                [[ "$_bucket_seat" == "$_sp"$'\t'"$_sm" ]] || continue
                chosen="$_bucket_seat"
                chosen_p="$_sp"
                chosen_m="$_sm"
                if [[ "$(model_class_of "$chosen_p" "$chosen_m")" == "prepaid-quota" ]]; then
                    _record_prepaid_pick "$chosen_p"
                fi
                seat_log "pick_seat: senior-review routing to $chosen_p/$chosen_m"
                break 2
            done
        done
    fi
    # fleet-ops#4467: expiring prepaid seats behind pace are picked FIRST,
    # round-robin, so a lapsing subscription (ClinePass, SuperGrok) is burned
    # instead of rolling over unused while devin+ollama absorb the fleet.
    # This overrides the product value/yield ledger (fleet-ops#3323/#3125): a
    # lapsing prepaid seat wastes money that a marginal yield difference does
    # not — the floor only front-runs seats that are actually behind pace, so
    # normal picks (all seeds on pace) keep the ledger order unchanged. It
    # yields only to keystone (strongest-capable seat) and to an explicit
    # prefer-class / senior-review override that already set `chosen` above.
    if [[ -z "${chosen:-}" ]] && ! _is_keystone_class "$difficulty"; then
        if _floor=$(_pick_expiring_floor_seat) && [[ -n "$_floor" ]]; then
            chosen="$_floor"
            chosen_p="${chosen%%$'\t'*}"
            chosen_m="${chosen#*$'\t'}"
            _record_prepaid_pick "$chosen_p"
            seat_log "pick_seat: expiring-pace floor routing to $chosen_p/$chosen_m (behind pace, lapsing prepaid)"
        fi
    fi
    if [[ -z "${chosen:-}" ]]; then
    if (( ${#product_seats[@]} > 0 )); then
        chosen="${product_seats[0]}"
        chosen_p="${chosen%%$'\t'*}"
        chosen_m="${chosen#*$'\t'}"
        # Prepaid seats still burn weekly pacing when the ledger picks them.
        if [[ "$(model_class_of "$chosen_p" "$chosen_m")" == "prepaid-quota" ]]; then
            _record_prepaid_pick "$chosen_p"
        fi
        if _is_keystone_class "$difficulty"; then
            seat_log "pick_seat: KEYSTONE routing to $chosen (product ledger order, yield-first)"
        fi
    elif _is_keystone_class "$difficulty"; then
        if (( ${#prepaid_seats[@]} > 0 )); then
            chosen="${prepaid_seats[0]}"
            chosen_p="${chosen%%$'\t'*}"
            _record_prepaid_pick "$chosen_p"
            seat_log "pick_seat: KEYSTONE routing to $chosen (prepaid/strongest class first)"
        elif (( ${#metered_seats[@]} > 0 )); then
            chosen="${metered_seats[0]}"
            seat_log "pick_seat: KEYSTONE routing to $chosen (metered; no prepaid left)"
        elif (( ${#free_seats[@]} > 0 )); then
            chosen="${free_seats[0]}"
            seat_log "pick_seat: KEYSTONE routing to $chosen (free last-resort)"
        elif (( ${#product_only_seats[@]} > 0 )); then
            chosen="${product_only_seats[0]}"
            seat_log "pick_seat: KEYSTONE routing to $chosen (product_only last-resort — fleet-ops#3724)"
        fi
    elif (( ${#free_seats[@]} > 0 )); then
        chosen="${free_seats[0]}"
    elif (( ${#prepaid_seats[@]} > 0 )); then
        chosen=$(_rr_pick "$STATE_DIR/prepaid-rr.idx" "${prepaid_seats[@]}")
        chosen_p="${chosen%%$'\t'*}"
        _record_prepaid_pick "$chosen_p"
    elif (( ${#metered_seats[@]} > 0 )); then
        chosen="${metered_seats[0]}"
    elif (( ${#product_only_seats[@]} > 0 )); then
        # fleet-ops#3724: product_only seats are the seat of last resort —
        # reached only when every free/prepaid/metered seat was unusable this
        # pick, and only for a packet repo flagged product in
        # config/intake-repos.json (the repo gate ran in the loop above).
        chosen="${product_only_seats[0]}"
        seat_log "pick_seat: routing to product_only last-resort seat $chosen (no free/prepaid seat usable — fleet-ops#3724)"
    fi
    fi
    if [[ -n "$chosen" ]]; then
        record_seat_selection "${chosen%%$'\t'*}" "${chosen#*$'\t'}" "$difficulty"
        if _is_keystone_class "$difficulty"; then
            keystone_record_event routed "${chosen%%$'\t'*}" "${chosen#*$'\t'}"
        fi
        # fleet-ops#3690: count this pick against the provider's per-tick
        # spawn cap so the next pick_seat in the same tick sees it.
        tick_spawn_cap_record "${chosen%%$'\t'*}"
        printf '%s\n' "$chosen"
        return 0
    fi

    # fleet-ops#1409: per-pick summary for the seat_usable UNUSABLE seats folded
    # during the loop above. Same pattern as the excluded/at-capacity/static
    # summaries — replaces N per-seat "UNUSABLE (…)" / "benched until (…)" log
    # lines with ONE per-pick line. Format is stable: "pick_seat: unusable N
    # seats [sample]" so a future grep can pin the count.
    if (( _seat_unusable_n > 0 )); then
        local _su_sorted=()
        if (( ${#_seat_unusable_sample[@]} > 0 )); then
            mapfile -t _su_sorted < <(printf '%s\n' "${_seat_unusable_sample[@]}" | sort | uniq)
            _su_sorted=("${_su_sorted[@]:0:6}")
        fi
        local _su_sample_str=""
        if (( ${#_su_sorted[@]} > 0 )); then
            _su_sample_str=$(printf '%s\n' "${_su_sorted[@]}" | paste -sd, -)
        fi
        seat_log "pick_seat: unusable ${_seat_unusable_n} seats [${_su_sample_str}]"
    fi

    # fleet-ops#4639: reserved repair rung. When the packet carries
    # seat-rung: repair (PI_REPAIR_RUNG=1), try the reserved ladder before
    # the recoverable-bench floor: litellm judge -> mergegateway audition
    # -> cursor keystone at cap 1. Money-walled seats stay refused.
    if [[ "${PI_REPAIR_RUNG:-0}" == "1" ]] && (( ! _count_mode )); then
        local _rung_line _rp _rm
        if _rung_line=$(_pick_repair_rung_seat "${!tried[@]}"); then
            IFS=$'\t' read -r _rp _rm <<<"$_rung_line"
            if [[ -n "$_rp" && -n "$_rm" ]]; then
                seat_log "REPAIR-RUNG: picked ${_rp}/${_rm} (fleet-ops#4639)"
                record_seat_selection "$_rp" "$_rm" "$difficulty"
                if _is_keystone_class "$difficulty"; then
                    keystone_record_event routed "$_rp" "$_rm"
                fi
                tick_spawn_cap_record "$_rp"
                printf '%s\t%s\n' "$_rp" "$_rm"
                return 0
            fi
        fi
    fi

    # fleet-ops#3324: minimum-usable floor. When the capable set is empty
    # but at least one benched seat is a recoverable class (transient_fault,
    # rate_limited, empty_run, overload_bench) — not a money wall
    # (402 / quota_exhausted / quota_bench / corpse / credentials_bad) —
    # fail-open the one with the shortest remaining bench instead of stalling.
    # Turns a starved tick into a slightly-early retry. Money-walled seats
    # stay on the loud-stall path below.
    local _floor_line _floor_p _floor_m _floor_left
    if _floor_line=$(_seat_floor_shortest_bench "$privacy" "$need_capable" "$tried_file" "$difficulty"); then
        IFS=$'\t' read -r _floor_p _floor_m _floor_left <<<"$_floor_line"
        if [[ -n "$_floor_p" && -n "$_floor_m" ]]; then
            [[ "$_floor_left" =~ ^[0-9]+$ ]] || _floor_left=0
            seat_log "seat-floor: fail-open ${_floor_p}/${_floor_m} (bench had ${_floor_left}s left)"
            _emit_seat_floor_failopen
            record_seat_selection "$_floor_p" "$_floor_m" "$difficulty"
            if _is_keystone_class "$difficulty"; then
                keystone_record_event routed "$_floor_p" "$_floor_m"
            fi
            # fleet-ops#3690: count floor-fallback picks too.
            tick_spawn_cap_record "$_floor_p"
            printf '%s\t%s\n' "$_floor_p" "$_floor_m"
            return 0
        fi
    fi

    # P15: loud stall beats a garbage seat. Every allowlisted seat was dead or
    # capped — return 1 (caller must not spawn anything) and say so, rather
    # than falling back to a non-allowlisted model.
    # fleet-ops#1409: cooldown before returning when no seat is available —
    # prevents the systemd RestartSec timer from immediately re-firing another
    # full pick_seat pass against an already walled fleet (the per-second
    # thrash loop: pick_seat → NO USABLE SEAT → exit 1 → restart → pick_seat).
    if [[ "$privacy" == "private" ]]; then
        seat_log "pick_seat: NO USABLE SEAT — every non-free allowlisted seat is dead/capped/rate-limited, and free-class lanes are blocked for this private-repo target (free-tier privacy line, fleet-ops#520). Refusing to route outside the cap map or to a free lane."
    else
        seat_log "pick_seat: NO USABLE SEAT — every allowlisted seat is dead/capped/rate-limited. Refusing to route outside the cap map."
    fi
    local _cooldown="${PI_SEAT_NOUSABLE_COOLDOWN_S:-5}"
    [[ "$_cooldown" =~ ^[0-9]+$ ]] || _cooldown=5
    if (( _cooldown > 0 )); then
        sleep "$_cooldown"
    fi
    return 1
}

# Derive a stable packet-id from a packet file path.
packet_id_from_path() {
    local pkt="$1" base
    base=$(basename "$pkt")
    base="${base%.txt}"
    echo "${base//[^A-Za-z0-9._-]/_}"
}

# Register that a worker is running on a given seat. The wrapper (pi-issue-run
# or pi-packet-run) MUST call this on start and clear_active_seat on exit
# (via trap) so the cap accounting reflects reality.
# Args: unit_name provider model
register_active_seat() {
    local unit="$1" p="$2" m="$3"
    mkdir -p "$ACTIVE_SEATS_DIR"
    jq -nc --arg p "$p" --arg m "$m" --arg u "$unit" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{provider:$p, model:$m, unit:$u, started_at:$t}' \
        > "$ACTIVE_SEATS_DIR/${unit}.json"
}

clear_active_seat() {
    local unit="$1"
    rm -f "$ACTIVE_SEATS_DIR/${unit}.json" 2>/dev/null || true
}

# --- spawn-fail marker (P13-B) ---------------------------------------------
# seat-health.ts writes the per-seat ledger via after_provider_response or
# cli_* sources, both of which only fire on a LIVE session. A spawn-phase
# failure (e.g. spawnSync ETIMEDOUT) terminates the worker before any
# response hook runs, so the seat stays green in the ledger and seat_usable
# keeps routing work to it. This writer is the deterministic event-driven
# complement: the worker wrapper (pi-issue-run / pi-packet-run) calls it
# on its way out when pi exited non-zero AND elapsed < SPAWN_FAIL_MAX_S
# AND ETIMEDOUT is in the captured output. Schema is byte-compatible with
# SeatHealthSidecar + SeatLedgerEntry (seat-health.ts); seat_usable here
# reads the same fields and the failure naturally flips usable_at into
# the future, which is the only field pick_seat gates on for this class.
#
# Args: provider model [reason]
#   reason defaults to "spawn_etimeout". Passed through to log lines only
#   (the marker itself uses a fixed failure_mode=cli_timeout so the shape
#   matches what a live-session timeout would have written — selectors are
#   stable across spawn-time and live-session failures).
# Side effect: writes LEDGER_DIR/<sanitised-provider>__<sanitised-model>.json
# atomically (tmp + rename). Best-effort: any failure is logged to
# $LOG_FILE but does NOT fail the worker's own exit — caller still wants
# a non-zero exit so systemd re-seats, and a broken marker write must
# never silently swallow that.
SPAWN_FAIL_BACKOFF_S="${SPAWN_FAIL_BACKOFF_S:-300}"  # 5 min — longer than
# the seat-health.ts default 60s because spawn ETIMEDOUT is the devin-503
# signature, and 60s would let the same dead seat be picked 4x in 5 min.
SPAWN_FAIL_MAX_S="${SPAWN_FAIL_MAX_S:-120}"
# fleet-ops#1408: a seat that spawn-fails in a loop (a REAL provider wall:
# non-zero exit, HTTP 429/402/500, spawn ETIMEDOUT) must NOT re-enter
# rotation at the base backoff every cycle. Escalate the bench by
# consecutive_failure_count so each repeated failure benches longer, breaking
# the re-seat loop (12 no-ops in 2h on opencode/nemotron-3-ultra-free at a flat
# 300s bench, count hit 16). Doubles per consecutive failure, capped so a
# recovered seat is never walled permanently — seat_usable fail-opens after
# usable_at regardless of count, and seat-health.ts resets the count to 0 on a
# healthy in-session observation, so the escalation is fair.
# fleet-ops#2343: EMPTY RUNS (provider no-op, exit 0 + <OUT_MIN stdout) are
# NOT a wall and must NOT take this ladder — see mark_seat_empty_run.
SPAWN_FAIL_BACKOFF_CAP_S="${SPAWN_FAIL_BACKOFF_CAP_S:-3600}"  # 1 h

# fleet-ops#5189: bench window for mark_seat_writes_refused_bench (a seat
# whose tool-approval gate refused the run's writes). The window must OUTLAST
# the caller unit's RestartSec: agent-cron-orchestrator-decision-sweep
# re-runs 900s after a failure, and senior-review tried-seats are dropped
# once the seat reads usable again (fleet-ops#4220), so a sub-900s bench
# would re-pick the same gated seat and refuse again. 3600s bounds the gate
# to one refused attempt per seat per hour — the classifier is intermittent,
# so each expiry re-probes the seat before the next refusal re-benches it.
SEAT_WRITES_REFUSED_BENCH_S="${SEAT_WRITES_REFUSED_BENCH_S:-3600}"

# _escalated_backoff base count [cap]
# Compute a backoff that doubles per consecutive failure, capped at <cap>.
#   count=1 -> base (one-off flake: short bench, quick retry)
#   count=2 -> base * 2
#   count=3 -> base * 4
#   count>=k -> cap
# Defensive: non-numeric inputs fall back to base / count=1.
_escalated_backoff() {
    local base="${1:-300}" count="${2:-1}" cap="${3:-3600}"
    [[ "$base" =~ ^[0-9]+$ ]] || base=300
    [[ "$count" =~ ^[0-9]+$ ]] || count=1
    [[ "$cap" =~ ^[0-9]+$ ]] || cap=3600
    (( count < 1 )) && count=1
    (( cap < base )) && cap="$base"
    local b="$base" i=1
    while (( i < count )); do
        b=$(( b * 2 ))
        if (( b >= cap )); then b="$cap"; break; fi
        i=$(( i + 1 ))
    done
    (( b > cap )) && b="$cap"
    printf '%s' "$b"
}

# fleet-ops#3531: geometric bench cap for the error-class writers. The
# normal backoff window doubles on each consecutive failure, capped at 6 h
# (21600 s). The long failure-ceiling park (SEAT_FAILURE_CEILING, default 20,
# to SEAT_PARK_WALL_S, default 24 h) is applied ON TOP of this cap.
SEAT_BENCH_GEOMETRIC_CAP_S="${SEAT_BENCH_GEOMETRIC_CAP_S:-21600}"

# fleet-ops#4640: a wall longer than 6h is a claim about the PROVIDER
# (money_boundary or a parsed quota window). A wrapper exit code is
# evidence about the LANE. Never the former from the latter.
SEAT_NON_MONEY_WALL_MAX_S="${SEAT_NON_MONEY_WALL_MAX_S:-21600}"
SEAT_CREDENTIALS_BAD_BENCH_S="${SEAT_CREDENTIALS_BAD_BENCH_S:-3600}"
SEAT_CREDENTIALS_CORPSE_STRIKES="${SEAT_CREDENTIALS_CORPSE_STRIKES:-24}"

# fleet-ops#3531: remote prepaid seats (e.g. devin) must not be benched for
# more than 30 min on a false empty run. Their empty-run geometric backoff is
# capped at 1800 s instead of the 6 h default.
SEAT_REMOTE_AGENT_EMPTY_RUN_CAP_S="${SEAT_REMOTE_AGENT_EMPTY_RUN_CAP_S:-1800}"

# _geometric_bench_window base count [cap] [ceil_override]
# Compute a bench window that doubles per consecutive failure, capped at <cap>,
# and then parked at the failure ceiling. This is the single helper shared by
# the overload, quota, and empty-run writers. The optional 4th arg overrides
# the failure ceiling for this call (fleet-ops#3727: empty runs use a lower
# EMPTY_RUN_FAILURE_CEILING than the generic SEAT_FAILURE_CEILING).
_geometric_bench_window() {
    local base="${1:-300}" count="${2:-1}" cap="${3:-$SEAT_BENCH_GEOMETRIC_CAP_S}" ceil_ovr="${4:-}"
    [[ "$base" =~ ^[0-9]+$ ]] || base=300
    [[ "$count" =~ ^[0-9]+$ ]] || count=1
    [[ "$cap" =~ ^[0-9]+$ ]] || cap=21600
    local window
    window=$(_escalated_backoff "$base" "$count" "$cap")
    _failure_ceiling_wall "$count" "$window" "$ceil_ovr"
}

# --- failure-count ceiling (fleet-ops#1362) ---------------------------------
# Before this, the escalated backoff capped at 1h (spawn; the empty/no-op
# side was also escalated to 2h until fleet-ops#2343 flattened it to
# EMPTY_RUN_BACKOFF_S — a provider no-op is not a wall) and the
# quota/overload/hang benches used a FLAT provider default every cycle, so a
# seat that kept failing re-entered rotation every cap/flat interval forever.
# consecutive_failure_count climbed to 72 on devin/glm-5-2 (HTTP 429), 64 on
# opencode/muse-spark-1.2-contributor-free (HTTP 500), 63 on
# opencode/mimo-v2.5-free (HTTP 429) while the bench never grew past ~15min —
# the prober kept hammering them and burning probe budget on guaranteed
# failures. The ceiling parks a seat behind a long wall once its
# consecutive_failure_count crosses SEAT_FAILURE_CEILING, so a chronically
# failing seat is probed once per park wall instead of once per base backoff.
#
# Design: the park is a LONGER WALL, not seat_dead=true. seat_usable fail-opens
# after usable_at / bench_until regardless of count (the #1408 contract), and
# seat-health.ts resets consecutive_failure_count to 0 on a healthy in-session
# observation — so a recovered seat is re-tried at the base backoff, not walled
# permanently. Setting seat_dead=true would either be redundant (the bench
# branches short-circuit before the seat_dead check) or break fail-open for
# transient_fault markers (seat_dead holds past usable_at). The long wall keeps
# the fail-open contract intact while still parking the seat.
#
# fleet-ops#2594: lower the ceiling default from 60 to 20. At 60 the
# read-side transient_fault fence (line ~1318) never engaged on the live
# poolside/laguna-s-2.1-free (c=21, transient_fault, 30s flat re-offer loop
# per the gap-audit snapshot), and the bash quota/overload/hang benches
# re-walled every provider-default interval for every seat below the ceiling.
# At 20 the long wall engages three times sooner — a chronically failing
# seat is probed once per park wall instead of hammering the flat cadence
# for ~20 wasted cycles first. The number is operator-tunable via env and
# the existing test overrides (`export SEAT_FAILURE_CEILING=N`) preserve
# their assertions byte-identically.
SEAT_FAILURE_CEILING="${SEAT_FAILURE_CEILING:-20}"
SEAT_PARK_WALL_S="${SEAT_PARK_WALL_S:-86400}"  # 24 h — probe once per day, not per 15min
# fleet-ops#3941: the failure-ceiling park wall ESCALATES with the count
# instead of resetting to a flat SEAT_PARK_WALL_S every cycle. A seat that
# has failed 47 times straight (live: xkiro/<retired-V4-flash>) was re-offered
# every 24h park-wall expiry and re-walled at the SAME 24h — the wall never
# grew, so a chronically-dead seat was probed once per day forever. Now the
# wall grows one SEAT_PARK_WALL_S per failure past the ceiling, capped at
# SEAT_PARK_WALL_MAX_S (default 7 days), so a seat that keeps failing is
# probed less and less often.
SEAT_PARK_WALL_MAX_S="${SEAT_PARK_WALL_MAX_S:-604800}"  # 7 days — cap on the escalated park wall

# --- corpse reclassification (fleet-ops#2594) ------------------------------
# The bash quota_bench writer (mark_seat_quota_bench) was excluded from the
# seat-health.ts corpse logic (#2145): that path covers transient_http /
# rate_limit / cli_timeout / transient_other / empty_run by count, and
# quota_exhausted by age, but quota_cap (the bash writer's failure_mode) was
# not in either branch. Consequence: opencode/mimo-v2.5-free at 42
# consecutive 429s sat at health_class=quota_bench forever — the bench
# expired after the 24h park wall, the prober retried, the seat failed
# again, the cycle repeated, and count kept climbing on a seat that was
# clearly dead (live snapshot in the #2594 audit). This threshold applies
# the corpse reclassification in the bash writer: at merged_count >=
# SEAT_DEAD_CONSECUTIVE_THRESHOLD the quota_bench ledger is written with
# seat_dead=true, and seat_usable holds the seat TERMINALLY (no auto
# fail-open — only a healthy observation, fleet-ops#2327, clears the
# corpse). Default matches seat-health.ts's seat_dead_consecutive_threshold
# (25) so the two writers agree on the corpse boundary. Lower than the
# 25-consecutive quarantine_threshold the extension uses is intentional:
# park first (the bench window), corpse later (terminal exclusion).
SEAT_DEAD_CONSECUTIVE_THRESHOLD="${SEAT_DEAD_CONSECUTIVE_THRESHOLD:-25}"

# True (return 0) if a consecutive_failure_count crosses the corpse threshold
# — i.e. the seat should be written with seat_dead=true. Same defensive
# pattern as _seat_parked_by_ceiling: non-numeric inputs fall back to 0/false.
_seat_dead_by_threshold() {
    local count="${1:-0}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    local thr="${SEAT_DEAD_CONSECUTIVE_THRESHOLD:-25}"
    [[ "$thr" =~ ^[0-9]+$ ]] || thr=25
    (( count >= thr ))
}

# _park_wall_s count [ceil_override]
# Echo the failure-ceiling park wall in seconds, ESCALATING with the count
# past the ceiling instead of resetting to a flat SEAT_PARK_WALL_S every
# cycle (fleet-ops#3941). count < ceil -> 0 (not parked; the caller uses the
# base backoff). count == ceil -> SEAT_PARK_WALL_S (first park). Each further
# failure adds one park wall, capped at SEAT_PARK_WALL_MAX_S. The optional
# 2nd arg overrides the ceiling (empty-run uses EMPTY_RUN_FAILURE_CEILING).
# Defensive: non-numeric inputs fall back to 0 / defaults.
_park_wall_s() {
    local count="${1:-0}" ceil_override="${2:-}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    local ceil="${SEAT_FAILURE_CEILING:-20}"
    [[ -n "$ceil_override" ]] && ceil="$ceil_override"
    [[ "$ceil" =~ ^[0-9]+$ ]] || ceil=20
    local park="${SEAT_PARK_WALL_S:-86400}"
    [[ "$park" =~ ^[0-9]+$ ]] || park=86400
    local max="${SEAT_PARK_WALL_MAX_S:-604800}"
    [[ "$max" =~ ^[0-9]+$ ]] || max=604800
    if (( count < ceil )); then
        printf '0'
        return 0
    fi
    local extra=$(( count - ceil + 1 ))
    local wall=$(( park * extra ))
    (( wall > max )) && wall="$max"
    printf '%s' "$wall"
}

# Echo the effective park wall seconds for a consecutive_failure_count and a
# computed base backoff/window. When count >= SEAT_FAILURE_CEILING the wall is
# forced to the ESCALATED park wall (_park_wall_s, fleet-ops#3941); otherwise
# the base is echoed unchanged. An optional 3rd argument overrides the ceiling
# for this call (legacy).
# fleet-ops#3531: all writers now share the generic SEAT_FAILURE_CEILING.
# Defensive: non-numeric inputs fall back to the base / count=0.
_failure_ceiling_wall() {
    local count="${1:-0}" base="${2:-300}" ceil_override="${3:-}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    [[ "$base" =~ ^[0-9]+$ ]] || base=300
    local ceil="${SEAT_FAILURE_CEILING:-20}"
    [[ -n "$ceil_override" ]] && ceil="$ceil_override"
    [[ "$ceil" =~ ^[0-9]+$ ]] || ceil=20
    if (( count >= ceil )); then
        printf '%s' "$(_park_wall_s "$count" "$ceil_override")"
        return 0
    fi
    printf '%s' "$base"
}

# True (return 0) if count has crossed the failure ceiling. Optional 2nd
# argument overrides the ceiling for this call (fleet-ops#2627 same-shape
# override as _failure_ceiling_wall).
_seat_parked_by_ceiling() {
    local count="${1:-0}" ceil_override="${2:-}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    local ceil="${SEAT_FAILURE_CEILING:-20}"
    [[ -n "$ceil_override" ]] && ceil="$ceil_override"
    [[ "$ceil" =~ ^[0-9]+$ ]] || ceil=20
    (( count >= ceil ))
}

# Emit the fleet_seat_failure_ceiling_parked metric for a parked seat. One
# gauge line per parked seat (provider,model labels); merging preserves the
# other seats' lines so a multi-seat park does not clobber the file. Fail-open:
# a write error never bricks the marker. Default file is under STATE_DIR so
# tests cannot poison the live node_exporter dir; production copies to the
# public textfile collector when STATE_DIR is the live path (same pattern as
# export_seat_selection_prom).
_emit_failure_ceiling_metric() {
    local p="$1" m="$2" count="${3:-0}"
    local out="${SEAT_FAILURE_CEILING_PROM:-$STATE_DIR/fleet-seat-failure-ceiling.prom}"
    local dir pub tmp sp sm
    dir=$(dirname "$out")
    mkdir -p "$dir" 2>/dev/null || return 0
    sp="${p//[^A-Za-z0-9._/-]/_}"
    sm="${m//[^A-Za-z0-9._/-]/_}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    tmp="$out.$$.$RANDOM.tmp"
    {
        echo "# HELP fleet_seat_failure_ceiling_parked Seats parked past the consecutive-failure ceiling (fleet-ops#1362)."
        echo "# TYPE fleet_seat_failure_ceiling_parked gauge"
        # Preserve other seats' gauge lines; drop any stale line for this seat.
        if [[ -f "$out" ]]; then
            grep -E '^fleet_seat_failure_ceiling_parked' "$out" 2>/dev/null \
                | grep -vE "fleet_seat_failure_ceiling_parked\\{provider=\"${sp}\",model=\"${sm}\"\\}" || true
        fi
        printf 'fleet_seat_failure_ceiling_parked{provider="%s",model="%s"} %s\n' "$sp" "$sm" "$count"
    } >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    mv "$tmp" "$out" 2>/dev/null || { rm -f "$tmp"; return 0; }
    if [[ -z "${SEAT_FAILURE_CEILING_PROM:-}" && "$STATE_DIR" == "${HOME}/.local/state/pi-packet" ]]; then
        pub="/var/lib/prometheus/node-exporter/fleet-seat-failure-ceiling.prom"
        if [[ -d "$(dirname "$pub")" && -w "$(dirname "$pub")" ]]; then
            cp "$out" "$pub" 2>/dev/null || true
        fi
    fi
}

# Returns 0 if the worker output looks like a spawn-phase failure (ETIMEDOUT
# pattern from devin/cursor CLI shims). Strict enough to require the
# timeout keyword AND a connection-flavored neighbour (ECONN / socket /
# fetch / connect / spawn / child); spawnPhase starts before pi has a real
# HTTP response to log, so the test is on the stderr text, not a status
# code.
is_spawn_etimeout() {
    local out="$1" err="$2"
    local combined="$out"$'\n'"$err"
    [[ -n "$combined" ]] || return 1
    if ! grep -qiE 'ETIMEDOUT|E2BIG|connection timed out|connect ETIMEDOUT|timed out waiting' <<<"$combined"; then
        return 1
    fi
    # Co-occurrence guard: a worker that took down stdout verbosely could
    # mention "timed out" without it being spawn-time. Require at least one
    # spawn-signal word within +/- 120 chars of the timed-out match. This
    # is the cheap regex-version of "did this happen before pi had a real
    # response" — a real timeout mid-session is paired with an HTTP status,
    # never with spawn/socket/connect/child.
    # fleet-ops#5309: E2BIG joins the signature set — `spawnSync <bin> E2BIG`
    # is pi's cursor provider passing a prompt past the kernel's per-arg
    # limit. Benching the seat is not the true fix (the prompt is the fault;
    # agent-cron-run's pre-flight cap refuses oversize prompts before spawn),
    # but a missed case must bench with a spawn-bench marker instead of
    # crash-looping the same seat to StartLimitBurst.
    if grep -qiE '.{0,120}(ETIMEDOUT|E2BIG|timed out).{0,120}(spawn|socket|connect|child|fetch|handshake)' <<<"$combined"; then
        return 0
    fi
    if grep -qiE '(spawn|socket|connect|child|fetch|handshake).{0,120}(ETIMEDOUT|E2BIG|timed out)' <<<"$combined"; then
        return 0
    fi
    return 1
}

# --- transport-down gate (fleet-ops#3111) -----------------------------------
# When the pi transport itself is down (clobbered bin, broken cli.js), EVERY
# run fails with the same empty/no-op/rc=124 shape and would be charged to the
# SEAT by the bench writers below — poisoning every seat with 24h benches
# while the fault is the transport, not any seat. The 2026-09-03 incident
# starved the fleet for 33h this way: consecutive_failure_count hit 43/23/20
# and pick_seat stayed NO USABLE SEAT even after the bin was restored, because
# the benches had to be quarantined by hand.
#
# Gate: every bench writer first asks _transport_is_down. If the transport is
# down, it writes NOTHING per-seat and instead records one transport-down
# marker (the run is charged to transport, never to the seat). On transport
# recovery the pi-transport-self-heal wrapper sweeps poisoned benches; this
# gate ensures no NEW ones are written while the bin is clobbered.
#
# Fail-open: if pi-transport-check is unavailable or
# PI_SEAT_LIB_CHECK_TRANSPORT=0 (tests), the gate is skipped so benching is
# not suppressed on a box without the probe. The probe is the existing guard
# (cli.js shebang+size+--version); a cheap `pi --version` semver test is the
# fallback when the probe bin is absent.
SEAT_TRANSPORT_DOWN_MARKER="${SEAT_TRANSPORT_DOWN_MARKER:-$STATE_DIR/transport-down.json}"
PI_SEAT_LIB_CHECK_TRANSPORT="${PI_SEAT_LIB_CHECK_TRANSPORT:-1}"

_transport_is_down() {
    (( ${PI_SEAT_LIB_CHECK_TRANSPORT:-1} )) || return 1
    local probe="${PI_TRANSPORT_CHECK:-/home/nish/.local/bin/pi-transport-check}"
    if [[ -x "$probe" ]]; then
        "$probe" >/dev/null 2>&1 || return 0
        return 1
    fi
    # Fleet-ops#3111 contract: "benching is not suppressed on a box without
    # the probe." Probe ABSENT -> health is undeterminable, not down —
    # fail-open, unconditionally. The old `pi --version` fallback here broke
    # that contract: every P14 test stubs PI_BIN with a fake pi whose
    # --version is not semver, so CI judged the transport DOWN and every
    # bench writer went silent (red on main from #3235 through #3335, run
    # 33901937578: pi-issue-run-noop-bench "per-seat ledger missing"). The
    # probe is what protects real boxes (it detects a clobbered cli.js — the
    # #3238 incident); a box without the probe has no gate and no lie.
    return 1
}

# Record one transport-down marker (idempotent per down-window: refreshes the
# timestamp so a single marker spans the whole outage). Best-effort: a write
# failure never blocks the caller's fail-open path.
_mark_transport_down() {
    local p="$1" m="$2"
    local dir
    dir=$(dirname "$SEAT_TRANSPORT_DOWN_MARKER" 2>/dev/null || echo "$STATE_DIR")
    mkdir -p "$dir" 2>/dev/null || return 0
    local now_utc
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local tmp="$SEAT_TRANSPORT_DOWN_MARKER.$$.$RANDOM.tmp"
    jq -nc --arg ts "$now_utc" --arg p "$p" --arg m "$m" \
        '{transport:"down", observed_at:$ts, last_charged_provider:$p, last_charged_model:$m}' \
        >"$tmp" 2>/dev/null && chmod 0644 "$tmp" 2>/dev/null && mv -f "$tmp" "$SEAT_TRANSPORT_DOWN_MARKER" 2>/dev/null \
        || rm -f "$tmp" 2>/dev/null || true
    seat_log "transport-down: $p/$m run charged to TRANSPORT, not the seat (pi-transport-check failed) — no per-seat bench written (fleet-ops#3111)"
    return 0
}

mark_seat_spawn_fail() {
    local p="$1" m="$2" reason="${3:-spawn_etimeout}"
    # fleet-ops#3661: never write a ledger for a phantom seat key.
    if ! _seat_key_guard "$p" "$m" "mark_seat_spawn_fail"; then return 1; fi
    # fleet-ops#4640: no_block:rc=N is a wrapper exit with no HTTP status.
    # A wall length is a claim about the PROVIDER; a wrapper exit code is
    # evidence about the LANE. Log LANE-FAULT and leave the ledger untouched.
    if [[ "$reason" == no_block:rc=* ]]; then
        seat_log "LANE-FAULT: $p/$m reason=$reason has no provider HTTP status — ledger untouched (fleet-ops#4640)"
        return 1
    fi
    if _transport_is_down; then _mark_transport_down "$p" "$m"; return 1; fi
    local path
    path=$(seat_ledger_path "$p" "$m")
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true
    local tmp="$path.spawn.$$.$RANDOM.tmp"
    local now_utc
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Merge consecutive_failure_count from the wrapper's clobber-proof
    # spawn-bench marker FIRST (any failure_mode, written recently), then
    # the (clobberable) ledger. Take the max as the prior count. A STALE
    # marker (older than EMPTY_RUN_MARKER_FRESH_S) means seat-health.ts
    # produced a healthy observation AFTER the bench expired — the recovery
    # signal — so fall through to the ledger and start fresh. The marker is
    # a SINGLE file per seat shared by mark_seat_empty_run and
    # mark_seat_spawn_fail, so the count must accumulate across
    # failure_mode classes (fleet-ops#2786: a seat that alternates between
    # empty_run and spawn_fail must still reach the failure-ceiling park;
    # reading only the clobberable ledger lets a healthy observation reset
    # the count to 0 between wrapper writes — the same #2627 reset pattern
    # the marker was built to bust).
    # fleet-ops#3749: class-aware freshness. The marker is a SINGLE file
    # shared by mark_seat_empty_run and mark_seat_spawn_fail, so a
    # spawn-fail write can clobber an empty-run marker. The empty-run
    # writer uses EMPTY_RUN_COUNT_WINDOW_S (24 h) for freshness; if the
    # spawn-fail writer applied its own 30 min window to an empty-run
    # marker, a spawn-fail >30 min after an empty-run would treat the
    # marker as stale, reset the count to 1, and overwrite the file —
    # destroying the empty-run count the #2786 cross-class contract is
    # meant to preserve. Live: ollama/<retired-V4-flash> reached
    # count=5/backoff=14400s at 22:49Z, a spawn-fail ~37 min later reset
    # the count to 1, and the next empty-run merged from the clobbered
    # marker + ledger to count=4 — the count went BACKWARDS. Use the
    # empty-run window when the marker was written by empty_run, and the
    # spawn-fail window (30 min) otherwise. spawn_fail -> spawn_fail
    # still resets after 30 min (spawn storms are clustered); only the
    # cross-class empty_run -> spawn_fail case widens.
    local prev_count=0 sb_mcount sb_written sb_marker_path now_s written_s sb_fmode sb_window
    sb_marker_path=$(seat_spawn_bench_path "$p" "$m")
    if [[ -f "$sb_marker_path" ]]; then
        sb_mcount=$(jq -r '.consecutive_failure_count // 0' "$sb_marker_path" 2>/dev/null || echo 0)
        [[ "$sb_mcount" =~ ^[0-9]+$ ]] || sb_mcount=0
        sb_written=$(jq -r '.written_at // ""' "$sb_marker_path" 2>/dev/null || true)
        sb_fmode=$(jq -r '.failure_mode // ""' "$sb_marker_path" 2>/dev/null || true)
        if [[ "$sb_fmode" == "empty_run" ]]; then
            sb_window="${EMPTY_RUN_COUNT_WINDOW_S:-86400}"
        else
            sb_window="${EMPTY_RUN_MARKER_FRESH_S:-1800}"
        fi
        if [[ -n "$sb_written" ]]; then
            now_s=$(date -u +%s)
            written_s=$(date -u -d "$sb_written" +%s 2>/dev/null || echo 0)
            if [[ "$written_s" =~ ^[0-9]+$ ]] && (( written_s > 0 )) \
                && (( now_s - written_s <= sb_window )); then
                prev_count="$sb_mcount"
            fi
        fi
    fi
    if [[ -f "$path" ]]; then
        local ledger_count
        ledger_count=$(jq -r '.consecutive_failure_count // 0' "$path" 2>/dev/null || echo 0)
        [[ "$ledger_count" =~ ^[0-9]+$ ]] || ledger_count=0
        [[ "$ledger_count" -gt "$prev_count" ]] && prev_count="$ledger_count"
    fi
    local merged_count=$((prev_count + 1))
    # fleet-ops#1408: escalate the bench by consecutive_failure_count so a
    # seat that no-ops or spawn-fails in a loop stays benched longer each
    # cycle instead of re-entering rotation every base-backoff seconds.
    local backoff
    backoff=$(_escalated_backoff "$SPAWN_FAIL_BACKOFF_S" "$merged_count" "$SPAWN_FAIL_BACKOFF_CAP_S")
    # fleet-ops#1362: once count crosses the failure ceiling, park the seat
    # behind the long wall so the prober stops hammering it every base backoff.
    backoff=$(_failure_ceiling_wall "$merged_count" "$backoff")
    # fleet-ops#4640: spawn_fail has no provider HTTP status. Cap at 6h.
    backoff=$(_seat_clamp_non_money_window_s "$backoff" "")
    # Compute usable_at = now + backoff (ISO 8601, bash portable: -d @ + offsets).
    local usable_at
    usable_at=$(date -u -d "@$(($(date -u +%s) + backoff))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")

    # fleet-ops#3889: corpse reclassification for a CHRONIC spawn_fail streak.
    # seat-health.ts logs a transport 200 as healthy during the very run that
    # then exits 0 with 0-byte stdout (after_provider_response carries status+
    # headers only, never the body), so the LEDGER stays health_class=healthy /
    # http 200 / seat_dead=false while the wrapper's benchmark climbs forever —
    # live xkiro/<retired-V4-flash> reached 47 consecutive spawn_fail with the
    # ledger healthy, re-offered every flat 24h park-wall expiry. Mirror the
    # quota writer (fleet-ops#2594): once merged_count crosses
    # SEAT_DEAD_CONSECUTIVE_THRESHOLD (default 25, matching seat-health.ts) the
    # spawn_fail bench is written seat_dead=true so the seat is classed a
    # CORPSE regardless of the HTTP 200, the roster/census count it dead, and
    # seat_usable holds it terminally (only a recovery probe re-proves it). The
    # corpse is ALSO carried onto the clobber-proof spawn-bench marker so the
    # false-healthy ledger clobber cannot resurrect it.
    local seat_dead=false
    if _seat_dead_by_threshold "$merged_count"; then
        seat_dead=true
    fi

    if ! jq -nc \
        --arg provider "$p" --arg model "$m" --arg reason "$reason" \
        --arg observed "$now_utc" --arg usable "$usable_at" \
        --argjson http_status 0 --argjson retry_after null \
        --argjson retryable true --argjson seat_dead "$seat_dead" --argjson poison_ladder false \
        --argjson backoff "$backoff" --argjson merged "$merged_count" \
        --arg writer "mark_seat_spawn_fail" \
        '{
          provider:$provider, model:$model,
          http_status:$http_status, retry_after:$retry_after,
          health_class:"transient_fault",
          retryable:$retryable, seat_dead:$seat_dead, poison_ladder:$poison_ladder,
          observed_at:$observed,
          source:"cli_timeout",
          failure_mode:"cli_timeout",
          usable_at:$usable,
          consecutive_failure_count:$merged,
          spawn_fail_reason:$reason,
          spawn_fail_backoff_s:$backoff,
          writer:$writer
        }' > "$tmp" 2>/dev/null; then
        seat_log "spawn-fail: jq compose FAILED for $p/$m (reason=$reason) — marker NOT written"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 0644 "$tmp" 2>/dev/null || true
    if mv "$tmp" "$path" 2>/dev/null; then
        if [[ "$seat_dead" == "true" ]]; then
            seat_log "spawn-fail: $p/$m CORPSE reclassified (count=$merged_count >= ${SEAT_DEAD_CONSECUTIVE_THRESHOLD}); usable_at=$usable_at kept as comeback clock (fleet-ops#3889); re-released only by a recovery probe / healthy observation clears seat_dead=false"
        else
            seat_log "spawn-fail: marked $p/$m unusable until $usable_at (reason=$reason, backoff=${backoff}s, count=$merged_count)"
            if _seat_parked_by_ceiling "$merged_count"; then
                _emit_failure_ceiling_metric "$p" "$m" "$merged_count"
                seat_log "spawn-fail: $p/$m PARKED past failure ceiling (count=$merged_count >= ${SEAT_FAILURE_CEILING}, wall=${backoff}s)"
            fi
        fi
        # fleet-ops#1512: also write the clobber-proof spawn-bench marker so
        # seat_usable honours this bench even if seat-health.ts later writes a
        # healthy observation to the ledger. Best-effort: a marker write
        # failure does not undo the ledger write above. fleet-ops#2627: also
        # carry the consecutive_failure_count and failure_mode so the marker
        # is the durable count authority for the bench class — the ledger's
        # count is reset to 0 by seat-health.ts's healthy clobber, and the
        # failure-ceiling park must engage from the marker-carried count.
        # fleet-ops#3889: a spawn_fail corpse (seat_dead=true) is carried onto
        # the marker too so the false-healthy 200 clobber cannot resurrect it.
        _seat_write_spawn_bench "$p" "$m" "$usable_at" "$reason" "$backoff" "$merged_count" "spawn_fail" "$seat_dead" 2>/dev/null || true
        return 0
    fi
    seat_log "spawn-fail: rename FAILED for $p/$m at $path (reason=$reason)"
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# --- empty-run bench (fleet-ops#902) ---------------------------------------
# A run where pi exits 0 but the only output is a PACKET-VERDICT tools=0
# verdict (no final text) is an EMPTY RUN — the seat accepted the packet,
# spent the tokens, and produced nothing (the devin lane #902 gap: exit 0,
# zero output, silently counted as success). It is a retryable LANE FAULT,
# not proof the seat is dead: bench it for a short cooldown
# (EMPTY_RUN_BACKOFF_S, default 900s = 15 min, matching seat-health.ts's
# empty_run mode) so pick_seat skips it and the packet is re-routed to the
# next healthy seat, then fail-opens (auto re-eligible — no manual re-arm,
# no permanent demotion, no two-strikes charge to the packet).
#
# The seat-health.ts extension writes the same empty_run marker from inside
# pi (classifyCliOutput of an empty CLI routes to the empty_run mode); this
# is the deterministic wrapper-side counterpart pi-issue-run calls on the
# exact run that produced the empty verdict, so the bench is written even if
# the extension is not wired. Ledger shape is byte-compatible with
# SeatLedgerEntry (seat-health.ts); seat_usable skips via the generic
# usable_at check and fail-opens after.
# fleet-ops#2343: an empty run is a provider NO-OP, not a quota wall, and
# must NOT escalate by count. The fleet-ops#1408 ladder (900 -> 1800 -> 3600
# -> 7200s) churned HEALTHY seats: openrouter/deepseek/deepseek-v4.1-flash
# produced 3 empty runs in 2h (fleet-ops-1384, stdout=0B), got benched 900s
# and re-seated in-process each time, and the count ladder kept extending a
# working seat's bench to hours after a handful of no-ops. The no-op cooldown
# is FLAT: every empty run benches for EMPTY_RUN_BACKOFF_S, and only the
# fleet-ops#1362 failure-ceiling park (60 consecutive failures = 24h wall, the
# extreme dead-seat guard) ever lengthens it. The count still merges for
# observability and for that ceiling, but it does not drive a bench ladder the
# way a real quota/rate/5xx wall (mark_seat_spawn_fail) does. Recovery is one
# successful run (count -> 0 via seat-health.ts).
#
# fleet-ops#2627: the count must ACCUMULATE across healthy ledger clobbers.
# seat-health.ts writes health_class=healthy/count=0 to the ledger on a later
# 200 observation, so reading only the ledger lets a chronic no-op'er reset
# its count to 0 between every wrapper write (live: openrouter/deepseek/
# <retired-V4-flash>-0731 no-op'ed 5+ times in 2h with every ledger write
# showing count=1, the #1362 park never fired, 18 empty runs/2h). The
# wrapper-side spawn-bench marker (fleet-ops#1512) is clobber-proof — read
# the count from the marker FIRST (any failure_mode, written recently),
# fall back to the ledger, take the max as the prior count, then pass the
# merged count +1 to the marker writer so the marker carries it forward
# across the next clobber. EMPTY_RUN_MARKER_FRESH_S bounds the merge: a
# STALE marker means the seat produced a healthy observation after the
# bench expired (count was reset to 0 by seat-health.ts — the recovery
# signal), so fall through to the ledger and start a fresh count.
# fleet-ops#2786: the marker is a SINGLE file per seat shared by both
# mark_seat_empty_run and mark_seat_spawn_fail. A same-class-only merge
# (the original #2627 design) loses the empty_run count the instant a
# spawn_fail marker overwrites the file — live: opencode/nemotron-3-ultra-free
# produced 10 empty runs over 3 days, every marker showing count=1 because
# a spawn_fail marker sat between empty runs and the same-class check
# skipped it. The fix: merge the count from ANY recent marker regardless
# of failure_mode. The counts share one file, so cross-class accumulation
# is the only way the failure-ceiling park ever fires for a seat that
# alternates between empty_run and spawn_fail. fleet-ops#3531: the bench
# now escalates geometrically (base * 2^(n-1), capped at 6 h, 1800 s for
# remote agents) and uses the generic SEAT_FAILURE_CEILING (default 20) so
# a free-lane no-op'er parks at the same threshold as any other wall.
# fleet-ops#3046: the prior default of 10 was too high for the live
# nemotron-3-ultra-free loop — 9 empty runs in 2h on the same issue
# (fleet-ops-2778) never reached 10 because the count-merge window
# (EMPTY_RUN_COUNT_WINDOW_S, 6 h) reset the count on every 3rd run as the
# 6 h window slid past the first no-op. A ceiling of 3 parks the seat
# on the 3rd no-op in the SAME 6 h window, so the loop cannot outpace the
# count-merge window the way 10 did. fleet-ops#3531: the bench now
# escalates geometrically (base * 2^(n-1), capped at 6 h, 1800 s for
# remote agents) so a repeat no-op'er is held out of rotation longer even
# before the failure-ceiling park.
#
# fleet-ops#2934: the count-merge window for EMPTY RUNS is LONGER than the
# spawn-fail window. EMPTY_RUN_MARKER_FRESH_S (30 min) was the merge bound
# for BOTH classes, but an intermittent no-op'er gaps its empty runs by
# more than 30 min (live 2026-09-02: openrouter/deepseek/deepseek-v4.1-flash-
# 0731 no-op'ed at 18:40:08Z count=2, then 20:22:31Z count=1 — the 1h42m
# gap aged the marker past 30 min, the count reset, the ceiling never
# fired, the seat re-entered rotation every 900 s and no-op'ed again). A
# provider no-op is intermittent, not clustered the way a spawn-fail storm
# is, so the recovery signal (no new empty run for N min) needs a longer
# N to be trustworthy. fleet-ops#3675: EMPTY_RUN_COUNT_WINDOW_S was widened
# from 2 h to the max empty-run bench (SEAT_BENCH_GEOMETRIC_CAP_S, 6 h) so a
# chronic no-op'er's count survives the geometric bench. fleet-ops#3666: that
# was still shorter than the failure-ceiling park wall (SEAT_PARK_WALL_S,
# 24 h). A parked seat is held out of rotation by its marker's usable_at for
# the full 24 h, so "no new empty run for 6 h" is NOT a recovery signal for a
# parked seat — it is just the park holding. The global seat-health probe can
# clobber the ledger to health_class=healthy/count=0 during the park (a 200
# HTTP observation on a no-op'ing seat), so once the marker aged past 6 h the
# count-merge fell through to the clobbered ledger, the count reset to 1, and
# the next no-op at the 24 h boundary dropped the bench back to the 900 s base
# — the 24 h park was overwritten by a 30 min flat cooldown and the dead seat
# re-entered the no-op loop (live: ollama/<retired-V4-flash>, 24 no-op
# runs/2h, 86400 s bench written then lost). The window now defaults to the
# PARK WALL (SEAT_PARK_WALL_S, 24 h) so the marker-carried count survives the
# full park: a no-op at the 24 h boundary merges the marker count (not the
# clobbered ledger), re-parks immediately, and the seat stays out of rotation.
# A marker older than 24 h means the seat went a full park wall without being
# probed AND without no-op'ing — the real recovery signal — so the count
# resets. spawn_fail keeps the 30-min window (spawn storms are clustered; a
# 24 h spawn-fail window would let a long-ago spawn_fail inflate a fresh
# empty-run count). The bench escalates geometrically (fleet-ops#3531); the
# COUNT-accumulation window now spans the full park, so the failure-ceiling
# park persists across the boundary instead of resetting to the base.
EMPTY_RUN_BACKOFF_S="${EMPTY_RUN_BACKOFF_S:-900}"  # 15 min
EMPTY_RUN_MARKER_FRESH_S="${EMPTY_RUN_MARKER_FRESH_S:-1800}"  # 30 min — spawn-fail count-merge window (see comment above)
# default = park wall (24 h) so a chronic no-op'er's count survives the full
# failure-ceiling park, not just the geometric bench cap (fleet-ops#3666).
EMPTY_RUN_COUNT_WINDOW_S="${EMPTY_RUN_COUNT_WINDOW_S:-$SEAT_PARK_WALL_S}"
# fleet-ops#3727: a SEPARATE, lower failure ceiling for empty runs. The generic
# SEAT_FAILURE_CEILING (default 20) was unified in fleet-ops#3531, but a chronic
# no-op'er (ollama/<retired-V4-flash>, 12 empty runs in 2h) churned for 20
# cycles before the 24h park engaged — the geometric cap (6h) re-offered the
# seat every 6h and the count climbed too slowly. A provider no-op is a LANE
# FAULT, not a quota wall: a few no-ops in the same 24h count-merge window is a
# strong signal the seat is functionally dead for agentic work, so park it
# behind the 24h wall instead of the 20th. The generic ceiling still applies to
# spawn_fail / quota / overload (real walls that recover differently). Tests
# that pin a low ceiling for empty-run park isolation set BOTH
# SEAT_FAILURE_CEILING and EMPTY_RUN_FAILURE_CEILING.
# fleet-ops#3760: lowered from 5 to 3. The 12-empty-runs-in-2h churn (4 issues
# filed this week: #3749/#3737/#3730/#3727) showed 5 was still too slow to
# converge — the geometric bench (900s -> 1800s -> 3600s -> 7200s) re-offered
# the seat four times before the 24h park, and any count-merge reset let it
# churn again. 3 no-ops in the 24h count-merge window parks on the 3rd no-op:
# the geometric bench holds (900s -> 1800s) for the first two, then the 24h
# wall fires. This is the max_bench_retries cap from the #3760 spec.
EMPTY_RUN_FAILURE_CEILING="${EMPTY_RUN_FAILURE_CEILING:-3}"

mark_seat_empty_run() {
    local p="$1" m="$2" reason="${3:-empty_run}"
    # fleet-ops#3661: never write a ledger for a phantom seat key.
    if ! _seat_key_guard "$p" "$m" "mark_seat_empty_run"; then return 1; fi
    if _transport_is_down; then _mark_transport_down "$p" "$m"; return 1; fi
    local path
    path=$(seat_ledger_path "$p" "$m")
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true
    local tmp="$path.empty.$$.$RANDOM.tmp"
    local now_utc
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # fleet-ops#2627/#2786: merge consecutive_failure_count from the
    # wrapper's clobber-proof spawn-bench marker FIRST (any failure_mode,
    # written recently), then the (clobberable) ledger. Take the max as
    # the prior count. A STALE marker (older than
    # EMPTY_RUN_COUNT_WINDOW_S, default 24 h = SEAT_PARK_WALL_S — fleet-ops#3666)
    # means the seat went a full park wall without no-op'ing — the real
    # recovery signal — so we fall through to the ledger (which seat-health.ts
    # clobbered to count=0) and start fresh. The window is LONGER than
    # mark_seat_spawn_fail's (EMPTY_RUN_MARKER_FRESH_S, 30 min) because a
    # provider no-op is intermittent, not clustered: a 30 min window let a
    # ~1h42m gap reset the count on the live <retired-V4-flash>-0731 seat
    # so the failure-ceiling park never fired. The marker is a SINGLE file
    # per seat shared by mark_seat_empty_run and mark_seat_spawn_fail, so
    # the count must accumulate across failure_mode classes (fleet-ops#2786:
    # a same-class-only merge lost the empty_run count the instant a
    # spawn_fail marker overwrote the file — live: 10 empty runs on
    # opencode/nemotron-3-ultra-free, every marker count=1).
    # fleet-ops#3749 (symmetric completion): class-aware freshness, mirroring
    # the #3849 fix in mark_seat_spawn_fail. The marker is a SINGLE file shared
    # by mark_seat_empty_run and mark_seat_spawn_fail, so an empty-run write can
    # read a marker left by a spawn_fail. The empty-run writer used
    # EMPTY_RUN_COUNT_WINDOW_S (24 h) for ALL markers, including spawn_fail
    # markers — so a spawn_fail marker older than the 30 min spawn-fail window
    # but inside 24 h was merged into a fresh empty-run count, inflating it
    # (the very inflation the comment above warns against: "a 24 h spawn-fail
    # window would let a long-ago spawn_fail inflate a fresh empty-run count").
    # spawn storms are clustered (30 min): a spawn_fail older than 30 min is
    # stale, the spawn problem is over, and a fresh empty-run is a separate
    # fault — the spawn_fail count must NOT carry over. Use the marker's
    # failure_mode to select the window: an empty_run marker uses
    # EMPTY_RUN_COUNT_WINDOW_S (24 h); a spawn_fail marker uses
    # EMPTY_RUN_MARKER_FRESH_S (30 min). empty_run -> empty_run still uses the
    # 24 h window (intermittent, long recovery signal); only the cross-class
    # spawn_fail -> empty_run case narrows to the spawn-fail window.
    local prev_count=0 sb_mcount sb_written sb_marker_path now_s written_s sb_fmode sb_window
    sb_marker_path=$(seat_spawn_bench_path "$p" "$m")
    if [[ -f "$sb_marker_path" ]]; then
        sb_mcount=$(jq -r '.consecutive_failure_count // 0' "$sb_marker_path" 2>/dev/null || echo 0)
        [[ "$sb_mcount" =~ ^[0-9]+$ ]] || sb_mcount=0
        sb_written=$(jq -r '.written_at // ""' "$sb_marker_path" 2>/dev/null || true)
        sb_fmode=$(jq -r '.failure_mode // ""' "$sb_marker_path" 2>/dev/null || true)
        if [[ "$sb_fmode" == "empty_run" ]]; then
            sb_window="${EMPTY_RUN_COUNT_WINDOW_S:-$SEAT_PARK_WALL_S}"
        else
            sb_window="${EMPTY_RUN_MARKER_FRESH_S:-1800}"
        fi
        if [[ -n "$sb_written" ]]; then
            now_s=$(date -u +%s)
            written_s=$(date -u -d "$sb_written" +%s 2>/dev/null || echo 0)
            if [[ "$written_s" =~ ^[0-9]+$ ]] && (( written_s > 0 )) \
                && (( now_s - written_s <= sb_window )); then
                prev_count="$sb_mcount"
            fi
        fi
    fi
    if [[ -f "$path" ]]; then
        local ledger_count
        ledger_count=$(jq -r '.consecutive_failure_count // 0' "$path" 2>/dev/null || echo 0)
        [[ "$ledger_count" =~ ^[0-9]+$ ]] || ledger_count=0
        [[ "$ledger_count" -gt "$prev_count" ]] && prev_count="$ledger_count"
    fi
    local merged_count=$((prev_count + 1))
    # fleet-ops#3531: empty runs now escalate geometrically by count
    # (base * 2^(n-1), capped at 6 h). Remote agents (e.g. devin) run outside
    # the local harness, so a false empty run is capped at 30 min (1800 s) to
    # avoid punishing a healthy remote seat — the tighter cap applies only to
    # prepaid-quota seats (a paid seat idled by a false verdict is real
    # money). The long failure-ceiling park (SEAT_PARK_WALL_S, default 24 h)
    # still applies on top. fleet-ops#3727: empty runs use a SEPARATE, lower
    # failure ceiling (EMPTY_RUN_FAILURE_CEILING, default 3 per fleet-ops#3760)
    # so a chronic no-op'er parks on the 3rd no-op, not the 20th — the generic
    # 20 let ollama/<retired-V4-flash> churn 12 empty runs in 2h without
    # parking.
    local cap
    cap="$SEAT_BENCH_GEOMETRIC_CAP_S"
    if provider_remote_agent "$p" && [[ "$(model_class_of "$p" "$m")" == "prepaid-quota" ]]; then
        cap="$SEAT_REMOTE_AGENT_EMPTY_RUN_CAP_S"
    fi
    local backoff
    backoff=$(_geometric_bench_window "$EMPTY_RUN_BACKOFF_S" "$merged_count" "$cap" "$EMPTY_RUN_FAILURE_CEILING")
    # fleet-ops#4640: empty_run is a lane no-op, not a provider wall.
    backoff=$(_seat_clamp_non_money_window_s "$backoff" "")
    # Compute usable_at = now + backoff (ISO 8601, bash portable).
    local usable_at
    usable_at=$(date -u -d "@$(($(date -u +%s) + backoff))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")

    if ! jq -nc \
        --arg provider "$p" --arg model "$m" --arg reason "$reason" \
        --arg observed "$now_utc" --arg usable "$usable_at" \
        --argjson http_status 200 --argjson retry_after null \
        --argjson retryable true --argjson seat_dead false --argjson poison_ladder false \
        --argjson backoff "$backoff" --argjson merged "$merged_count" \
        --arg writer "mark_seat_empty_run" \
        '{
          provider:$provider, model:$model,
          http_status:$http_status, retry_after:$retry_after,
          health_class:"transient_fault",
          retryable:$retryable, seat_dead:$seat_dead, poison_ladder:$poison_ladder,
          observed_at:$observed,
          source:"cli_spawn",
          failure_mode:"empty_run",
          usable_at:$usable,
          consecutive_failure_count:$merged,
          empty_run_reason:$reason,
          empty_run_backoff_s:$backoff,
          writer:$writer
        }' > "$tmp" 2>/dev/null; then
        seat_log "empty-run: jq compose FAILED for $p/$m (reason=$reason) — marker NOT written"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 0644 "$tmp" 2>/dev/null || true
    if mv "$tmp" "$path" 2>/dev/null; then
        seat_log "empty-run: marked $p/$m unusable until $usable_at (reason=$reason, backoff=${backoff}s, count=$merged_count)"
        # fleet-ops#3727: park check uses the empty-run-specific failure ceiling
        # (EMPTY_RUN_FAILURE_CEILING, default 3 per fleet-ops#3760). The
        # geometric backoff (capped at 6 h, 1800 s for remote agents) grows the
        # bench below the ceiling; once crossed, the seat is parked behind the
        # long wall.
        if _seat_parked_by_ceiling "$merged_count" "$EMPTY_RUN_FAILURE_CEILING"; then
            _emit_failure_ceiling_metric "$p" "$m" "$merged_count"
            seat_log "empty-run: $p/$m PARKED past failure ceiling (count=$merged_count >= ${EMPTY_RUN_FAILURE_CEILING}, wall=${backoff}s)"
        fi
        # fleet-ops#1512: clobber-proof spawn-bench marker (same rationale as
        # mark_seat_spawn_fail). fleet-ops#2627: also carry the
        # consecutive_failure_count and failure_mode=empty_run so the next
        # empty-run call merges from this marker across any healthy ledger
        # clobber, and the chronic-no-op park engages from the durable count.
        # fleet-ops#3602: the marker write is NOT best-effort. The ledger is
        # co-written by seat-health.ts, which clobbers it back to
        # health_class=healthy / count=0 / usable_at=null on a later HTTP-200
        # observation (a different worker's simple packet). When the marker
        # write failed silently (the old `2>/dev/null || true`), the bench
        # lived ONLY in the clobberable ledger, the next 200 probe cleared it,
        # and pick_seat re-offered the no-op'ing seat — live
        # ollama/<retired-V4-flash> was re-benched 8x in 2h (count=6,7,8)
        # yet still offered healthy. The marker is the survival mechanism, so
        # a marker write failure fails LOUD (return 1): the bench either has a
        # clobber-proof marker that survives until wall_end, or the caller
        # (pi-issue-run) logs the failure and falls back to tried-seats
        # exclusion for the current run — never a silent degradation to a
        # clobberable-only bench.
        if ! _seat_write_spawn_bench "$p" "$m" "$usable_at" "$reason" "$backoff" "$merged_count" "empty_run" 2>/dev/null; then
            seat_log "empty-run: LOUD marker-write FAILED for $p/$m at $sb_marker_path (reason=$reason) — bench NOT clobber-proof, relying on tried-seats exclusion (fleet-ops#3602)"
            return 1
        fi
        return 0
    fi
    seat_log "empty-run: rename FAILED for $p/$m at $path (reason=$reason)"
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# --- worked-no-text bench (fleet-ops#3847) --------------------------------
# fleet-ops#3714 taught pi-issue-run that a session which made tool calls did
# real work: when a model ends its turn ON a tool call (<retired-V4-flash>
# via ollama closes with structured_output and no trailing text), pi --print
# emits no final text, so stdout is 0B while the verdict on stderr already says
# tools=N class=worked. Those runs are NOT provider no-ops and must not be
# benched as empty runs. But a single 0B-stdout run is not proof of a broken
# seat either — it is the live 2026-09-06 case (fleet-ops#3847):
# ollama/<retired-V4-flash> produced 0B final text on 5/5 runs in 2h
# (fleet-ops-3714, 0509-1731, fleet-ops-3727, fleet-ops-3322, fleet-ops-3730;
# 197 tool calls, zero deliverables) and each was classified worked-no-text and
# deliberately NOT benched. Whatever the classification, N consecutive
# 0B-stdout runs is a broken seat. These helpers keep a per-seat counter of
# consecutive worked-no-text runs (durable, across separate pi-issue-run
# invocations and across issues) and bench the seat via mark_seat_empty_run
# once the count reaches WORKED_NO_TEXT_THRESHOLD. The counter resets on a
# real-output run (out_bytes >= OUT_MIN) and on the bench itself.
WORKED_NO_TEXT_THRESHOLD="${WORKED_NO_TEXT_THRESHOLD:-5}"
# A worked-no-text run that happened more than this many seconds ago is stale
# (the seat went a healthy stretch in between) and starts a fresh count.
WORKED_NO_TEXT_WINDOW_S="${WORKED_NO_TEXT_WINDOW_S:-7200}"  # 2 h

seat_worked_no_text_path() {
    local p="$1" m="$2" ps ms
    ps="${p//[^A-Za-z0-9._-]/_}"
    ms="${m//[^A-Za-z0-9._-]/_}"
    printf '%s/%s__%s.worked-no-text.json\n' "$LEDGER_DIR" "$ps" "$ms"
}

# Increment the per-seat consecutive worked-no-text counter and, once it
# reaches WORKED_NO_TEXT_THRESHOLD, bench the seat via mark_seat_empty_run and
# reset the counter. Returns 0 (bench fired) when the threshold is reached,
# 1 otherwise. Best-effort: a counter write failure must not block the
# caller's fall-through (the run is still treated as worked-no-text).
mark_seat_worked_no_text() {
    local p="$1" m="$2" reason="${3:-worked-no-text}"
    if ! _seat_key_guard "$p" "$m" "mark_seat_worked_no_text"; then return 1; fi
    local path now_utc now_s prev prev_written written_s count tmp
    path=$(seat_worked_no_text_path "$p" "$m")
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    now_s=$(date -u +%s)
    prev=0
    if [[ -f "$path" ]]; then
        prev=$(jq -r '.consecutive_worked_no_text // 0' "$path" 2>/dev/null || echo 0)
        [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
        prev_written=$(jq -r '.written_at // ""' "$path" 2>/dev/null || true)
        if [[ -n "$prev_written" ]]; then
            written_s=$(date -u -d "$prev_written" +%s 2>/dev/null || echo 0)
            if [[ "$written_s" =~ ^[0-9]+$ ]] && (( written_s > 0 )) \
                && (( now_s - written_s > ${WORKED_NO_TEXT_WINDOW_S:-7200} )); then
                prev=0  # stale: a healthy stretch elapsed, start fresh
            fi
        fi
    fi
    count=$((prev + 1))
    tmp="$path.$$.$RANDOM.tmp"
    if jq -nc --arg p "$p" --arg m "$m" --arg written "$now_utc" --arg reason "$reason" \
        --argjson count "$count" \
        '{provider:$p, model:$m, consecutive_worked_no_text:$count, written_at:$written, reason:$reason}' \
        >"$tmp" 2>/dev/null; then
        chmod 0644 "$tmp" 2>/dev/null || true
        mv "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; }
    else
        rm -f "$tmp" 2>/dev/null || true
    fi
    seat_log "worked-no-text: $p/$m consecutive 0B-stdout runs = $count (threshold ${WORKED_NO_TEXT_THRESHOLD:-5})"
    if (( count >= ${WORKED_NO_TEXT_THRESHOLD:-5} )); then
        seat_log "worked-no-text: $p/$m hit ${count} consecutive 0B-stdout runs — BENCHING via empty_run (fleet-ops#3847)"
        mark_seat_empty_run "$p" "$m" "pi-issue:worked-no-text:x${count}:${reason}" || true
        rm -f "$path" 2>/dev/null || true  # reset after the bench
        return 0
    fi
    return 1
}

# Reset the per-seat consecutive worked-no-text counter. Called on a real-output
# run (out_bytes >= OUT_MIN) so a recovered seat starts fresh.
reset_seat_worked_no_text() {
    local p="$1" m="$2" path
    path=$(seat_worked_no_text_path "$p" "$m")
    rm -f "$path" 2>/dev/null || true
}

seat_empty_success_path() {
    local p="$1" m="$2" ps ms
    ps="${p//[^A-Za-z0-9._-]/_}"
    ms="${m//[^A-Za-z0-9._-]/_}"
    printf '%s/%s__%s.empty-success.json\n' "$LEDGER_DIR" "$ps" "$ms"
}

# --- empty-success ledger (fleet-ops#4457) --------------------------------
# A run that ends SUCCESS (real output, exit 0) but opened NO PR and did NOT
# close the issue is an EMPTY-SUCCESS: the seat burned a full session and the
# work shipped nothing. It is a WASTE class (the issue's 51% blind spot — 127
# sessions logged "SUCCESS" but only 62 shipped), distinct from the empty-run
# (tools=0, no final text) which is already benched. An empty-success is NOT a
# seat fault to bench (the seat produced real text) — it is a wasted claim to
# COUNT. This writes/increments a per-seat counter so the hourly judge can
# measure the empty-success share per seat and name the top offenders
# (measure.sh `waste:` line, fleet-ops#4457). Best-effort: a write failure must
# never block the caller's exit-0 success path.
mark_seat_empty_success() {
    local p="$1" m="$2" output_bytes="${3:-0}" reason="${4:-}"
    if ! _seat_key_guard "$p" "$m" "mark_seat_empty_success"; then return 0; fi
    local path now_utc prev count tmp
    path=$(seat_empty_success_path "$p" "$m")
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    prev=0
    if [[ -f "$path" ]]; then
        prev=$(jq -r '.empty_success_count // 0' "$path" 2>/dev/null || echo 0)
        [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
    fi
    count=$((prev + 1))
    tmp="$path.$$.$RANDOM.tmp"
    if jq -nc --arg p "$p" --arg m "$m" --arg written "$now_utc" \
        --argjson count "$count" --argjson bytes "${output_bytes:-0}" --arg reason "$reason" \
        '{provider:$p, model:$m, empty_success_count:$count, last_output_bytes:$bytes, last_occurred_at:$written, reason:$reason}' \
        >"$tmp" 2>/dev/null; then
        chmod 0644 "$tmp" 2>/dev/null || true
        mv "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; }
        seat_log "empty-success: $p/$m count=$count last_output_bytes=$output_bytes (fleet-ops#4457)"
    else
        rm -f "$tmp" 2>/dev/null || true
    fi
    return 0
}

# --- error-class registry dispatch (fleet-ops#859) -----------------------
# Data-driven lane-fault dispatch. seat-caps.json declares an `error_classes`
# map: each class names a matcher function, a writer function, a trigger_order,
# and a default_window_s_seconds. pi-issue-run (and any other caller) invokes
# _dispatch_lane_faults <provider> <model> <out> <err> on a non-zero pi exit;
# it iterates the registry by trigger_order, calling _matcher_dispatch once
# per class, and on the FIRST match calls _writer_dispatch and returns — one
# writer wins, no double-bench. New classes are config-only: add a row to
# seat-caps.json, a matcher function, a case branch in _matcher_dispatch /
# _writer_dispatch, and one regression test.
#
# Why the dispatch tables are a `case` (not eval): bash function dispatch by
# name via eval is fragile under set -euo pipefail and unreadable to auditors.
# A case table is explicit, grep-able, and fails loud on an unregistered name
# instead of silently no-op'ing. Adding a class IS two code edits (case branch
# + seat-caps.json row), not zero — that is the explicit-registration contract:
# a misspelled matcher name must NOT silently resolve to nothing.

# _matcher_dispatch <matcher_name> <out> <err>
# Calls the named matcher function with (out, err). Returns the matcher's
# exit code (0=match, nonzero=no-match). Returns 1 for an unknown name so
# a stale config row is a loud fail, not a silent skip.
_matcher_dispatch() {
    local matcher="$1" out="$2" err="$3"
    case "$matcher" in
        is_openrouter_free_retired_error) is_openrouter_free_retired_error "$out" "$err" ;;
        is_quota_cap_error) is_quota_cap_error "$out" "$err" ;;
        is_overload_error)  is_overload_error "$out" "$err" ;;
        *)                  return 1 ;;
    esac
}

# _writer_dispatch <writer_name> <provider> <model> <text>
# Calls the named writer function with (provider, model, text). Returns the
# writer's exit code (0=marker written, 1=fail-open / no default). Unknown
# names return 1.
_writer_dispatch() {
    local writer="$1" p="$2" m="$3" text="$4"
    case "$writer" in
        mark_seat_free_retired_corpse) mark_seat_free_retired_corpse "$p" "$m" "$text" ;;
        mark_seat_quota_bench)    mark_seat_quota_bench "$p" "$m" "$text" ;;
        mark_seat_overload_bench) mark_seat_overload_bench "$p" "$m" "$text" ;;
        *)                        return 1 ;;
    esac
}

# _load_error_classes [json_path]
# Echoes one class entry per line as: <trigger_order>	<class_name>	<matcher>	<writer>
# Sorted ascending by trigger_order. Returns 1 if the error_classes block is
# missing or empty (callers fall back gracefully — no dispatch, no bench).
_load_error_classes() {
    local json="${1:-$SEAT_CAPS_JSON}"
    [[ -f "$json" ]] || return 1
    jq -r '
      if (.error_classes // {}) | length == 0 then empty
      else
        .error_classes | to_entries[]
        | [.value.trigger_order // 999, .key, (.value.matcher // ""), (.value.writer // "")]
        | @tsv
      end
    ' "$json" 2>/dev/null | sort -t$'	' -k1,1n || true
}

# _dispatch_lane_faults <provider> <model> <out> <err>
# Single entry point for pi-issue-run's post-mortem dispatch. Iterates the
# error_classes registry by trigger_order; the FIRST class whose matcher
# returns 0 fires its writer and the function returns (no later class fires).
# This is the "one writer wins, no double-bench" contract: a body that matches
# two classes (e.g. a 503 storm that also mentions "limit") gets benched by
# the lowest trigger_order class only.
#
# Returns 0 if any class matched and its writer was attempted (whether the
# writer wrote a marker or failed-open), 1 if no class matched.
_dispatch_lane_faults() {
    local p="$1" m="$2" out="$3" err="$4"
    local order cls matcher writer
    while IFS=$'	' read -r order cls matcher writer; do
        [[ -n "$cls" && -n "$matcher" && -n "$writer" ]] || continue
        if _matcher_dispatch "$matcher" "$out" "$err"; then
            if _writer_dispatch "$writer" "$p" "$m" "$out"$'
'"$err"; then
                return 0
            fi
            seat_log "dispatch: $cls matcher fired but writer $writer failed-open for $p/$m"
            return 0
        fi
    done < <(_load_error_classes)
    return 1
}

# --- fast-death error classification (fleet-ops#3766) ----------------------
# A fast death (pi exits non-zero with 0 tool calls) that matches NO existing
# detector leaves the seat ledger at health_class=healthy (a probe overwrote
# it) while pick_seat logged UNUSABLE — the seat flaps between probe-healthy
# and run-dead every few minutes and each flap burns a claim. The seat
# retirement rule (2026-09-05) requires citing the ERROR CLASS before any cap
# change; with no error text nobody can classify the death, so the seat can
# neither be benched honestly nor cleared. These helpers give every fast death
# a classifiable literal: session_tool_calls counts the session, classify_death_error
# reuses the existing matchers to derive an error_class (unknown if none match)
# plus the raw tail, and _seat_merge_error_class writes last_error_class +
# bench_reason into the existing ledger file (a field-merge, not a new organ).

# session_tool_calls <session_jsonl_path>
# Counts completed tool calls in a pi session jsonl. Each toolResult message
# is one tool call that ran. Returns 0 on parse failure (fail-open).
session_tool_calls() {
    local f="${1:-}"
    [[ -n "$f" && -f "$f" ]] || { printf '0'; return 0; }
    local n
    n=$(jq -r 'select(.message.role? == "toolResult") | .message.toolCallId // empty' "$f" 2>/dev/null | grep -c . 2>/dev/null || true)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# classify_death_error <out_file> <err_file> <session_jsonl>
# Prints two lines: the error_class and the literal error tail (<=300 chars).
# Reuses the existing matchers (is_quota_cap_error, is_overload_error,
# is_spawn_etimeout, is_mid_session_death) so a fast death always carries a
# classifiable literal. An unclassifiable death is "unknown" with the raw tail.
classify_death_error() {
    local out="${1:-}" err="${2:-}" sess="${3:-}"
    local out_text="" err_text=""
    [[ -n "$out" && -f "$out" ]] && out_text=$(cat "$out" 2>/dev/null || true)
    [[ -n "$err" && -f "$err" ]] && err_text=$(cat "$err" 2>/dev/null || true)
    local cls="unknown"
    if is_openrouter_free_retired_error "$out_text" "$err_text"; then
        cls="openrouter_free_retired"
    elif is_quota_cap_error "$out_text" "$err_text"; then
        cls="quota_cap"
    elif is_overload_error "$out_text" "$err_text"; then
        cls="overload_503"
    elif is_workspace_trust_error "$out_text" "$err_text"; then
        cls="config_fault_trust"
    elif is_devin_writes_rejected "$out_text" "$err_text"; then
        cls="devin-writes-rejected"
    elif is_sandbox_localhost_error "$out_text" "$err_text"; then
        cls="sandbox-localhost-unresolvable"
    elif is_spawn_etimeout "$out_text" "$err_text"; then
        cls="spawn_etimeout"
    elif is_mid_session_death "$err"; then
        cls="mid_session_death"
    elif [[ -n "$err_text" ]] && grep -qiE 'spawnSync.*ETIMEDOUT|ETIMEDOUT.*spawnSync' <<<"$err_text" 2>/dev/null; then
        cls="hang_etimedout"
    fi
    # Literal: prefer the session-error line (#3238 surfaces it into err),
    # then the last non-empty stderr line, then the session jsonl errorMessage.
    local literal=""
    if [[ -n "$err_text" ]]; then
        literal=$(grep -E '^session-error:' <<<"$err_text" 2>/dev/null | tail -1 | sed 's/^session-error: //' | head -c 300 || true)
    fi
    if [[ -z "$literal" && -n "$err_text" ]]; then
        literal=$(grep -vE '^[[:space:]]*$' <<<"$err_text" 2>/dev/null | tail -1 | head -c 300 || true)
    fi
    if [[ -z "$literal" && -n "$sess" && -f "$sess" ]]; then
        literal=$(jq -r 'select(.message.stopReason? == "error") | .message.errorMessage // empty' "$sess" 2>/dev/null | tail -1 | head -c 300 || true)
    fi
    [[ -z "$literal" ]] && literal="(no error text captured)"
    printf '%s\n%s\n' "$cls" "$literal"
}

# _seat_merge_error_class <provider> <model> <error_class> <bench_reason>
# Merges last_error_class + bench_reason into the existing seat ledger file
# (in-place jq edit). Same ledger file the mark_seat_* writers use — a
# field-merge, not a new organ. Best-effort: a missing ledger or jq failure
# returns 1, never blocks the caller's exit path.
_seat_merge_error_class() {
    local p="$1" m="$2" cls="${3:-unknown}" reason="${4:-}"
    if ! _seat_key_guard "$p" "$m" "_seat_merge_error_class"; then return 1; fi
    local path
    path=$(seat_ledger_path "$p" "$m")
    [[ -f "$path" ]] || return 1
    local tmp="$path.errcls.$$.$RANDOM.tmp"
    if jq --arg ec "$cls" --arg br "$reason" \
        '.last_error_class=$ec | .bench_reason=$br' "$path" >"$tmp" 2>/dev/null; then
        chmod 0644 "$tmp" 2>/dev/null || true
        if mv "$tmp" "$path" 2>/dev/null; then
            return 0
        fi
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# _seat_is_benched <provider> <model>
# Returns 0 if the seat ledger already shows an active bench (a non-healthy
# health_class, a future bench_until/usable_at, or an unexpired spawn-bench
# marker), 1 otherwise. Used by the fast-death fallthrough bench (fleet-ops#3766)
# so it never overwrites a bench a prior detector (hang_bench / quota / overload
# / mid-session) already wrote — the fallthrough is only for a seat that is
# genuinely unbenched and flapping.
_seat_is_benched() {
    local p="$1" m="$2"
    local sb_path sb_usable
    sb_path=$(seat_spawn_bench_path "$p" "$m")
    if [[ -f "$sb_path" ]]; then
        sb_usable=$(jq -r '.usable_at // ""' "$sb_path" 2>/dev/null || true)
        if [[ -n "$sb_usable" ]] && _seat_in_future "$sb_usable"; then
            return 0
        fi
    fi
    local f hc bench_until usable_at
    f=$(seat_ledger_path "$p" "$m")
    [[ -f "$f" ]] || return 1
    IFS=$'\x1f'$'\n' read -r hc bench_until usable_at < <(
        jq -r '[(.health_class//""),(.bench_until//""),(.usable_at//"")] | join("\u001f")' "$f" 2>/dev/null || true
    )
    [[ -z "$hc" ]] && return 1
    # Any non-healthy class is a bench (hang_bench / quota_bench / overload_bench
    # / transient_fault / corpse) — never overwrite it with a fresh spawn-fail.
    [[ "$hc" != "healthy" ]] && return 0
    if [[ -n "$bench_until" ]] && _seat_in_future "$bench_until"; then return 0; fi
    if [[ -n "$usable_at" ]] && _seat_in_future "$usable_at"; then return 0; fi
    return 1
}

# --- quota/cap bench (fleet-ops#90) ----------------------------------------
# A provider that returns a hard cap/quota 429 with an advertised reset window
# (ClinePass "weekly Clinepass limit ... resets in 1d 11h", devin 15-min 429,
# HTTP retry-after) is a WALLED SEAT, not a transient retry. seat-health.ts
# writes its ledger only on a live-session response hook, and even then may
# record quota_exhausted with no bench window — so pick_seat keeps re-offering
# the same walled seat to fresh workers, each of which burns a StartLimitBurst
# attempt on a guaranteed failure. This is the deterministic complement to
# mark_seat_spawn_fail: the worker wrapper (pi-issue-run) calls it on its way
# out when pi exited non-zero AND the captured output looks like a quota/cap
# error. It records a bench-until timestamp in the existing per-seat ledger;
# seat_usable then skips the seat until that timestamp and fail-opens after.
# Per the provider-wall standing rule: a walled seat is a lane fault, never
# charged to the work item.

# Parse a reset window out of an error text blob and echo the duration in
# seconds. Returns 0 (echoing seconds) if a window is found, 1 (no echo) if not.
# Handles the formats observed in the fleet:
#   - "resets in 1d 11h" / "resets in 2h 30m" / "resets in 45m" / "resets in 3d"
#   - "retry after 60" / "retry-after: 60" / "retry_after: 60" (delta-seconds)
#   - "resets at 2026-08-27T12:00:00Z" / "retry after <ISO ts>" (absolute)
# Greedy on the first match; case-insensitive. Whitespace-tolerant.
# Every grep in a command substitution is `|| true` so a no-match cannot
# kill the caller under `set -euo pipefail` (pi-issue-run sources this file).
_parse_reset_window_s() {
    local text="$1" s d h m
    [[ -n "$text" ]] || return 1

    # Absolute timestamp: "resets at <ISO>" or "retry after <ISO>". Parse the
    # ts and compute the delta from now; only positive deltas count.
    local abs_ts abs_ts_s abs_now_s
    abs_ts=$(grep -oiE '(resets[[:space:]]+at|retry[[:space:]_-]?after)[^0-9]*([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9:]+))' <<<"$text" 2>/dev/null \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9:]+)' | head -n1 || true)
    if [[ -n "$abs_ts" ]]; then
        abs_now_s=$(date -u +%s)
        abs_ts_s=$(date -u -d "$abs_ts" +%s 2>/dev/null || echo 0)
        if [[ "$abs_ts_s" =~ ^[0-9]+$ ]] && (( abs_ts_s > abs_now_s )); then
            echo $((abs_ts_s - abs_now_s))
            return 0
        fi
        # ts in the past -> window already expired -> no window. Caller falls
        # back to the provider default, which is the safe direction: bench
        # for the default rather than immediately retry.
        return 1
    fi

    # "resets in Nd Nh" / "Nh Nm" / "Nm" / "Ns" / "Nd" — sum all present units.
    s=0; d=0; h=0; m=0
    local in_block
    in_block=$(grep -oiE 'resets[[:space:]]+in[[:space:]]+[0-9]+[dhms]([[:space:]]+[0-9]+[dhms])*' <<<"$text" 2>/dev/null || true)
    if [[ -n "$in_block" ]]; then
        local v u
        while read -r v u; do
            [[ "$v" =~ ^[0-9]+$ && -n "$u" ]] || continue
            u="${u,,}"
            case "$u" in
                d) d=$v ;;
                h) h=$v ;;
                m) m=$v ;;
                s) s=$v ;;
            esac
        done < <(grep -oiE '[0-9]+[dhms]' <<<"$in_block" | sed -E 's/^([0-9]+)([dhmsDHMS])$/\1 \2/' || true)
        local total=$((d*86400 + h*3600 + m*60 + s))
        if (( total > 0 )); then
            echo "$total"
            return 0
        fi
    fi

    # "retry after N" / "retry-after: N" / "retry_after: N" — delta-seconds.
    local delta
    delta=$(grep -oiE 'retry[[:space:]_-]?after[^0-9]*[0-9]+' <<<"$text" 2>/dev/null \
        | grep -oE '[0-9]+$' | head -n1 || true)
    if [[ "$delta" =~ ^[0-9]+$ ]] && (( delta > 0 )); then
        echo "$delta"
        return 0
    fi

    # Devin phrasing: "Your limit will reset in 35 minutes" (word units, singular).
    local word_block n unit total=0
    word_block=$(grep -oiE 'resets?[[:space:]]+in[[:space:]]+[0-9]+[[:space:]]+(seconds?|minutes?|hours?|days?)' <<<"$text" 2>/dev/null | head -n1 || true)
    if [[ -n "$word_block" ]]; then
        n=$(grep -oE '[0-9]+' <<<"$word_block" | head -n1 || true)
        unit=$(grep -oiE '(seconds?|minutes?|hours?|days?)' <<<"$word_block" | tail -n1 | tr '[:upper:]' '[:lower:]' || true)
        if [[ "$n" =~ ^[0-9]+$ && -n "$unit" ]]; then
            case "$unit" in
                second|seconds) total=$n ;;
                minute|minutes) total=$((n * 60)) ;;
                hour|hours) total=$((n * 3600)) ;;
                day|days) total=$((n * 86400)) ;;
            esac
            if (( total > 0 )); then
                echo "$total"
                return 0
            fi
        fi
    fi

    return 1
}

# True if the captured output is an HTTP 401 / dead-token credential failure
# (fleet-ops#4640). One 401 is not a 10-year corpse: credentials rotate.
is_credentials_error() {
    local out="$1" err="$2"
    local combined="$out"$'\n'"$err"
    [[ -n "$combined" ]] || return 1
    grep -qiE '\b401\b|invalid[[:space:]]+token|unauthorized|authentication[[:space:]]+failed|invalid[[:space:]]+api[[:space:]]+key' <<<"$combined"
}

# fleet-ops#4640: 401 -> credentials_bad bench of 1h. Corpse only after
# SEAT_CREDENTIALS_CORPSE_STRIKES consecutive 401s. A single 401 is a
# rotated key, not a decade of death.
mark_seat_credentials_bad() {
    local p="$1" m="$2" text="${3:-}"
    if ! _seat_key_guard "$p" "$m" "mark_seat_credentials_bad"; then return 1; fi
    if _transport_is_down; then _mark_transport_down "$p" "$m"; return 1; fi
    local path now_utc now_s bench_until window_s tmp prev_count merged_count seat_dead
    path=$(seat_ledger_path "$p" "$m")
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true
    window_s="${SEAT_CREDENTIALS_BAD_BENCH_S:-3600}"
    [[ "$window_s" =~ ^[0-9]+$ ]] || window_s=3600
    now_s=$(date -u +%s)
    now_utc=$(date -u -d "@$now_s" +%Y-%m-%dT%H:%M:%SZ)
    prev_count=0
    if [[ -f "$path" ]]; then
        prev_count=$(jq -r '.consecutive_failure_count // 0' "$path" 2>/dev/null || echo 0)
        [[ "$prev_count" =~ ^[0-9]+$ ]] || prev_count=0
    fi
    merged_count=$((prev_count + 1))
    seat_dead=false
    local strikes="${SEAT_CREDENTIALS_CORPSE_STRIKES:-24}"
    [[ "$strikes" =~ ^[0-9]+$ ]] || strikes=24
    if (( merged_count >= strikes )); then
        seat_dead=true
    fi
    bench_until=$(date -u -d "@$((now_s + window_s))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")
    tmp="$path.cred.$$.$RANDOM.tmp"
    if ! jq -nc \
        --arg provider "$p" --arg model "$m" \
        --arg observed "$now_utc" --arg bench "$bench_until" --arg usable "$bench_until" \
        --argjson window "$window_s" --argjson merged "$merged_count" \
        --argjson http_status 401 --argjson retry_after null \
        --argjson retryable true --argjson seat_dead "$seat_dead" --argjson poison_ladder false \
        --arg writer "mark_seat_credentials_bad" \
        '{
          provider:$provider, model:$model,
          http_status:$http_status, retry_after:$retry_after,
          health_class:"credentials_bad",
          retryable:$retryable, seat_dead:$seat_dead, poison_ladder:$poison_ladder,
          observed_at:$observed,
          source:"after_provider_response",
          failure_mode:"credentials_bad",
          bench_until:$bench,
          usable_at:$usable,
          bench_window_s:$window,
          consecutive_failure_count:$merged,
          writer:$writer
        }' > "$tmp" 2>/dev/null; then
        seat_log "credentials-bad: jq compose FAILED for $p/$m — marker NOT written"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 0644 "$tmp" 2>/dev/null || true
    if mv "$tmp" "$path" 2>/dev/null; then
        if [[ "$seat_dead" == "true" ]]; then
            seat_log "credentials-bad: $p/$m CORPSE after ${merged_count} consecutive 401s (threshold=${strikes}) — Nish-reserved credential class (fleet-ops#4640)"
        else
            seat_log "credentials-bad: benched $p/$m until $bench_until (1h re-probe, count=$merged_count/${strikes}) (fleet-ops#4640)"
        fi
        return 0
    fi
    seat_log "credentials-bad: rename FAILED for $p/$m at $path"
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# fleet-ops#4825: bench a seat for a config/trust fault (the Devin CLI's
# "Refusing to run in an untrusted workspace"). This is INFRASTRUCTURE, not
# yield: the seat is skipped for a short window so pick_seat dodges it, but it
# is NEVER retired (seat_dead stays false, no corpse escalation). The fix is
# the managed config key `skip_workspace_trust: true` (pinned by install.sh);
# this writer is the safety net for when the config is wrong again. A short
# bench (default 60s) is enough — the config is the real fix, and a long bench
# would wall the seat longer than the misconfiguration lasts once install.sh
# re-converges. Args: provider model [error_text].
# Writes LEDGER_DIR/<sanitised-provider>__<sanitised-model>.json atomically with
# health_class="config_fault" and failure_mode="config_fault_trust". Best-effort:
# any failure is logged but does NOT fail the worker's own exit. Returns 0 if
# the marker was written, 1 if it was not.
mark_seat_config_fault_bench() {
    local p="$1" m="$2" text="${3:-}"
    # fleet-ops#3661: never write a ledger for a phantom seat key.
    if ! _seat_key_guard "$p" "$m" "mark_seat_config_fault_bench"; then return 1; fi
    if _transport_is_down; then _mark_transport_down "$p" "$m"; return 1; fi
    local path
    path=$(seat_ledger_path "$p" "$m")
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true

    # Short bench: the config is the real fix. A longer bench would wall the
    # seat past the moment install.sh re-converges the trust key.
    local window_s="${SEAT_CONFIG_FAULT_BENCH_S:-60}"
    [[ "$window_s" =~ ^[0-9]+$ ]] || window_s=60

    local now_utc now_s bench_until
    now_s=$(date -u +%s)
    now_utc=$(date -u -d "@$now_s" +%Y-%m-%dT%H:%M:%SZ)
    bench_until=$(date -u -d "@$((now_s + window_s))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")

    # Merge consecutive_failure_count from any existing entry, but NEVER
    # escalate to a corpse — a config fault is infrastructure, not yield.
    local prev_count=0
    if [[ -f "$path" ]]; then
        prev_count=$(jq -r '.consecutive_failure_count // 0' "$path" 2>/dev/null || echo 0)
        [[ "$prev_count" =~ ^[0-9]+$ ]] || prev_count=0
    fi
    local merged_count=$((prev_count + 1))

    local tmp="$path.cfgfault.$$.$RANDOM.tmp"
    if ! jq -nc \
        --arg provider "$p" --arg model "$m" \
        --arg observed "$now_utc" --arg bench "$bench_until" --arg usable "$bench_until" \
        --argjson window "$window_s" --argjson merged "$merged_count" \
        --argjson http_status 0 --argjson retry_after null \
        --argjson retryable true --argjson seat_dead false --argjson poison_ladder false \
        --arg writer "mark_seat_config_fault_bench" \
        '{
          provider:$provider, model:$model,
          http_status:$http_status, retry_after:$retry_after,
          health_class:"config_fault",
          retryable:$retryable, seat_dead:$seat_dead, poison_ladder:$poison_ladder,
          observed_at:$observed,
          source:"config_fault_trust",
          failure_mode:"config_fault_trust",
          bench_until:$bench,
          usable_at:$usable,
          bench_window_s:$window,
          consecutive_failure_count:$merged,
          last_error_class:"config_fault_trust",
          writer:$writer
        }' > "$tmp" 2>/dev/null; then
        seat_log "config-fault-bench: jq compose FAILED for $p/$m — marker NOT written"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 0644 "$tmp" 2>/dev/null || true
    if mv "$tmp" "$path" 2>/dev/null; then
        seat_log "config-fault-bench: benched $p/$m until $bench_until (window=${window_s}s, count=$merged_count) — config/trust fault, NOT retired (fleet-ops#4825)"
        return 0
    fi
    seat_log "config-fault-bench: rename FAILED for $p/$m at $path"
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# fleet-ops#4780: the Devin CLI under `--sandbox` rejects every file write
# non-interactively ("rejected a tool call that requires confirmation"), so
# every run ends empty at the first edit. This is a CLI/flag CONFIG fault,
# not a seat yield: the fix is dropping `--sandbox` (the provider now runs
# `--permission-mode dangerous` unsandboxed). Bench via a short window so
# pick_seat dodges the seat this cycle, but NEVER retire it (seat_dead stays
# false, no corpse escalation) — a future vendor change that re-breaks the
# flag must not wall devin out of the fleet. Same shape as
# mark_seat_config_fault_bench (fleet-ops#4825). Args: provider model
# [error_text]. Writes LEDGER_DIR/<sanitised-provider>__<sanitised-model>.json
# atomically with health_class="config_fault" and
# failure_mode="devin-writes-rejected". Best-effort: any failure is logged
# but does NOT fail the worker's own exit. Returns 0 if the marker was
# written, 1 if it was not.
mark_seat_devin_writes_rejected_bench() {
    local p="$1" m="$2" text="${3:-}"
    # fleet-ops#3661: never write a ledger for a phantom seat key.
    if ! _seat_key_guard "$p" "$m" "mark_seat_devin_writes_rejected_bench"; then return 1; fi
    if _transport_is_down; then _mark_transport_down "$p" "$m"; return 1; fi
    local path
    path=$(seat_ledger_path "$p" "$m")
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true

    # Short bench: the flag is the real fix. A longer bench would wall the
    # seat past the moment the extension re-converges to a writable mode.
    local window_s="${SEAT_DEVIN_WRITES_REJECTED_BENCH_S:-60}"
    [[ "$window_s" =~ ^[0-9]+$ ]] || window_s=60

    local now_utc now_s bench_until
    now_s=$(date -u +%s)
    now_utc=$(date -u -d "@$now_s" +%Y-%m-%dT%H:%M:%SZ)
    bench_until=$(date -u -d "@$((now_s + window_s))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")

    # Merge consecutive_failure_count from any existing entry, but NEVER
    # escalate to a corpse — a CLI/flag config fault is infrastructure, not
    # seat yield.
    local prev_count=0
    if [[ -f "$path" ]]; then
        prev_count=$(jq -r '.consecutive_failure_count // 0' "$path" 2>/dev/null || echo 0)
        [[ "$prev_count" =~ ^[0-9]+$ ]] || prev_count=0
    fi
    local merged_count=$((prev_count + 1))

    local tmp="$path.devinwr.$$.$RANDOM.tmp"
    if ! jq -nc \
        --arg provider "$p" --arg model "$m" \
        --arg observed "$now_utc" --arg bench "$bench_until" --arg usable "$bench_until" \
        --argjson window "$window_s" --argjson merged "$merged_count" \
        --argjson http_status 0 --argjson retry_after null \
        --argjson retryable true --argjson seat_dead false --argjson poison_ladder false \
        --arg writer "mark_seat_devin_writes_rejected_bench" \
        '{
          provider:$provider, model:$model,
          http_status:$http_status, retry_after:$retry_after,
          health_class:"config_fault",
          retryable:$retryable, seat_dead:$seat_dead, poison_ladder:$poison_ladder,
          observed_at:$observed,
          source:"devin-writes-rejected",
          failure_mode:"devin-writes-rejected",
          bench_until:$bench,
          usable_at:$usable,
          bench_window_s:$window,
          consecutive_failure_count:$merged,
          last_error_class:"devin-writes-rejected",
          writer:$writer
        }' > "$tmp" 2>/dev/null; then
        seat_log "devin-writes-rejected-bench: jq compose FAILED for $p/$m — marker NOT written"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 0644 "$tmp" 2>/dev/null || true
    if mv "$tmp" "$path" 2>/dev/null; then
        seat_log "devin-writes-rejected-bench: benched $p/$m until $bench_until (window=${window_s}s, count=$merged_count) — CLI/flag config fault, NOT retired (fleet-ops#4780)"
        return 0
    fi
    seat_log "devin-writes-rejected-bench: rename FAILED for $p/$m at $path"
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# Bench a seat whose tool-approval gate refused the run's writes
# (fleet-ops#5189). Args: provider model [reason]. Same infrastructure class
# as mark_seat_devin_writes_rejected_bench (fleet-ops#4780): health_class
# config_fault, seat_dead=false, NEVER retired — a seat-side permission gate
# is a lane fault, not seat yield. The difference is the window: this bench
# must outlast the caller unit's RestartSec so the systemd retry walks the
# seat ladder instead of re-picking the same gated seat (senior-review
# tried-seats drop once the seat reads usable, fleet-ops#4220).
# Writes LEDGER_DIR/<sanitised-provider>__<sanitised-model>.json atomically.
# Best-effort: any failure is logged but does NOT fail the caller's exit.
mark_seat_writes_refused_bench() {
    local p="$1" m="$2" reason="${3:-writes-refused}"
    # fleet-ops#3661: never write a ledger for a phantom seat key.
    if ! _seat_key_guard "$p" "$m" "mark_seat_writes_refused_bench"; then return 1; fi
    if _transport_is_down; then _mark_transport_down "$p" "$m"; return 1; fi
    local path
    path=$(seat_ledger_path "$p" "$m")
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true

    local window_s="${SEAT_WRITES_REFUSED_BENCH_S:-3600}"
    [[ "$window_s" =~ ^[0-9]+$ ]] || window_s=3600

    local now_utc now_s bench_until
    now_s=$(date -u +%s)
    now_utc=$(date -u -d "@$now_s" +%Y-%m-%dT%H:%M:%SZ)
    bench_until=$(date -u -d "@$((now_s + window_s))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")

    # Merge consecutive_failure_count from any existing entry, but NEVER
    # escalate to a corpse — a tool-approval gate is infrastructure, not
    # seat yield.
    local prev_count=0
    if [[ -f "$path" ]]; then
        prev_count=$(jq -r '.consecutive_failure_count // 0' "$path" 2>/dev/null || echo 0)
        [[ "$prev_count" =~ ^[0-9]+$ ]] || prev_count=0
    fi
    local merged_count=$((prev_count + 1))

    local tmp="$path.wr.$$.$RANDOM.tmp"
    if ! jq -nc \
        --arg provider "$p" --arg model "$m" --arg reason "$reason" \
        --arg observed "$now_utc" --arg bench "$bench_until" --arg usable "$bench_until" \
        --argjson window "$window_s" --argjson merged "$merged_count" \
        --argjson http_status 0 --argjson retry_after null \
        --argjson retryable true --argjson seat_dead false --argjson poison_ladder false \
        --arg writer "mark_seat_writes_refused_bench" \
        '{
          provider:$provider, model:$model,
          http_status:$http_status, retry_after:$retry_after,
          health_class:"config_fault",
          retryable:$retryable, seat_dead:$seat_dead, poison_ladder:$poison_ladder,
          observed_at:$observed,
          source:"writes-refused",
          failure_mode:"writes-refused",
          bench_until:$bench,
          usable_at:$usable,
          bench_window_s:$window,
          consecutive_failure_count:$merged,
          last_error_class:"writes-refused",
          bench_reason:$reason,
          writer:$writer
        }' > "$tmp" 2>/dev/null; then
        seat_log "writes-refused-bench: jq compose FAILED for $p/$m — marker NOT written"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 0644 "$tmp" 2>/dev/null || true
    if mv "$tmp" "$path" 2>/dev/null; then
        seat_log "writes-refused-bench: benched $p/$m until $bench_until (window=${window_s}s, count=$merged_count, reason=$reason) — approval-gate fault, NOT retired (fleet-ops#5189)"
        return 0
    fi
    seat_log "writes-refused-bench: rename FAILED for $p/$m at $path"
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# True if the captured output looks like a quota/cap wall (NOT a transient
# rate-limit retry). Strict enough to require a quota/cap keyword AND a reset
# signal, so a plain 429-with-retry-after (transient) does NOT trigger a long
# bench — the rate_limited path already handles short windows. The trigger is a
# hard cap: weekly/daily limit, quota exhausted, INFERENCE_CAP_ERROR, plan/usage
# limit, out of credits, paired with either an explicit reset window OR a
# provider default in seat-caps.json (the caller resolves the default).
is_quota_cap_error() {
    local out="$1" err="$2"
    local combined="$out"$'\n'"$err"
    [[ -n "$combined" ]] || return 1
    # Quota/cap signal words (hard wall, not a transient retry).
    # fleet-ops#4444: Alibaba token-plan 429 body is "Your token-plan 1-week
    # quota has been exhausted. The quota will reset at ..." — `quota` has
    # intervening words before `exhausted` ("has been"), so the adjacency
    # `quota (exhausted|...)` misses it and the death fell to
    # error_class=unknown, never benched, seat re-picked every cycle. Match
    # `token-plan` and `quota has been` as the hard-wall signal the same way.
    if ! grep -qiE 'weekly[[:space:]]+(clinepass[[:space:]]+)?limit|daily[[:space:]]+limit|quota[[:space:]]+(exhausted|exceeded|reached)|quota[[:space:]]+has[[:space:]]+been|token-plan|usage[[:space:]]+balance[[:space:]]+exhausted|budget_exceeded|credit[[:space:]]+balance[[:space:]]+depleted|free-model[[:space:]]+token[[:space:]]+quota|resource_exhausted|Connection error, send a message to continue retrying|INFERENCE_CAP_ERROR|usage[[:space:]]+limit|plan[[:space:]]+limit|out[[:space:]]+of[[:space:]]+credits|insufficient[[:space:]]+credits|credit_insufficient|budget_error|insufficient_user_quota|message[[:space:]]+rate[[:space:]]+limit|rate[[:space:]]+limit[[:space:]]+(exceeded|reached)|cap[[:space:]]+(exceeded|reached)|exceeded[[:space:]]+your' <<<"$combined"; then
        return 1
    fi
    # A reset signal: an explicit window OR a "resets" keyword. The provider
    # default (seat-caps.json) is the caller's fallback when the keyword is
    # present but no numeric window is; this guard just confirms it is a wall.
    if grep -qiE 'resets?[[:space:]]+(in|at|after)|retry[[:space:]_-]?after|reset[[:space:]]+window' <<<"$combined"; then
        return 0
    fi
    # Hard-cap keyword alone (e.g. "weekly Clinepass limit") with no window
    # text still qualifies: the caller falls back to the provider default.
    # FreeUsageLimitError (opencode/mimo free-tier 429, no reset window) is a
    # provider-side free-quota exhaustion — a hard wall, not a transient retry.
    # "usage balance exhausted" (xai-oauth Grok Build HTTP 402, fleet-ops 2026-09-05:
    # 15 sessions/24h died at 1s, never benched) is a prepaid-balance wall with no
    # reset text — the weekly provider default in seat-caps.json applies.
    # "Credit balance depleted" / budget_exceeded (mergegateway HTTP 402,
    # fleet-ops#3973, 2026-09-06: three seats died at 1s, booked
    # error_class=unknown) is the same prepaid-balance wall: classify it; with
    # no provider default the writer fails open and the reactive ledger benches.
    # "Insufficient credits for this request" / budget_error / credit_insufficient
    # (Pareto Inference HTTP 429, fleet-ops 2026-09-09: wire probe returned this
    # body; 91 deaths in 4h booked rc=124/rc=1, health_class=transient_fault and
    # a generic "no_block:rc=1" bench with no error-class citation) is a prepaid
    # credit wall wearing a 429, not a rate limit: classify it so the money wall
    # is never counted as seat yield.
    # "insufficient_user_quota" (b.ai HTTP 400, fleet-ops#4831, 2026-09-09:
    # bai/deepseek-v4.1-flash returned 400 {"message":"credit insufficient
    # balance: balance=0 required=7716","code":"insufficient_user_quota"} —
    # pi-scout@0509, pi-scout-repair@0509 and pi-issue@0509-2085 all died on the
    # seat inside 3 min, each booked error_class=unknown -> transient_fault ->
    # 300s spawn bench, and the dead free seat was re-offered every ~5 min
    # (~12 claims/hour). The body carries no reset window, so it must pass the
    # hard-cap list like `credit balance depleted` does; the 3600s
    # quota_bench_default_s in seat-caps.json bounds the re-probe.
    if grep -qiE 'weekly[[:space:]]+(clinepass[[:space:]]+)?limit|daily[[:space:]]+limit|INFERENCE_CAP_ERROR|FreeUsageLimitError|usage[[:space:]]+balance[[:space:]]+exhausted|budget_exceeded|budget_error|credit[[:space:]]+balance[[:space:]]+depleted|insufficient[[:space:]]+credits|credit_insufficient|insufficient_user_quota|usage[[:space:]]+limit[[:space:]]+for[[:space:]]+the[[:space:]]+current[[:space:]]+free[[:space:]]+model|free-model[[:space:]]+token[[:space:]]+quota|resource_exhausted' <<<"$combined"; then
        return 0
    fi
    return 1
}

# fleet-ops#5274: OpenRouter retired the free tier of a model. The upstream
# body is HTTP 404 {"message":"This model is unavailable for free. The paid
# version is available now - use this slug instead: <paid-slug>"}. Neither
# is_quota_cap_error (quota words) nor is_overload_error (503) matches it, so
# pi-issue-run booked error_class=unknown, benched 300s, and the corpse seat
# was re-offered every restart (pi-issue@0509-2724, 8 reclaims). The 404 is
# PERMANENT: OpenRouter's /api/v1/models no longer lists the slug. Match it
# explicitly so it classifies as a corpse, not a transient bench.
is_openrouter_free_retired_error() {
    local out="$1" err="$2"
    local combined="$out"$'\n'"$err"
    [[ -n "${combined//$'\n'/}" ]] || return 1
    # fleet-ops#5274: require BOTH a 404 status token and OpenRouter's exact
    # 'unavailable for free' phrase — a bare 404, a 503 overload, or a quota
    # body alone must never corpse a seat.
    grep -qiE '404' <<<"$combined" \
        && grep -qiE 'unavailable[[:space:]_-]+for[[:space:]]+free' <<<"$combined"
}

# mark_seat_free_retired_corpse <provider> <model> [error_text]
# Permanent-corpse writer for the free_retired_corpse error class (fleet-ops#5274
# row in seat-caps.json's error_classes registry). Composes the existing corpse
# pieces instead of adding an organ: write_parked_ledger writes the terminal
# seat_dead=true ledger, _seat_merge_error_class stamps the classifiable class
# + literal on top, and _seat_write_spawn_bench (seat_dead=true, far-future,
# source=free_retired_corpse) carries the corpse onto the clobber-proof marker
# so the false-healthy transport-200 clobber (fleet-ops#3889) cannot resurrect
# it. Best-effort: a marker failure does not undo the ledger.
mark_seat_free_retired_corpse() {
    local p="$1" m="$2" text="${3:-}"
    # fleet-ops#3661: never write a ledger for a phantom seat key.
    if ! _seat_key_guard "$p" "$m" "mark_seat_free_retired_corpse"; then return 1; fi
    if _transport_is_down; then _mark_transport_down "$p" "$m"; return 1; fi
    local lit="${text:0:300}"
    if ! write_parked_ledger "$p" "$m" \
        "free-retired corpse: OpenRouter 404 unavailable-for-free is PERMANENT (provider retired the free tier; cap=0 intentional_cap_zero=corpse, fleet-ops#5274): $lit"; then
        return 1
    fi
    _seat_merge_error_class "$p" "$m" "openrouter_free_retired" \
        "OpenRouter 404 unavailable-for-free — permanent corpse (fleet-ops#5274): $lit" 2>/dev/null || true
    local now_s far_future
    now_s=$(date -u +%s)
    far_future=$(date -u -d "@$((now_s + 315360000))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    _seat_write_spawn_bench "$p" "$m" "$far_future" \
        "openrouter 404 unavailable-for-free — permanent corpse (fleet-ops#5274)" \
        0 1 "free_retired_404" "true" "free_retired_corpse" 2>/dev/null || true
    return 0
}

# Bench a seat for a quota/cap wall. Args: provider model [error_text]
#   error_text defaults to "" — when empty, no window can be parsed and the
#   provider default is used (or, with no default, the writer fails open and
#   writes nothing).
# Writes LEDGER_DIR/<sanitised-provider>__<sanitised-model>.json atomically with
# health_class="quota_bench" and bench_until=<ISO>. Best-effort: any failure is
# logged but does NOT fail the worker's own exit. Returns 0 if the marker was
# written, 1 if it was not (no window AND no provider default -> fail open, or
# jq/rename failure).
mark_seat_quota_bench() {
    local p="$1" m="$2" text="${3:-}"
    # fleet-ops#3661: never write a ledger for a phantom seat key.
    if ! _seat_key_guard "$p" "$m" "mark_seat_quota_bench"; then return 1; fi
    if _transport_is_down; then _mark_transport_down "$p" "$m"; return 1; fi
    # fleet-ops#4453: first 429-after-budget. ParetoInference's daily allowance
    # is a quota/concurrency wall; a 429 that arrives AFTER the provider's
    # token-derived daily budget is already reached is the allowance wall, not
    # momentary concurrency — log the first one per week (the reset hour is
    # undocumented, rule 2). Only fires for a provider with a configured
    # daily_budget_usd that is currently exhausted (paretoinference today).
    if [[ -n "${SEAT_PROVIDER_DAILY_BUDGET_USD[$p]:-}" ]] && ! _provider_daily_429_logged "$p"; then
        if _provider_daily_budget_reached "$p"; then
            _provider_daily_set_log "$p" 429
            seat_log "provider-daily-budget: FIRST 429-after-budget on $p/$m (daily allowance exhausted; reset hour is undocumented — fleet-ops#4453)"
        fi
    fi
    local path
    path=$(seat_ledger_path "$p" "$m")
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true

    local window_s=0 parsed
    parsed=$(_parse_reset_window_s "$text" 2>/dev/null || true)
    [[ "$parsed" =~ ^[0-9]+$ ]] && window_s="$parsed"
    if (( window_s <= 0 )); then
        # fleet-ops#4217: the provider's own live quota (fresh observation of
        # an EXHAUSTED window) is the real reset horizon — it beats the static
        # quota_bench_default_s below. 0 (no live figure) falls through.
        local live
        live=$(provider_live_reset_s "$p")
        if [[ "$live" =~ ^[0-9]+$ ]] && (( live > 0 )); then
            window_s="$live"
            seat_log "quota-bench: $p/$m benching on live fleet_seat_quota reset ${live}s (exhausted window, fleet-ops#4217)"
        fi
    fi
    local declared_window_s=""
    if (( window_s <= 0 )); then
        local def
        def=$(provider_quota_bench_default "$p")
        if [[ "$def" =~ ^[0-9]+$ ]]; then
            window_s="$def"
            declared_window_s="$def"
        fi
    fi

    if (( window_s <= 0 )); then
        seat_log "quota-bench: $p/$m NOT benched — no reset window parsed and no provider default in seat-caps.json (fail-open; reactive ledger remains the backstop)"
        return 1
    fi

    local now_utc now_s bench_until
    now_s=$(date -u +%s)
    now_utc=$(date -u -d "@$now_s" +%Y-%m-%dT%H:%M:%SZ)

    # Merge consecutive_failure_count from any existing entry.
    local prev_count=0
    if [[ -f "$path" ]]; then
        prev_count=$(jq -r '.consecutive_failure_count // 0' "$path" 2>/dev/null || echo 0)
        [[ "$prev_count" =~ ^[0-9]+$ ]] || prev_count=0
    fi
    local merged_count=$((prev_count + 1))
    # fleet-ops#3531: escalate the bench geometrically by count (base * 2^(n-1),
    # capped at 6 h), then park at the failure ceiling. The quota/cap path used
    # a FLAT provider default every cycle, so a chronically walled seat re-entered
    # rotation every window forever (count climbed to 72 on devin/glm-5-2 at a
    # ~15min default). bench_until is computed from the escalated window so the
    # bench branch in seat_usable holds the effective wall.
    window_s=$(_geometric_bench_window "$window_s" "$merged_count")
    # fleet-ops#4640: a bench > 6h needs a money wall or a real quota window.
    local wall_source="quota_bench"
    if _seat_text_is_money_wall "$text"; then
        wall_source="money_boundary"
    elif [[ -n "$parsed" && "$parsed" =~ ^[0-9]+$ ]] && (( parsed > 0 )); then
        wall_source="provider_quota_window"
    else
        local ceil
        ceil=$(provider_wall_ceiling_s "$p")
        if [[ "$ceil" =~ ^[0-9]+$ ]] && (( ceil > 0 )); then
            (( window_s > ceil )) && window_s="$ceil"
            wall_source="provider_quota_window"
        fi
    fi
    window_s=$(_seat_clamp_non_money_window_s "$window_s" "$wall_source" "$declared_window_s")
    # fleet-ops#5285: a bench longer than 15 min owes the seat a bench-truth
    # probe at min(advertised reset, 15 min). A window built ONLY from the
    # provider's static quota_bench_default_s is not an advertised reset —
    # no provider reset was parsed or observed live — so cap it at 15 min
    # before the first truth probe (DECISION 2026-09-11). Parsed windows and
    # live fleet_seat_quota resets ARE advertised and keep their window (the
    # probe corrects a lying advertisement within one 15-min cycle); money
    # walls (wall_source=money_boundary) are policy, never probed, and keep
    # their full declared window. The #3531 geometric escalation on top of a
    # default is also capped here: escalating a guessed window multiplies a
    # guess (the lived Devin "reset in 2…" -> 15360s misparse class), and the
    # bench-truth probe at 15-min cadence is the correct brake now.
    # A failure-ceiling PARK (merged_count >= SEAT_FAILURE_CEILING) is not a
    # guess: it is N consecutive real failures, and #4640's 6h clamp on it
    # stands — the expired-wall tool probe owns parked seats, not the
    # 15-min PONG.
    if [[ -n "$declared_window_s" && "$wall_source" == "quota_bench" ]] \
        && (( merged_count < ${SEAT_FAILURE_CEILING:-20} )); then
        local truth_max="${SEAT_QUOTA_BENCH_DEFAULT_MAX_S:-900}"
        if [[ "$truth_max" =~ ^[0-9]+$ ]] && (( truth_max > 0 )) && (( window_s > truth_max )); then
            seat_log "quota-bench: $p/$m default-driven window ${window_s}s capped at ${truth_max}s — no advertised reset; bench-truth probe owes the seat a PONG at 15 min (fleet-ops#5285)"
            window_s="$truth_max"
        fi
    fi
    bench_until=$(date -u -d "@$((now_s + window_s))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")

    # fleet-ops#2594: corpse reclassification for quota_cap. seat-health.ts
    # (#2145) covers transient_http/rate_limit/cli_timeout/transient_other/
    # empty_run by count and quota_exhausted by age — but the bash writer's
    # failure_mode=quota_cap was excluded from both branches, so a seat like
    # opencode/mimo-v2.5-free at 42 consecutive 429s stayed quota_bench
    # forever, re-offered after each park wall and never terminal. At
    # merged_count >= SEAT_DEAD_CONSECUTIVE_THRESHOLD (default 25, matching
    # seat-health.ts) the ledger is written with seat_dead=true so the roster
    # and census count the seat dead and the alert surface stays loud.
    #
    # fleet-ops#3377: as originally written the corpse branch ALSO cleared
    # bench_until/usable_at (the fleet-ops#2415/#2422 "no-comeback-clock"
    # convention). For a quota_cap seat that is wrong: a quota wall is
    # TIME-BASED and resets, so clearing the clock means no release time is
    # ever reached — the seat is permanently dead instead of cooling down
    # (live 2026-09-04: opencode/mimo-v2.5-free at c=33 sat seat_dead=true
    # with bench_until=""). A concrete bench_until is now KEPT on the corpse
    # so that (a) seat_usable's quota_bench branch holds the seat benched
    # while the clock is future and (b) fleet-seat-comeback-release tool-uses
    # the seat once the clock passes and a healthy observation clears
    # seat_dead=false (fleet-ops#2638: a quota_cap corpse is not in
    # _corpse_is_recoverable_mode, so with no wall it would be retired as
    # permanent). seat_dead=true still flags the corpse to the roster/census;
    # only the no-comeback-clock clear is dropped.
    local seat_dead=false
    # fleet-ops#4453: a 429 on an expiring-daily-allowance seat is a quota OR
    # concurrency wall (https://docs.paretoinference.com/errors.md). Bench 15
    # min then re-probe; never a seat-dead corpse. Key rotation does not reset
    # the allowance; the daily reset does.
    if [[ -z "${SEAT_PROVIDER_DAILY_BUDGET_USD[$p]:-}" ]] && _seat_dead_by_threshold "$merged_count"; then
        seat_dead=true
    fi

    local tmp="$path.bench.$$.$RANDOM.tmp"
    if ! jq -nc \
        --arg provider "$p" --arg model "$m" \
        --arg observed "$now_utc" --arg bench "$bench_until" --arg usable "$bench_until" \
        --argjson window "$window_s" --argjson merged "$merged_count" \
        --argjson http_status 429 --argjson retry_after null \
        --argjson retryable true --argjson seat_dead "$seat_dead" --argjson poison_ladder false \
        --arg writer "mark_seat_quota_bench" --arg source "$wall_source" \
        '{
          provider:$provider, model:$model,
          http_status:$http_status, retry_after:$retry_after,
          health_class:"quota_bench",
          retryable:$retryable, seat_dead:$seat_dead, poison_ladder:$poison_ladder,
          observed_at:$observed,
          source:$source,
          failure_mode:"quota_cap",
          bench_until:$bench,
          usable_at:$usable,
          bench_window_s:$window,
          consecutive_failure_count:$merged,
          writer:$writer
        }' > "$tmp" 2>/dev/null; then
        seat_log "quota-bench: jq compose FAILED for $p/$m — marker NOT written"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 0644 "$tmp" 2>/dev/null || true
    if mv "$tmp" "$path" 2>/dev/null; then
        if [[ "$seat_dead" == "true" ]]; then
            seat_log "quota-bench: $p/$m CORPSE reclassified (count=$merged_count >= ${SEAT_DEAD_CONSECUTIVE_THRESHOLD}); bench_until=$bench_until kept as comeback clock (fleet-ops#3377); re-released once it passes / a healthy observation clears seat_dead=false (fleet-ops#2594)"
        else
            seat_log "quota-bench: benched $p/$m until $bench_until (window=${window_s}s, count=$merged_count)"
            if _seat_parked_by_ceiling "$merged_count"; then
                _emit_failure_ceiling_metric "$p" "$m" "$merged_count"
                seat_log "quota-bench: $p/$m PARKED past failure ceiling (count=$merged_count >= ${SEAT_FAILURE_CEILING}, wall=${window_s}s)"
            fi
        fi
        return 0
    fi
    seat_log "quota-bench: rename FAILED for $p/$m at $path"
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# --- corpse-retirement parked ledger (fleet-ops#3669) -----------------------
# Write a terminal "parked" ledger for a seat that the corpse-retirement
# caller (bin/fleet-seat-comeback-release) has physically moved out of the
# live roster into a dated seats-corpse-retired-<ts>/ audit dir. Before this
# writer, the move left NO ledger in the live roster, so seat_usable fell
# through to the "NO HEALTH DATA (no ledger file) — assuming usable" fail-open
# and pick_seat re-picked the deliberately-retired dead seat (hetzner burned
# 2 claims in 6 min, 2026-09-05). The parked ledger keeps the seat UNPICKABLE:
# seat_usable sees seat_dead=true / health_class=parked / usable_at far future
# and refuses it. Best-effort: a write failure is logged but must not fail the
# caller's own exit. Returns 0 if the parked ledger was written, 1 otherwise.
write_parked_ledger() {
    local p="$1" m="$2" reason="${3:-corpse-retired}"
    local path now_utc now_s far_future tmp
    # fleet-ops#3661: never write a ledger for a phantom seat key.
    if ! _seat_key_guard "$p" "$m" "write_parked_ledger"; then return 1; fi
    path=$(seat_ledger_path "$p" "$m")
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true
    now_s=$(date -u +%s)
    now_utc=$(date -u -d "@$now_s" +%Y-%m-%dT%H:%M:%SZ)
    # Far future: 10 years out, so seat_usable's future-usable_at check always
    # holds the seat off the ladder (and seat_dead=true is the terminal block).
    far_future=$(date -u -d "@$((now_s + 315360000))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")
    tmp="$path.park.$$.$RANDOM.tmp"
    # fleet-ops#3603: a corpse ledger that carries NO bench_reason reads as the
    # fail-open corpse shape (fleet-ops#1890/#2712) to the seat-health census /
    # corpse snapshot, which re-files the same durably-benched corpse ticket
    # every tick as "bench_reason=null". Record the durable bench literal here
    # so a corpse-retired ledger (cap=0 + intentional_cap_zero=corpse is the
    # real bench; pick_seat never offers it) is recognisable as benched, never
    # fail-open.
    br="corpse-retired: cap=0 corpse bench, pick_seat never offers (durable, fleet-ops#2716/#3669)"
    if ! jq -nc \
        --arg provider "$p" --arg model "$m" \
        --arg observed "$now_utc" --arg usable "$far_future" \
        --arg br "$br" \
        --argjson seat_dead true --argjson poison_ladder false \
        '{
          provider:$provider, model:$model,
          http_status:null, retry_after:null,
          health_class:"parked",
          retryable:false, seat_dead:$seat_dead, poison_ladder:$poison_ladder,
          observed_at:$observed,
          source:"corpse_retirement",
          failure_mode:"corpse_retired",
          last_error_class:"corpse_retired",
          bench_reason:$br,
          bench_until:$usable,
          usable_at:$usable,
          consecutive_failure_count:0,
          writer:"write_parked_ledger"
        }' > "$tmp" 2>/dev/null; then
        seat_log "parked-ledger: jq compose FAILED for $p/$m — parked ledger NOT written"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 0644 "$tmp" 2>/dev/null || true
    if mv "$tmp" "$path" 2>/dev/null; then
        seat_log "parked-ledger: $p/$m parked (seat_dead=true, class=parked, usable_at=$far_future, reason=$reason)"
        return 0
    fi
    seat_log "parked-ledger: rename FAILED for $p/$m at $path"
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# --- 503 / upstream-overload bench (fleet-ops #652, 2026-08-27 hot-patch) ----
# A provider that returns 503 "Upstream model provider is temporarily unavailable"
# mid-session is NOT a quota wall (is_quota_cap_error does not match) and NOT a
# spawn-time ETIMEDOUT (is_spawn_etimeout does not match). Live failure mode
# observed in fleet-ops#652: commandcode/minimax-m3-free returned 35 of 200+ tool
# calls as 503 in the first 20 minutes of a worker run, destabilising the model
# for the rest of the session. Without this writer, the seat was never benched
# and pick_seat kept routing fresh workers to a still-storming seat. The 2026-08-27
# root-cause block: is_quota_cap_error matches "quota/cap/limit" words; "temporarily
# unavailable" is a different shape, so the wrapper never wrote a marker and the
# seat stayed pickable.
#
# Distinction from the quota/cap path:
#   - quota/cap: hard wall, seat is walled until advertised reset (ClinePass weekly,
#     devin 15-min message rate limit). bench_until from the error text or the
#     provider's quota_bench_default_s.
#   - 503 overload: transient, the provider's upstream is up but overloaded; the
#     standard mitigation is a short backoff (5-10 min) so the next worker lands
#     after the burst clears, NOT after a full reset window. bench_until from
#     any Retry-After / retry-after in the error text, else the provider's
#     overload_bench_default_s (alias 503_bench_default_s) from seat-caps.json.
#     No default -> writer fails open (reactive seat-health ledger remains the
#     backstop, just like the quota path).

# True if the captured output looks like a 503 / upstream-overload storm.
# Distinct from is_quota_cap_error: the quota path requires a quota/cap keyword
# (weekly limit, INFERENCE_CAP_ERROR, plan limit, out of credits, etc.) — the
# 503 path requires an upstream-availability keyword. They MUST NOT overlap:
# 503 + "temporarily unavailable" is overload, NOT a quota cap; a 429 with
# "quota exceeded" is a cap, NOT overload.
is_overload_error() {
    local out="$1" err="$2"
    local combined="$out"$'\n'"$err"
    [[ -n "$combined" ]] || return 1
    # Four ACCEPT shapes, each independently sufficient (any one of):
    #   (a) the commandcode-specific 503 "Upstream model provider is
    #       temporarily unavailable" — the live fleet-ops#652 body.
    #   (b) an HTTP 503 status with a Retry-After / "try again" hint.
    #   (c) a generic "upstream ... overloaded" (e.g. OpenAI/Anthropic
    #       502/503 wording).
    #   (d) a generic "A server error occurred. Please try again." — the
    #       xkiro 5xx body (fleet-ops#3738): pi surfaces it as rc=1 with no
    #       status code, so without this shape it falls through to
    #       no_block:rc=1 spawn-fail and accumulates a 47-count park
    #       instead of a short overload bench.
    # Bare "503" or bare "temporarily unavailable" WITHOUT any of the
    # above co-occurring context is NOT a match (avoid false positives on
    # log lines that mention 503 in passing, or a flaky network call).
    if grep -qiE 'upstream[[:space:]]+(model[[:space:]]+)?provider[[:space:]]+is[[:space:]]+temporarily[[:space:]]+unavailable|upstream[[:space:]]+(is[[:space:]]+)?overloaded|overloaded[[:space:]]+upstream|server[[:space:]]+error[[:space:]]+occurred[[:space:]]*\.?[[:space:]]*please[[:space:]]+try[[:space:]]+again' <<<"$combined"; then
        return 0
    fi
    if grep -qiE '503[[:space:]]+(service[[:space:]]+unavailable|backend|upstream|bad[[:space:]]+gateway|gateway[[:space:]]+timeout)|http[[:space:]]*503|status[[:space:]]*:[[:space:]]*503|"status":[[:space:]]*503' <<<"$combined"; then
        # 503 status code present — also require a "please try again" /
        # Retry-After signal, otherwise a passing 200 log mentioning 503
        # (e.g. server access log) would false-positive.
        if grep -qiE 'retry[[:space:]_-]?after|try[[:space:]]+again[[:space:]]+later|please[[:space:]]+try[[:space:]]+again|temporarily[[:space:]]+unavailable|upstream' <<<"$combined"; then
            return 0
        fi
        return 1
    fi
    return 1
}

# Bench a seat for a 503 / upstream-overload storm. Args: provider model [error_text]
#   error_text defaults to "" — when empty, no Retry-After can be parsed and the
#   provider default is used (or, with no default, the writer fails open and
#   writes nothing; the reactive seat-health ledger's transient_fault /
#   rate_limited blocks remain the backstop).
# Writes LEDGER_DIR/<sanitised-provider>__<sanitised-model>.json atomically with
# health_class="overload_bench" and bench_until=<ISO>. Distinct failure_mode
# ("overload_503") so the auditor / post-mortem tooling can tell overload
# benches apart from quota/cap benches. Best-effort: any failure is logged but
# does NOT fail the worker's own exit. Returns 0 if the marker was written, 1
# if it was not (no Retry-After AND no provider default -> fail open, or
# jq/rename failure).
mark_seat_overload_bench() {
    local p="$1" m="$2" text="${3:-}"
    # fleet-ops#3661: never write a ledger for a phantom seat key.
    if ! _seat_key_guard "$p" "$m" "mark_seat_overload_bench"; then return 1; fi
    if _transport_is_down; then _mark_transport_down "$p" "$m"; return 1; fi
    local path
    path=$(seat_ledger_path "$p" "$m")
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true

    # Re-use _parse_reset_window_s — it already handles "retry-after: N" and
    # the other delta-seconds forms observed in HTTP error bodies.
    local window_s=0 parsed
    parsed=$(_parse_reset_window_s "$text" 2>/dev/null || true)
    [[ "$parsed" =~ ^[0-9]+$ ]] && window_s="$parsed"
    if (( window_s <= 0 )); then
        local def
        def=$(provider_overload_bench_default "$p")
        [[ "$def" =~ ^[0-9]+$ ]] && window_s="$def"
    fi

    if (( window_s <= 0 )); then
        seat_log "overload-bench: $p/$m NOT benched — no Retry-After parsed and no overload_bench_default_s in seat-caps.json (fail-open; reactive ledger remains the backstop)"
        return 1
    fi

    local now_utc now_s bench_until
    now_s=$(date -u +%s)
    now_utc=$(date -u -d "@$now_s" +%Y-%m-%dT%H:%M:%SZ)

    # Merge consecutive_failure_count from any existing entry.
    local prev_count=0
    if [[ -f "$path" ]]; then
        prev_count=$(jq -r '.consecutive_failure_count // 0' "$path" 2>/dev/null || echo 0)
        [[ "$prev_count" =~ ^[0-9]+$ ]] || prev_count=0
    fi
    local merged_count=$((prev_count + 1))
    # fleet-ops#3531: escalate the bench geometrically by count (base * 2^(n-1),
    # capped at 6 h), then park at the failure ceiling.
    window_s=$(_geometric_bench_window "$window_s" "$merged_count")
    window_s=$(_seat_clamp_non_money_window_s "$window_s" "")
    bench_until=$(date -u -d "@$((now_s + window_s))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")
    # fleet-ops#3531: a 503 on a corpse must not resurrect it. Keep the
    # existing seat_dead (same rule as mark_seat_quota_bench); a fresh
    # ledger starts false.
    local prev_dead=false
    if [[ -f "$path" ]]; then
        prev_dead=$(jq -r 'if .seat_dead == true then "true" else "false" end' "$path" 2>/dev/null || echo false)
        [[ "$prev_dead" == "true" ]] || prev_dead=false
    fi

    local tmp="$path.overload.$$.$RANDOM.tmp"
    if ! jq -nc \
        --arg provider "$p" --arg model "$m" \
        --arg observed "$now_utc" --arg bench "$bench_until" --arg usable "$bench_until" \
        --argjson window "$window_s" --argjson merged "$merged_count" \
        --argjson http_status 503 --argjson retry_after null \
        --argjson retryable true --argjson seat_dead "$prev_dead" --argjson poison_ladder false \
        --arg writer "mark_seat_overload_bench" \
        '{
          provider:$provider, model:$model,
          http_status:$http_status, retry_after:$retry_after,
          health_class:"overload_bench",
          retryable:$retryable, seat_dead:$seat_dead, poison_ladder:$poison_ladder,
          observed_at:$observed,
          source:"overload_bench",
          failure_mode:"overload_503",
          bench_until:$bench,
          usable_at:$usable,
          bench_window_s:$window,
          consecutive_failure_count:$merged,
          writer:$writer
        }' > "$tmp" 2>/dev/null; then
        seat_log "overload-bench: jq compose FAILED for $p/$m — marker NOT written"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 0644 "$tmp" 2>/dev/null || true
    if mv "$tmp" "$path" 2>/dev/null; then
        seat_log "overload-bench: benched $p/$m until $bench_until (window=${window_s}s, count=$merged_count)"
        if _seat_parked_by_ceiling "$merged_count"; then
            _emit_failure_ceiling_metric "$p" "$m" "$merged_count"
            seat_log "overload-bench: $p/$m PARKED past failure ceiling (count=$merged_count >= ${SEAT_FAILURE_CEILING}, wall=${window_s}s)"
        fi
        return 0
    fi
    seat_log "overload-bench: rename FAILED for $p/$m at $path"
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# --- hang bench (auditor 2026-08-27, pi-scout-repair@0509 hung) ------------
# A seat whose model accepted the request (no 429, no 5xx, no quota wall) but
# never sent a final response before the unit's TimeoutStartSec / wrapper
# PI_HANG_TIMEOUT_S killed it is a HUNG SEAT, not a transient. The reactive
# seat-health ledger only writes on a live-session response hook, so a hang
# never records itself — pick_seat then re-offers the same hung seat to the
# next worker, which stalls the same way (this is the auditor 2026-08-27
# 14:12Z trip on pi-scout-repair@0509: opencode/nemotron-3-ultra-free had
# health_class=healthy (last probe PONG 08:44:03Z) but never finalised a
# real 8KB packet; systemd TimeoutStartSec=1800 killed the unit at
# 14:12:15Z with status=15/TERM; no other bench class fits this shape).
#
# Distinct failure_mode="hang_no_response" so the auditor / post-mortem
# tooling can tell hang benches apart from quota/cap/overload. Default
# window is short (180s) — a hang often self-resolves within a minute or
# two (the upstream has to drain a stuck connection); a longer default
# would starve the ladder for no reason. Caller can override with
# mark_seat_hang_bench <p> <m> <text> [observed_elapsed_s]; if the text
# contains an explicit "retry after Ns" or "resets in N" window we use it,
# and fleet-ops#4602 raises the window to the observed hang when the caller
# passes the measured elapsed seconds.
mark_seat_hang_bench() {
    local p="$1" m="$2" text="${3:-}" observed_s="${4:-0}"
    # fleet-ops#3661: never write a ledger for a phantom seat key.
    if ! _seat_key_guard "$p" "$m" "mark_seat_hang_bench"; then return 1; fi
    if _transport_is_down; then _mark_transport_down "$p" "$m"; return 1; fi
    local path
    path=$(seat_ledger_path "$p" "$m")
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true

    # Try to parse an advertised reset window from the text (rare for a
    # hang; included for symmetry with the other benches).
    local window_s=180  # short default; hangs usually clear in < 1 min
    local parsed
    parsed=$(_parse_reset_window_s "$text" 2>/dev/null || true)
    [[ "$parsed" =~ ^[0-9]+$ ]] && (( parsed > 0 )) && window_s="$parsed"

    # fleet-ops#4602: scale the window to the OBSERVED hang when the caller
    # measured one. A seat that deterministically draws ~40 min per pick was
    # benched a flat 180s, so the next tick re-offered it and it hung again —
    # ~16 LONG-HANG ETIMEDOUT events on devin/glm-5-2 in 16h, each burning a
    # worker/scout slot. Never shrink an already-larger window (a parsed
    # provider reset or the failure-ceiling park below still wins).
    if [[ "$observed_s" =~ ^[0-9]+$ ]] && (( observed_s > window_s )); then
        window_s="$observed_s"
    fi

    local now_utc bench_until
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bench_until=$(date -u -d "@$(($(date -u +%s) + window_s))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")

    # Merge consecutive_failure_count from any existing entry.
    local prev_count=0
    if [[ -f "$path" ]]; then
        prev_count=$(jq -r '.consecutive_failure_count // 0' "$path" 2>/dev/null || echo 0)
        [[ "$prev_count" =~ ^[0-9]+$ ]] || prev_count=0
    fi
    local merged_count=$((prev_count + 1))
    # fleet-ops#1362: park past the failure ceiling (long wall override).
    window_s=$(_failure_ceiling_wall "$merged_count" "$window_s")
    # fleet-ops#4640: a hang is a lane stall, not a provider quota window.
    window_s=$(_seat_clamp_non_money_window_s "$window_s" "")
    bench_until=$(date -u -d "@$(($(date -u +%s) + window_s))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")

    local tmp="$path.hang.$$.$RANDOM.tmp"
    if ! jq -nc \
        --arg provider "$p" --arg model "$m" --arg observed "$now_utc" --arg bench_until "$bench_until" \
        --argjson window_s "$window_s" --argjson merged "$merged_count" \
        --arg writer "mark_seat_hang_bench" \
        '{
          provider:$provider, model:$model,
          http_status:0, retry_after:null,
          health_class:"hang_bench",
          retryable:true, seat_dead:false, poison_ladder:false,
          observed_at:$observed,
          source:"hang_no_response",
          failure_mode:"hang_no_response",
          bench_until:$bench_until,
          hang_window_s:$window_s,
          consecutive_failure_count:$merged,
          writer:$writer
        }' > "$tmp" 2>/dev/null; then
        seat_log "hang-bench: jq compose FAILED for $p/$m — marker NOT written"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 0644 "$tmp" 2>/dev/null || true
    if mv "$tmp" "$path" 2>/dev/null; then
        seat_log "hang-bench: benched $p/$m until $bench_until (window=${window_s}s, count=$merged_count) — hung unit TimeoutStartSec / PI_HANG_TIMEOUT_S"
        if _seat_parked_by_ceiling "$merged_count"; then
            _emit_failure_ceiling_metric "$p" "$m" "$merged_count"
            seat_log "hang-bench: $p/$m PARKED past failure ceiling (count=$merged_count >= ${SEAT_FAILURE_CEILING}, wall=${window_s}s)"
        fi
        return 0
    fi
    seat_log "hang-bench: rename FAILED for $p/$m at $path"
    rm -f "$tmp" 2>/dev/null || true
    return 1
}
