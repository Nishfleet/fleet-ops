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
LOG_FILE="$STATE_DIR/watch.log"
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
# fleet-ops#1432: classification of cap=0 seats as intentional (dead_decoy /
# money_only) vs stale (broken endpoint, TPM ceiling, exhausted quota). Drives
# the summary line in _build_excluded_set so the operator sees at a glance
# which cap=0 seats are by-design vs which need re-audition. Keyed on
# "provider" for provider-level cap=0, "provider/model" for model-level.
declare -A SEAT_CAP_ZERO_CLASS_INTENTIONAL=()
declare -A SEAT_CAP_ZERO_CLASS_STALE=()
SEAT_FREE_ORDER=""
SEAT_PREPAID_ORDER=""
# fleet-ops#3125: seat-caps product_order. "yield" routes product picks
# (PI_PICK_ROLE=product) through the rolling PR-yield ledger instead of the
# free-first ladder; empty/absent keeps the class-bucket ladder.
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

# fleet-ops#457: lanes whose snapshot metrics exceed quality-routing.json
# cuts. Empty when the scoreboard is missing/stale. Loaded once per pick.
_quality_routing_loaded=0
declare -A QUALITY_HEAVY_BAN=()

# fleet-ops#3250: per-seat rolling PR-yield ledger. Loaded once per pick so
# downstream gating has fresh data; missing/stale -> empty -> 0.5 fallback.
_seat_yield_loaded=0
declare -A SEAT_YIELD=()

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
    _seat_yield_loaded=1
    [[ -f "$SEAT_YIELD_JSON" ]] || return 0
    [[ -s "$SEAT_YIELD_JSON" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local seat y _sessions _provisional
    while IFS=$'\t' read -r seat y _sessions _provisional; do
        [[ -n "$seat" ]] || continue
        SEAT_YIELD["$seat"]="$y"
    done < <(
        jq -r 'to_entries[]
               | [ .key,
                   (.value.yield // 0.5 | tostring),
                   (.value.sessions // 0 | tostring),
                   (.value.provisional // true | tostring) ]
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
    SEAT_CAP_ZERO_CLASS_INTENTIONAL=()
    SEAT_CAP_ZERO_CLASS_STALE=()
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

    [[ -f "$SEAT_CAPS_JSON" ]] || { seat_log "seat-caps: NO CAPS FILE at $SEAT_CAPS_JSON — falling back to no-cap behaviour"; return 1; }
    if ! jq -e . "$SEAT_CAPS_JSON" >/dev/null 2>&1; then
        seat_log "seat-caps: $SEAT_CAPS_JSON unparseable — falling back to no-cap behaviour"
        return 1
    fi

    local ram ores tgt
    ram=$(jq -r '.ram_gb_per_worker // 1.5' "$SEAT_CAPS_JSON")
    [[ "$ram" =~ ^[0-9]+(\.[0-9]+)?$ ]] && SEAT_RAM_GB_PER_WORKER="$ram"
    ores=$(jq -r '.org_reserve // 2' "$SEAT_CAPS_JSON")
    [[ "$ores" =~ ^[0-9]+$ ]] && SEAT_ORG_RESERVE="$ores"
    tgt=$(jq -r '.target_concurrent // 25' "$SEAT_CAPS_JSON")
    [[ "$tgt" =~ ^[0-9]+$ ]] && SEAT_TARGET_CONCURRENT="$tgt"

    # fleet-ops#602: the read loops below must use LOCAL variables. bash's
    # `local` is DYNAMIC scoping, so a bare `p`/`m` here would write into the
    # caller's variable of the same name — a lazy-loading model_cap()/class_of()
    # would have its own $p/$m clobbered to the last jq line before its lookup
    # ran, returning 0 for every unlisted-model seat and NO-USABLE-SEAT for
    # the whole free role (pi-audit@ free-glm-5-3 unit-failure loop 2026-08-27).
    local p m cap class bench_def max_probe hard reason window budget ko ov_model ov_ex ov_usd cb
    # Unit separator (\x1f), not TSV: bash `read` collapses consecutive tabs
    # so optional empty fields (max_probe_ceiling, reason) would vanish.
    while IFS=$'\x1f\n' read -r p cap class bench_def max_probe hard reason icz; do
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
        # fleet-ops#1432: classification of cap=0 seats (intentional vs stale).
        # fleet-ops#2435: "corpse" joins the intentional set — a model whose
        # ledger is seat_dead (terminal "corpse" class, no comeback clock)
        # is retired, never re-auditioned, so its cap-0 skip classifies as
        # intentional (by design), not stale (re-audit when the external
        # condition clears).
        if [[ "$icz" == "dead_decoy" || "$icz" == "money_only" || "$icz" == "corpse" ]]; then
            SEAT_CAP_ZERO_CLASS_INTENTIONAL["$p"]="$icz"
        elif [[ "$icz" == "stale" ]]; then
            SEAT_CAP_ZERO_CLASS_STALE["$p"]="$icz"
        fi
    # A provider may be a bare number (shorthand for cap=N, class=free, no
    # models — e.g. "devin": 0). Indexing .value.cap on a number crashes jq
    # and, with `2>/dev/null || true`, silently empties the whole cap map —
    # which then makes total_seat_cap() return 0 and the intake ceiling fall
    # back to the (inflated) RAM governor. Normalise by type first.
    # quota_bench_default_s (fleet-ops#90) is optional; absent -> empty ->
    # provider_quota_bench_default returns 0 (no default, writer fails open).
    # max_probe_ceiling / hard_ceiling / reason (fleet-ops#217) likewise
    # optional; absent fields emit "" so the guards above skip them.
    done < <(jq -r '.providers | to_entries[] | .key as $k | .value as $v | [$k, (if ($v|type)=="number" then $v else ($v.cap // 0) end), (if ($v|type)=="number" then "free" else ($v.class // "free") end), (if ($v|type)=="object" then ($v.quota_bench_default_s // "") else "" end), (if ($v|type)=="object" then ($v.max_probe_ceiling // "") else "" end), (if ($v|type)=="object" then ($v.hard_ceiling // false) else false end), (if ($v|type)=="object" then ($v.reason // "") else "" end), (if ($v|type)=="object" then ($v.intentional_cap_zero // "") else "" end)] | join("\u001f")' "$SEAT_CAPS_JSON" 2>/dev/null || true)

    while IFS=$'\x1f\n' read -r p m cap class mprobe; do
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
        # fleet-ops#1432: model-level intentional_cap_zero classification.
        # Only present when the model value is an object (not a bare number).
        if [[ ! "$cap" =~ ^[0-9]+$ ]]; then
            local icz
            icz=$(jq -r '.intentional_cap_zero // ""' <<<"$cap" 2>/dev/null || true)
            # fleet-ops#2435: "corpse" is intentional too — see the provider
            # loop comment. Matches the ledger's terminal corpse class.
            if [[ "$icz" == "dead_decoy" || "$icz" == "money_only" || "$icz" == "corpse" ]]; then
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
        fi
    # Unit separator (\x1f), not TSV, for the same reason the providers loop
    # uses it: bash `read` collapses consecutive tabs, so an empty per-model
    # `class` would shift `max_probe_ceiling` out of mprobe and the model
    # probe ceilings would silently never load (fleet-ops#3125).
    done < <(jq -r '.providers | to_entries[] | .key as $p | .value as $v | (if ($v|type)=="object" then ($v.models // {}) else {} end) | to_entries[] | [$p, .key, (.value // 0 | tostring), (if (.value|type)=="object" then (.value.class // "") else "" end), (if (.value|type)=="object" then (.value.max_probe_ceiling // "") else "" end)] | join("\u001f")' "$SEAT_CAPS_JSON" 2>/dev/null || true)

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
            seat_log "cap0-stale-expire: $key stale cap=0 expired (age=$((now_s - date_s))s; reason dated ${date_str}) -> re-admitted at cap=$default for re-probe (fleet-ops#3111)"
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

# Default bench window (seconds) for a provider's quota/cap 429 when the
# error text carries no explicit reset window (fleet-ops#90). 0 = no default
# configured; the writer then fails open (no marker) and relies on the
# reactive seat-health ledger's existing quota_exhausted block.
provider_quota_bench_default() {
    local p="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    echo "${SEAT_PROVIDER_BENCH_DEFAULT[$p]:-0}"
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

load_learned_caps() {
    LEARNED_CAP=()
    LEARNED_BENCH_UNTIL=()
    _seat_learned_loaded=1
    [[ -f "$LEARNED_CAPS_JSON" ]] || return 0
    local p lc bu
    while IFS=$'\x1f\n' read -r p lc bu; do
        [[ -n "$p" ]] || continue
        [[ "$lc" =~ ^[0-9]+$ ]] && LEARNED_CAP["$p"]="$lc"
        [[ -n "$bu" ]] && LEARNED_BENCH_UNTIL["$p"]="$bu"
    done < <(jq -r '.providers // {} | to_entries[] | [.key, (.value.learned_cap//""), (.value.bench_until//"")] | join("\u001f")' "$LEARNED_CAPS_JSON" 2>/dev/null || true)
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

_learned_audit() {
    local line="$1"
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >>"$LEARNED_CAPS_AUDIT" 2>/dev/null || true
}

_set_learned_in_memory() {
    local p="$1" lc="$2" bench="${3:-}"
    LEARNED_CAP["$p"]="$lc"
    if [[ -n "$bench" ]]; then
        LEARNED_BENCH_UNTIL["$p"]="$bench"
    else
        unset 'LEARNED_BENCH_UNTIL[$p]'
    fi
}

# Persist learned state for one provider and emit an audit line.
# Args: provider learned_cap result bench_until
# result in {probe, backoff, decay}.
_record_learned_cap() {
    local p="$1" lc="$2" result="$3" bench="${4:-}"
    [[ "$lc" =~ ^[0-9]+$ ]] || return 1
    mkdir -p "$(dirname "$LEARNED_CAPS_JSON")" 2>/dev/null || true
    local tmp="$LEARNED_CAPS_JSON.tmp.$$.$RANDOM" now_utc
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [[ -f "$LEARNED_CAPS_JSON" ]] && jq -e . "$LEARNED_CAPS_JSON" >/dev/null 2>&1; then
        # Merge via object addition, not $ps[$p] = ... jq 1.7 rejects
        # assignment through a variable-held object ("Invalid path
        # expression") and the fallback would then rewrite the file with
        # only this provider, wiping sibling learned caps.
        if jq --arg p "$p" --argjson lc "$lc" --arg r "$result" \
                --arg b "$bench" --arg t "$now_utc" \
            '.providers = ((.providers // {}) + {($p): {learned_cap:$lc, last_result:$r, bench_until:(if $b == "" then null else $b end), last_at:$t}})' \
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
            --arg b "$bench" --arg t "$now_utc" \
            '{providers: {($p): {learned_cap:$lc, last_result:$r, bench_until:(if $b == "" then null else $b end), last_at:$t}}}' >"$tmp" 2>/dev/null; then
            seat_log "aimd: state write FAILED for $p (lc=$lc result=$result) — in-memory only"
            rm -f "$tmp" 2>/dev/null || true
            _set_learned_in_memory "$p" "$lc" "$bench"
            return 0
        fi
    fi
    chmod 0644 "$tmp" 2>/dev/null || true
    if mv "$tmp" "$LEARNED_CAPS_JSON" 2>/dev/null; then
        _set_learned_in_memory "$p" "$lc" "$bench"
        local bench_desc="no bench"
        [[ -n "$bench" ]] && bench_desc="bench_until=$bench"
        _learned_audit "aimd $p: learned_cap=$lc result=$result $bench_desc"
        return 0
    fi
    seat_log "aimd: state rename FAILED for $p at $LEARNED_CAPS_JSON — in-memory only"
    rm -f "$tmp" 2>/dev/null || true
    _set_learned_in_memory "$p" "$lc" "$bench"
    return 0
}

# Effective cap pick_seat honours. Records backoff on a fresh 429.
# Order: hard_ceiling -> fresh 429 backoff -> bench in effect -> decay ->
# clamp learned to [declared, ceiling].
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
    if provider_has_recent_error "$p"; then
        local backoff=$(( declared / 2 ))
        (( backoff < 1 )) && backoff=1
        local bench
        bench=$(_provider_bench_until "$p")
        local cur="${LEARNED_CAP[$p]:-}"
        local cur_bench="${LEARNED_BENCH_UNTIL[$p]:-}"
        if [[ "$cur" != "$backoff" || "$cur_bench" != "$bench" ]]; then
            _record_learned_cap "$p" "$backoff" "backoff" "$bench"
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
            _record_learned_cap "$p" "$declared" "decay" ""
        elif [[ -n "$cur" ]]; then
            _record_learned_cap "$p" "$declared" "decay" ""
        fi
        echo "$declared"
        return
    fi
    local current="${LEARNED_CAP[$p]:-}"
    if [[ ! "$current" =~ ^[0-9]+$ ]]; then current="$declared"; fi
    local eff=$(( current < ceiling ? current : ceiling ))
    (( eff < declared )) && eff=$declared
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
    (( ram_cap > active_total )) || return 1
    local new=$(( eff + 1 ))
    (( new > ceiling )) && new=$ceiling
    _record_learned_cap "$p" "$new" "probe" ""
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
    (( ram_cap > active_total )) || return 1
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
    local sn p m
    for sn in "${SEAT_SENIOR_ORDER[@]}"; do
        [[ -n "$sn" ]] || continue
        p="${sn%%/*}"
        m="${sn#*/}"
        [[ -n "$p" && -n "$m" ]] || continue
        [[ "$(model_cap "$p" "$m" 2>/dev/null || echo 0)" -gt 0 ]] 2>/dev/null || continue
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

# Mirror of seat-health.ts seatLedgerPath: sanitise provider/model so model
# ids containing '/' (e.g. deepseek/deepseek-v4-flash) survive on disk.
seat_ledger_path() {
    local p="$1" m="$2" ps ms
    ps="${p//[^A-Za-z0-9._-]/_}"
    ms="${m//[^A-Za-z0-9._-]/_}"
    printf '%s/%s__%s.json\n' "$LEDGER_DIR" "$ps" "$ms"
}

# fleet-ops#1512: separate spawn-fail/empty-run bench marker. The per-seat
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
# seats: opencode/nemotron-3-ultra-free, openrouter/deepseek/deepseek-v4-flash-0731).
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
# Args: provider model usable_at reason backoff_s count failure_mode
_seat_write_spawn_bench() {
    local p="$1" m="$2" usable="$3" reason="$4" backoff="$5"
    local count="${6:-0}" mode="${7:-unknown}"
    local path now_utc tmp
    path=$(seat_spawn_bench_path "$p" "$m")
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    tmp="$path.$$.$RANDOM.tmp"
    if jq -nc \
        --arg provider "$p" --arg model "$m" --arg usable "$usable" \
        --arg reason "$reason" --arg written "$now_utc" --argjson backoff "$backoff" \
        --arg mode "$mode" --argjson count "$count" \
        '{provider:$provider, model:$model, usable_at:$usable,
          reason:$reason, written_at:$written, backoff_s:$backoff,
          failure_mode:$mode, consecutive_failure_count:$count}' \
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
#   - transient_fault past SEAT_FAILURE_CEILING consecutive failures -> unusable
#     (parked behind the long wall until observed_at + SEAT_PARK_WALL_S, then
#     fail-opens — the fleet-ops#2288 read-side fence for extension-written
#     flat-window markers whose write-side escalation lives in the out-of-repo
#     extension).
#   - otherwise                                   -> usable.
seat_usable() {
    local p="$1" m="$2" f hc dead observed usable_at bench_until fail_count
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
    # whether the ledger file exists at all). An expired marker falls through
    # to the ledger (fail-open, same as the ledger's own bench_until expiry).
    local sb_path sb_usable
    sb_path=$(seat_spawn_bench_path "$p" "$m")
    if [[ -f "$sb_path" ]]; then
        sb_usable=$(jq -r '.usable_at // ""' "$sb_path" 2>/dev/null || true)
        if [[ -n "$sb_usable" ]] && _seat_in_future "$sb_usable"; then
            seat_log "seat $p/$m: UNUSABLE (spawn-bench until $sb_usable — wrapper bench held)"
            return 1
        fi
    fi
    f=$(seat_ledger_path "$p" "$m")
    if [[ ! -f "$f" ]]; then
        (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: NO HEALTH DATA (no ledger file) — assuming usable"
        return 0
    fi
    # Unit-separator join (not TSV): bash `read` treats tab as IFS whitespace
    # and collapses consecutive tabs, which would shift bench_until left when
    # usable_at is empty (the 9d fixture and any ledger without usable_at).
    # \x1f is not whitespace, so empty fields survive. Include newline in IFS
    # so the trailing jq newline is not glued onto bench_until.
    IFS=$'\x1f'$'\n' read -r hc dead observed usable_at bench_until fail_count < <(
        jq -r '[(.health_class//""),(.seat_dead|tostring),(.observed_at//""),(.usable_at//""),(.bench_until//""),(.consecutive_failure_count//0)] | join("\u001f")' "$f" 2>/dev/null || true
    )
    if [[ -z "$hc" ]]; then
        (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: NO HEALTH DATA (ledger unparseable) — assuming usable"
        return 0
    fi
    # quota_bench BEFORE stale-observed_at: bench_until is the source of truth
    # for the advertised reset window, which can outlive STALE_SECS.
    if [[ "$hc" == "quota_bench" ]]; then
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
    # cline-pass/deepseek-v4-flash + cline-pass/minimax-m3 both 402 with
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
    # use: past SEAT_FAILURE_CEILING a transient_fault ledger is held until
    # observed_at + SEAT_PARK_WALL_S, then fail-opens (one probe per park
    # wall, not per flat window). Same contract as #1362: a healthy write
    # resets count to 0, so a recovered seat is never walled permanently.
    if [[ "$hc" == "transient_fault" && -n "$observed" ]] && _seat_parked_by_ceiling "$fail_count"; then
        local park_end_s park_end_iso
        park_end_s=$(($(date -u -d "$observed" +%s 2>/dev/null || echo 0) + SEAT_PARK_WALL_S))
        park_end_iso=$(date -u -d "@$park_end_s" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$observed")
        if _seat_in_future "$park_end_iso"; then
            (( ${_SEAT_USABLE_SILENT:-0} )) || seat_log "seat $p/$m: UNUSABLE (transient_fault count=$fail_count >= ${SEAT_FAILURE_CEILING:-20}, parked until $park_end_iso — long wall, not flat re-offer)"
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

# P15: a unit in `activating` for longer than this is a wedge, not a
# worker. Type=oneshot workers legitimately sit in `activating` for up to
# TimeoutStartSec=45min (the unit's own hang bound); anything beyond that
# bound + margin is a hung pi that the wrapper watchdog (PI_HANG_TIMEOUT_S,
# default 42 min) should have killed but didn't (older wrapper, SIGKILL
# path, unit timeout race). The unit table's ActiveEnterTimestamp is the
# ground truth for how long it has been trying to start.
PI_SEAT_ACTIVATING_MAX_S="${PI_SEAT_ACTIVATING_MAX_S:-3300}"  # 55 min > unit 45 min

# fleet-ops#1361: shorter threshold for units stuck in activating without ever
# launching their process (ExecMainStartTimestampMonotonic=0). 5 min is enough
# to detect a unit that will never start its process.
PI_SEAT_ACTIVATING_NO_PROCESS_MAX_S="${PI_SEAT_ACTIVATING_NO_PROCESS_MAX_S:-300}"  # 5 min
# True if the registry file's unit is still a live pi worker unit.
# Non-zero (stale) when the unit is dead, missing, or not a pi unit name.
#
# The registry stores the bare instance name (e.g. "pi-issue-fleet-ops-21",
# matching the unit's %i / the active-seats filename), NOT the full unit
# name. The full systemd unit is "pi-issue@<instance>.service" (template
# unit) for issue workers and "pi-packet@<instance>.service" for packet
# workers. Translate here so systemctl queries the real unit.
_seat_registry_unit_live() {
    local f="$1" unit="" sysunit=""
    unit=$(jq -r '.unit // ""' "$f" 2>/dev/null || true)
    [[ -n "$unit" ]] || return 1
    case "$unit" in
        pi-issue-*) sysunit="pi-issue@${unit#pi-issue-}.service" ;;
        pi-packet-*) sysunit="pi-packet@${unit#pi-packet-}.service" ;;
        *) return 1 ;;
    esac
    local state active_since now age_s
    state=$(systemctl --user is-active "$sysunit" 2>/dev/null || true)
    # A running Type=oneshot worker reports "activating" while its process
    # runs; "active" also means live. Anything else (inactive/failed/
    # auto-restart with MainPID=0) is not consuming a seat.
    if [[ "$state" == "active" ]]; then
        return 0
    fi
    if [[ "$state" != "activating" ]]; then
        return 1
    fi
    # P15 wedge probe: `activating` is normally live (up to the unit's own
    # TimeoutStartSec), but a unit stuck activating past the wrapper's hang
    # bound + margin is a wedged pi whose seat registration must be reaped
    # so caps free up. A SIGKILLed wedged worker leaves `activating`
    # (systemd -9 leaves the unit start state) — age is the only honest
    # signal. This is the fleet-ops#83 blind spot: the probe treated every
    # `activating` as live, so a wedged unit held its seat for the full
    # 45-minute TimeoutStartSec and starved pick_seat.
    #
    # fleet-ops#993 (2026-08-27 outage): ActiveEnterTimestampMonotonic is 0
    # for EVERY Type=oneshot unit that is still `activating` (systemd only
    # stamps it when the start completes). With a live worker that has run
    # 30+ min that read 0 -> age_s = uptime - 0 = 1.4M s > max -> every live
    # seat got reaped, cap accounting went blind, and pick_seat piled
    # unbounded workers onto the first free seat (the 8-vCPU box saturating
    # at load 87, SustainedLoadHigh alert, zero-tools repair failure).
    # Measure age from ExecMainStartTimestampMonotonic instead — systemd
    # stamps it when the worker's ExecStart pi process actually started,
    # so it is nonzero for every activating oneshot with a live process —
    # and treat an unparseable/0 timestamp as live (a young unit that
    # systemd has not yet stamped is not wedged).
    #
    # fleet-ops#1361 (2026-08-29): When ExecMainStartTimestampMonotonic=0
    # (process never started), the unit is stuck in activating without ever
    # launching pi. Use ActiveEnterTimestampMonotonic (when the unit entered
    # activating state) with a shorter threshold (5 min) since a unit that
    # hasn't started its process after 5 min in activating is clearly broken.
    # Also: when ExecMainStartTimestampMonotonic>0 but SubState="start"
    # (process started but unit stuck in startup phase), use a shorter
    # threshold (5 min) since a real worker transitions to active/running
    # within seconds.
    active_since=$(systemctl --user show "$sysunit" --property=ExecMainStartTimestampMonotonic --value 2>/dev/null || echo 0)
    # Both timestamps are in MICROSECONDS since boot; /proc/uptime is in
    # SECONDS. Compare in seconds to avoid ms/us mixing.
    if [[ "$active_since" =~ ^[0-9]+$ ]] && (( active_since > 0 )); then
        now_s=$(awk '{print int($1)}' /proc/uptime)
        age_s=$(( now_s - active_since / 1000000 ))
        # Check SubState: if stuck in "start" phase, use shorter threshold.
        local sub_state
        sub_state=$(systemctl --user show "$sysunit" --property=SubState --value 2>/dev/null || echo "")
        local max_s=${PI_SEAT_ACTIVATING_MAX_S}
        if [[ "$sub_state" == "start" ]]; then
            # Process started but unit stuck in startup phase — use 5 min threshold.
            max_s=${PI_SEAT_ACTIVATING_NO_PROCESS_MAX_S:-300}
        fi
        if (( age_s > max_s )); then
            seat_log "seat registry: unit $sysunit stuck activating ${age_s}s (SubState=$sub_state, threshold=${max_s}s) — wedged pi, reaping seat"
            return 1
        fi
    else
        # Process never started (ExecMainStartTimestampMonotonic=0). Check how
        # long the unit has been in activating state using ActiveEnterTimestampMonotonic.
        # A unit stuck in activating without launching its process for >5 min is wedged.
        local active_enter
        active_enter=$(systemctl --user show "$sysunit" --property=ActiveEnterTimestampMonotonic --value 2>/dev/null || echo 0)
        if [[ "$active_enter" =~ ^[0-9]+$ ]] && (( active_enter > 0 )); then
            now_s=$(awk '{print int($1)}' /proc/uptime)
            age_s=$(( now_s - active_enter / 1000000 ))
            # Shorter threshold for units that never started their process: 5 min.
            local no_process_max_s=${PI_SEAT_ACTIVATING_NO_PROCESS_MAX_S:-300}
            if (( age_s > no_process_max_s )); then
                seat_log "seat registry: unit $sysunit stuck activating ${age_s}s without process launch (> ${no_process_max_s}s) — wedged pi, reaping seat"
                return 1
            fi
        fi
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

# Total RAM charge of active workers in light-worker units. Heavy workers
# (packet difficulty heavy|keystone) are charged at 1.0 GB = 2x the light
# 0.5 GB, so they count double; org/repair packets stay at 1x. This is what
# the RAM governor's cap is compared against so heavy workers consume their
# real 1.0 GB share of MemAvailable (fleet-ops#3281).
active_ram_charge() {
    local total heavy
    total=$(count_active_total)
    heavy=$(count_active_heavy)
    echo $(( total + heavy ))
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
    local p="$1" f week count tmp
    week=$(_prepaid_iso_week)
    f=$(_prepaid_usage_path "$p")
    mkdir -p "$STATE_DIR/prepaid-usage"
    count=$(_prepaid_usage "$p")
    count=$((count + 1))
    tmp="$f.tmp.$$"
    jq -nc --arg w "$week" --argjson c "$count" '{week:$w,count:$c}' >"$tmp" 2>/dev/null || {
        rm -f "$tmp"
        return 0
    }
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
        for x in "${ordered[@]:-}"; do
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
    # only deepseek-v4-flash:0731, so kimi-k2.7-code is not allowlisted).
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
SEAT_FLOOR_FAILOPEN_CLASSES="transient_fault rate_limited empty_run overload_bench"

# True if this ledger row is a money wall the floor must never lift.
# Args: health_class seat_dead [failure_mode]
_seat_floor_is_money_wall() {
    local hc="$1" dead="$2" fm="${3:-}"
    [[ "$dead" == "true" ]] && return 0
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
    [[ "$fm" == "empty_run" ]] && return 0
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
        park_end_iso=$(date -u -d "@$(( $(date -u -d "$observed" +%s 2>/dev/null || echo 0) + SEAT_PARK_WALL_S ))" \
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
        _seat_floor_is_money_wall "$hc" "$dead" "$fm" && continue
        if ! _seat_floor_is_failopen_class "$hc" "$fm"; then
            # Wrapper spawn-bench can outlive a healthy ledger clobber
            # (fleet-ops#1512). empty_run / spawn_fail on the marker are
            # recoverable; anything else is not a floor candidate.
            local sb_path sb_usable sb_mode
            sb_path=$(seat_spawn_bench_path "$p" "$m")
            [[ -f "$sb_path" ]] || continue
            sb_usable=$(jq -r '.usable_at // ""' "$sb_path" 2>/dev/null || true)
            sb_mode=$(jq -r '.failure_mode // ""' "$sb_path" 2>/dev/null || true)
            _seat_in_future "$sb_usable" || continue
            case "$sb_mode" in
                empty_run|spawn_fail|unknown) fm="$sb_mode" ;;
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
    _cred_cache=()

    # Build the set of tried seats for exclusion.
    declare -A tried=()
    tried["$fail_p/$fail_m"]=1
    local tried_count=0
    if [[ -n "$tried_file" && -f "$tried_file" ]]; then
        local tp tm
        while IFS=/ read -r tp tm; do
            [[ -n "$tp" ]] && tried["$tp/$tm"]=1 && tried_count=$((tried_count + 1))
        done <"$tried_file"
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
        case "$class" in
            prepaid-quota) prepaid_seats+=("$p"$'\t'"$m") ;;
            metered)       metered_seats+=("$p"$'\t'"$m") ;;
            *)             free_seats+=("$p"$'\t'"$m") ;;
        esac
    done < <(enumerate_seats)

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
    # Keystone and non-product picks keep the class ladder below.
    local -a product_seats=()
    if ! _is_keystone_class "$difficulty" \
        && [[ "${PI_PICK_ROLE:-scout}" == "product" ]] \
        && [[ "$SEAT_PRODUCT_ORDER" == "yield" ]]; then
        local -a _yranked=()
        mapfile -t _yranked < <(
            _i=0
            for _fm in "${prepaid_seats[@]:-}" "${metered_seats[@]:-}" "${free_seats[@]:-}"; do
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
        for _yline in "${_yranked[@]:-}"; do
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
    if _is_keystone_class "$difficulty"; then
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
        fi
    elif (( ${#product_seats[@]} > 0 )); then
        chosen="${product_seats[0]}"
        chosen_p="${chosen%%$'\t'*}"
        chosen_m="${chosen#*$'\t'}"
        # Prepaid seats still burn weekly pacing when yield picks them.
        if [[ "$(model_class_of "$chosen_p" "$chosen_m")" == "prepaid-quota" ]]; then
            _record_prepaid_pick "$chosen_p"
        fi
    elif (( ${#free_seats[@]} > 0 )); then
        chosen="${free_seats[0]}"
    elif (( ${#prepaid_seats[@]} > 0 )); then
        chosen=$(_rr_pick "$STATE_DIR/prepaid-rr.idx" "${prepaid_seats[@]}")
        chosen_p="${chosen%%$'\t'*}"
        _record_prepaid_pick "$chosen_p"
    elif (( ${#metered_seats[@]} > 0 )); then
        chosen="${metered_seats[0]}"
    fi
    if [[ -n "$chosen" ]]; then
        record_seat_selection "${chosen%%$'\t'*}" "${chosen#*$'\t'}" "$difficulty"
        if _is_keystone_class "$difficulty"; then
            keystone_record_event routed "${chosen%%$'\t'*}" "${chosen#*$'\t'}"
        fi
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

# Echo the effective park wall seconds for a consecutive_failure_count and a
# computed base backoff/window. When count >= SEAT_FAILURE_CEILING the wall is
# forced to SEAT_PARK_WALL_S (the park); otherwise the base is echoed unchanged.
# An optional 3rd argument overrides the ceiling for this call (fleet-ops#2627:
# EMPTY_RUN_FAILURE_CEILING can be lower than the generic SEAT_FAILURE_CEILING
# so a chronic no-op seat parks sooner). Defensive: non-numeric inputs fall
# back to the base / count=0.
_failure_ceiling_wall() {
    local count="${1:-0}" base="${2:-300}" ceil_override="${3:-}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    [[ "$base" =~ ^[0-9]+$ ]] || base=300
    local ceil="${SEAT_FAILURE_CEILING:-20}"
    [[ -n "$ceil_override" ]] && ceil="$ceil_override"
    local park="${SEAT_PARK_WALL_S:-86400}"
    [[ "$ceil" =~ ^[0-9]+$ ]] || ceil=20
    [[ "$park" =~ ^[0-9]+$ ]] || park=86400
    if (( count >= ceil )); then
        printf '%s' "$park"
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
    if ! grep -qiE 'ETIMEDOUT|connection timed out|connect ETIMEDOUT|timed out waiting' <<<"$combined"; then
        return 1
    fi
    # Co-occurrence guard: a worker that took down stdout verbosely could
    # mention "timed out" without it being spawn-time. Require at least one
    # spawn-signal word within +/- 120 chars of the timed-out match. This
    # is the cheap regex-version of "did this happen before pi had a real
    # response" — a real timeout mid-session is paired with an HTTP status,
    # never with spawn/socket/connect/child.
    if grep -qiE '.{0,120}(ETIMEDOUT|timed out).{0,120}(spawn|socket|connect|child|fetch|handshake)' <<<"$combined"; then
        return 0
    fi
    if grep -qiE '(spawn|socket|connect|child|fetch|handshake).{0,120}(ETIMEDOUT|timed out)' <<<"$combined"; then
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
    local prev_count=0 sb_mcount sb_written sb_marker_path now_s written_s
    sb_marker_path=$(seat_spawn_bench_path "$p" "$m")
    if [[ -f "$sb_marker_path" ]]; then
        sb_mcount=$(jq -r '.consecutive_failure_count // 0' "$sb_marker_path" 2>/dev/null || echo 0)
        [[ "$sb_mcount" =~ ^[0-9]+$ ]] || sb_mcount=0
        sb_written=$(jq -r '.written_at // ""' "$sb_marker_path" 2>/dev/null || true)
        if [[ -n "$sb_written" ]]; then
            now_s=$(date -u +%s)
            written_s=$(date -u -d "$sb_written" +%s 2>/dev/null || echo 0)
            if [[ "$written_s" =~ ^[0-9]+$ ]] && (( written_s > 0 )) \
                && (( now_s - written_s <= EMPTY_RUN_MARKER_FRESH_S )); then
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
    # Compute usable_at = now + backoff (ISO 8601, bash portable: -d @ + offsets).
    local usable_at
    usable_at=$(date -u -d "@$(($(date -u +%s) + backoff))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")

    if ! jq -nc \
        --arg provider "$p" --arg model "$m" --arg reason "$reason" \
        --arg observed "$now_utc" --arg usable "$usable_at" \
        --argjson http_status 0 --argjson retry_after null \
        --argjson retryable true --argjson seat_dead false --argjson poison_ladder false \
        --argjson backoff "$backoff" --argjson merged "$merged_count" \
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
          spawn_fail_backoff_s:$backoff
        }' > "$tmp" 2>/dev/null; then
        seat_log "spawn-fail: jq compose FAILED for $p/$m (reason=$reason) — marker NOT written"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 0644 "$tmp" 2>/dev/null || true
    if mv "$tmp" "$path" 2>/dev/null; then
        seat_log "spawn-fail: marked $p/$m unusable until $usable_at (reason=$reason, backoff=${backoff}s, count=$merged_count)"
        if _seat_parked_by_ceiling "$merged_count"; then
            _emit_failure_ceiling_metric "$p" "$m" "$merged_count"
            seat_log "spawn-fail: $p/$m PARKED past failure ceiling (count=$merged_count >= ${SEAT_FAILURE_CEILING}, wall=${backoff}s)"
        fi
        # fleet-ops#1512: also write the clobber-proof spawn-bench marker so
        # seat_usable honours this bench even if seat-health.ts later writes a
        # healthy observation to the ledger. Best-effort: a marker write
        # failure does not undo the ledger write above. fleet-ops#2627: also
        # carry the consecutive_failure_count and failure_mode so the marker
        # is the durable count authority for the bench class — the ledger's
        # count is reset to 0 by seat-health.ts's healthy clobber, and the
        # failure-ceiling park must engage from the marker-carried count.
        _seat_write_spawn_bench "$p" "$m" "$usable_at" "$reason" "$backoff" "$merged_count" "spawn_fail" 2>/dev/null || true
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
EMPTY_RUN_BACKOFF_S="${EMPTY_RUN_BACKOFF_S:-900}"  # 15 min
# fleet-ops#2343: an empty run is a provider NO-OP, not a quota wall, and
# must NOT escalate by count. The fleet-ops#1408 ladder (900 -> 1800 -> 3600
# -> 7200s) churned HEALTHY seats: openrouter/deepseek/deepseek-v4-flash-0731
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
# deepseek-v4-flash-0731 no-op'ed 5+ times in 2h with every ledger write
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
# alternates between empty_run and spawn_fail. EMPTY_RUN_FAILURE_CEILING
# lowers the chronic-no-op park threshold below the generic
# SEAT_FAILURE_CEILING (default 3 vs 20) so a free-lane no-op'er parks
# within a following 2h window, not after 20 cycles (~5h at flat 900s).
# fleet-ops#3046: the prior default of 10 was too high for the live
# nemotron-3-ultra-free loop — 9 empty runs in 2h on the same issue
# (fleet-ops-2778) never reached 10 because the count-merge window
# (EMPTY_RUN_COUNT_WINDOW_S, 2 h) reset the count on every 3rd run as the
# 2h SLO window slid past the first no-op. A ceiling of 3 parks the seat
# on the 3rd no-op in the SAME 2h window, so the loop cannot outpace the
# count-merge window the way 10 did.
#
# fleet-ops#2934: the count-merge window for EMPTY RUNS is LONGER than the
# spawn-fail window. EMPTY_RUN_MARKER_FRESH_S (30 min) was the merge bound
# for BOTH classes, but an intermittent no-op'er gaps its empty runs by
# more than 30 min (live 2026-09-02: openrouter/deepseek/deepseek-v4-flash-
# 0731 no-op'ed at 18:40:08Z count=2, then 20:22:31Z count=1 — the 1h42m
# gap aged the marker past 30 min, the count reset, the ceiling never
# fired, the seat re-entered rotation every 900 s and no-op'ed again). A
# provider no-op is intermittent, not clustered the way a spawn-fail storm
# is, so the recovery signal (no new empty run for N min) needs a longer
# N to be trustworthy. EMPTY_RUN_COUNT_WINDOW_S (default 7200 = 2 h,
# matching the waste.empty_runs_last_2h SLO window) bounds the empty-run
# count merge: a marker younger than that is still fresh and its count
# carries forward; a marker older than 2 h means the seat went a full SLO
# window without no-op'ing — the real recovery signal — so the count
# resets. spawn_fail keeps the 30-min window (spawn storms are clustered;
# a 2 h window would let a long-ago spawn_fail inflate a fresh empty-run
# count). The bench itself is still the FLAT 900 s cooldown (fleet-ops#2343
# — no ladder); only the COUNT-accumulation window widens, so the
# failure-ceiling park can engage for a chronic intermittent no-op'er
# without re-introducing the bench ladder that churned healthy seats.
EMPTY_RUN_BACKOFF_S="${EMPTY_RUN_BACKOFF_S:-900}"  # 15 min
EMPTY_RUN_MARKER_FRESH_S="${EMPTY_RUN_MARKER_FRESH_S:-1800}"  # 30 min — spawn-fail count-merge window (see comment above)
EMPTY_RUN_COUNT_WINDOW_S="${EMPTY_RUN_COUNT_WINDOW_S:-7200}"  # 2 h — empty-run count-merge window (fleet-ops#2934); matches waste.empty_runs_last_2h
EMPTY_RUN_FAILURE_CEILING="${EMPTY_RUN_FAILURE_CEILING:-3}"  # default 3 (vs generic 20) parks chronic no-op seats on the 3rd no-op in a 2h window (fleet-ops#3046)

mark_seat_empty_run() {
    local p="$1" m="$2" reason="${3:-empty_run}"
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
    # EMPTY_RUN_COUNT_WINDOW_S, default 2 h — fleet-ops#2934) means the
    # seat went a full SLO window without no-op'ing — the real recovery
    # signal — so we fall through to the ledger (which seat-health.ts
    # clobbered to count=0) and start fresh. The window is LONGER than
    # mark_seat_spawn_fail's (EMPTY_RUN_MARKER_FRESH_S, 30 min) because a
    # provider no-op is intermittent, not clustered: a 30 min window let a
    # ~1h42m gap reset the count on the live deepseek-v4-flash-0731 seat
    # so the failure-ceiling park never fired. The marker is a SINGLE file
    # per seat shared by mark_seat_empty_run and mark_seat_spawn_fail, so
    # the count must accumulate across failure_mode classes (fleet-ops#2786:
    # a same-class-only merge lost the empty_run count the instant a
    # spawn_fail marker overwrote the file — live: 10 empty runs on
    # opencode/nemotron-3-ultra-free, every marker count=1).
    local prev_count=0 sb_mcount sb_written sb_marker_path now_s written_s
    sb_marker_path=$(seat_spawn_bench_path "$p" "$m")
    if [[ -f "$sb_marker_path" ]]; then
        sb_mcount=$(jq -r '.consecutive_failure_count // 0' "$sb_marker_path" 2>/dev/null || echo 0)
        [[ "$sb_mcount" =~ ^[0-9]+$ ]] || sb_mcount=0
        sb_written=$(jq -r '.written_at // ""' "$sb_marker_path" 2>/dev/null || true)
        if [[ -n "$sb_written" ]]; then
            now_s=$(date -u +%s)
            written_s=$(date -u -d "$sb_written" +%s 2>/dev/null || echo 0)
            if [[ "$written_s" =~ ^[0-9]+$ ]] && (( written_s > 0 )) \
                && (( now_s - written_s <= EMPTY_RUN_COUNT_WINDOW_S )); then
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
    # fleet-ops#2343: FLAT no-op cooldown — no count ladder (the #1408
    # escalation churned healthy seats; a provider no-op is not a wall).
    local backoff
    backoff="$EMPTY_RUN_BACKOFF_S"
    # fleet-ops#2627: park past the EMPTY_RUN_FAILURE_CEILING (default 3,
    # lower than SEAT_FAILURE_CEILING=20) using the marker-carried count that
    # survives the healthy clobber. Without this override, the chronic no-op
    # path stays at flat 900s forever (live: 18 empty runs/2h with count=1
    # every time) — the #1362 park never fires because seat-health.ts
    # resets the ledger's count to 0 between every wrapper write. The
    # marker count is the durable authority for this class.
    backoff=$(_failure_ceiling_wall "$merged_count" "$backoff" "${EMPTY_RUN_FAILURE_CEILING:-$SEAT_FAILURE_CEILING}")
    # Compute usable_at = now + backoff (ISO 8601, bash portable).
    local usable_at
    usable_at=$(date -u -d "@$(($(date -u +%s) + backoff))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")

    if ! jq -nc \
        --arg provider "$p" --arg model "$m" --arg reason "$reason" \
        --arg observed "$now_utc" --arg usable "$usable_at" \
        --argjson http_status 200 --argjson retry_after null \
        --argjson retryable true --argjson seat_dead false --argjson poison_ladder false \
        --argjson backoff "$backoff" --argjson merged "$merged_count" \
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
          empty_run_backoff_s:$backoff
        }' > "$tmp" 2>/dev/null; then
        seat_log "empty-run: jq compose FAILED for $p/$m (reason=$reason) — marker NOT written"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 0644 "$tmp" 2>/dev/null || true
    if mv "$tmp" "$path" 2>/dev/null; then
        seat_log "empty-run: marked $p/$m unusable until $usable_at (reason=$reason, backoff=${backoff}s, count=$merged_count)"
        # fleet-ops#2627: park check uses the EMPTY_RUN ceiling override so
        # the chronic-no-op path engages the long wall before the generic
        # SEAT_FAILURE_CEILING (20) would — drops empty_runs_last_2h within
        # a following 2h window on free-lane no-op'ers.
        if _seat_parked_by_ceiling "$merged_count" "${EMPTY_RUN_FAILURE_CEILING:-$SEAT_FAILURE_CEILING}"; then
            _emit_failure_ceiling_metric "$p" "$m" "$merged_count"
            seat_log "empty-run: $p/$m PARKED past failure ceiling (count=$merged_count >= ${EMPTY_RUN_FAILURE_CEILING:-$SEAT_FAILURE_CEILING}, wall=${backoff}s)"
        fi
        # fleet-ops#1512: clobber-proof spawn-bench marker (same rationale as
        # mark_seat_spawn_fail). Best-effort. fleet-ops#2627: also carry the
        # consecutive_failure_count and failure_mode=empty_run so the next
        # empty-run call merges from this marker across any healthy ledger
        # clobber, and the chronic-no-op park engages from the durable count.
        _seat_write_spawn_bench "$p" "$m" "$usable_at" "$reason" "$backoff" "$merged_count" "empty_run" 2>/dev/null || true
        return 0
    fi
    seat_log "empty-run: rename FAILED for $p/$m at $path (reason=$reason)"
    rm -f "$tmp" 2>/dev/null || true
    return 1
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
    if ! grep -qiE 'weekly[[:space:]]+(clinepass[[:space:]]+)?limit|daily[[:space:]]+limit|quota[[:space:]]+(exhausted|exceeded|reached)|resource_exhausted|Connection error, send a message to continue retrying|INFERENCE_CAP_ERROR|usage[[:space:]]+limit|plan[[:space:]]+limit|out[[:space:]]+of[[:space:]]+credits|message[[:space:]]+rate[[:space:]]+limit|rate[[:space:]]+limit[[:space:]]+(exceeded|reached)|cap[[:space:]]+(exceeded|reached)|exceeded[[:space:]]+your' <<<"$combined"; then
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
    if grep -qiE 'weekly[[:space:]]+(clinepass[[:space:]]+)?limit|daily[[:space:]]+limit|INFERENCE_CAP_ERROR|FreeUsageLimitError|usage[[:space:]]+limit[[:space:]]+for[[:space:]]+the[[:space:]]+current[[:space:]]+free[[:space:]]+model|resource_exhausted' <<<"$combined"; then
        return 0
    fi
    return 1
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
    if _transport_is_down; then _mark_transport_down "$p" "$m"; return 1; fi
    local path
    path=$(seat_ledger_path "$p" "$m")
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true

    local window_s=0 parsed
    parsed=$(_parse_reset_window_s "$text" 2>/dev/null || true)
    [[ "$parsed" =~ ^[0-9]+$ ]] && window_s="$parsed"
    if (( window_s <= 0 )); then
        local def
        def=$(provider_quota_bench_default "$p")
        [[ "$def" =~ ^[0-9]+$ ]] && window_s="$def"
    fi

    if (( window_s <= 0 )); then
        seat_log "quota-bench: $p/$m NOT benched — no reset window parsed and no provider default in seat-caps.json (fail-open; reactive ledger remains the backstop)"
        return 1
    fi

    local now_utc now_s bench_until
    now_s=$(date -u +%s)
    now_utc=$(date -u -d "@$now_s" +%Y-%m-%dT%H:%M:%SZ)
    bench_until=$(date -u -d "@$((now_s + window_s))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")

    # Merge consecutive_failure_count from any existing entry.
    local prev_count=0
    if [[ -f "$path" ]]; then
        prev_count=$(jq -r '.consecutive_failure_count // 0' "$path" 2>/dev/null || echo 0)
        [[ "$prev_count" =~ ^[0-9]+$ ]] || prev_count=0
    fi
    local merged_count=$((prev_count + 1))
    # fleet-ops#1362: park past the failure ceiling. The quota/cap path used a
    # FLAT provider default every cycle, so a chronically walled seat re-entered
    # rotation every window forever (count climbed to 72 on devin/glm-5-2 at a
    # ~15min default). Override the window and recompute bench_until so the
    # bench branch in seat_usable holds the long wall.
    window_s=$(_failure_ceiling_wall "$merged_count" "$window_s")
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
    if _seat_dead_by_threshold "$merged_count"; then
        seat_dead=true
    fi

    local tmp="$path.bench.$$.$RANDOM.tmp"
    if ! jq -nc \
        --arg provider "$p" --arg model "$m" \
        --arg observed "$now_utc" --arg bench "$bench_until" --arg usable "$bench_until" \
        --argjson window "$window_s" --argjson merged "$merged_count" \
        --argjson http_status 429 --argjson retry_after null \
        --argjson retryable true --argjson seat_dead "$seat_dead" --argjson poison_ladder false \
        '{
          provider:$provider, model:$model,
          http_status:$http_status, retry_after:$retry_after,
          health_class:"quota_bench",
          retryable:$retryable, seat_dead:$seat_dead, poison_ladder:$poison_ladder,
          observed_at:$observed,
          source:"quota_bench",
          failure_mode:"quota_cap",
          bench_until:$bench,
          usable_at:$usable,
          bench_window_s:$window,
          consecutive_failure_count:$merged
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
    # Three ACCEPT shapes, each independently sufficient (any one of):
    #   (a) the commandcode-specific 503 "Upstream model provider is
    #       temporarily unavailable" — the live fleet-ops#652 body.
    #   (b) an HTTP 503 status with a Retry-After / "try again" hint.
    #   (c) a generic "upstream ... overloaded" (e.g. OpenAI/Anthropic
    #       502/503 wording).
    # Bare "503" or bare "temporarily unavailable" WITHOUT any of the
    # above co-occurring context is NOT a match (avoid false positives on
    # log lines that mention 503 in passing, or a flaky network call).
    if grep -qiE 'upstream[[:space:]]+(model[[:space:]]+)?provider[[:space:]]+is[[:space:]]+temporarily[[:space:]]+unavailable|upstream[[:space:]]+(is[[:space:]]+)?overloaded|overloaded[[:space:]]+upstream' <<<"$combined"; then
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
    bench_until=$(date -u -d "@$((now_s + window_s))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")

    # Merge consecutive_failure_count from any existing entry.
    local prev_count=0
    if [[ -f "$path" ]]; then
        prev_count=$(jq -r '.consecutive_failure_count // 0' "$path" 2>/dev/null || echo 0)
        [[ "$prev_count" =~ ^[0-9]+$ ]] || prev_count=0
    fi
    local merged_count=$((prev_count + 1))
    # fleet-ops#1362: park past the failure ceiling (long wall override).
    window_s=$(_failure_ceiling_wall "$merged_count" "$window_s")
    bench_until=$(date -u -d "@$((now_s + window_s))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")

    local tmp="$path.overload.$$.$RANDOM.tmp"
    if ! jq -nc \
        --arg provider "$p" --arg model "$m" \
        --arg observed "$now_utc" --arg bench "$bench_until" --arg usable "$bench_until" \
        --argjson window "$window_s" --argjson merged "$merged_count" \
        --argjson http_status 503 --argjson retry_after null \
        --argjson retryable true --argjson seat_dead false --argjson poison_ladder false \
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
          consecutive_failure_count:$merged
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
# mark_seat_hang_bench <p> <m> <text>; if the text contains an explicit
# "retry after Ns" or "resets in N" window we use it.
mark_seat_hang_bench() {
    local p="$1" m="$2" text="${3:-}"
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
    bench_until=$(date -u -d "@$(($(date -u +%s) + window_s))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")

    local tmp="$path.hang.$$.$RANDOM.tmp"
    if ! jq -nc \
        --arg provider "$p" --arg model "$m" --arg observed "$now_utc" --arg bench_until "$bench_until" \
        --argjson window_s "$window_s" --argjson merged "$merged_count" \
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
          consecutive_failure_count:$merged
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
