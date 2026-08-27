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

MODELS_JSON="${PI_MODELS_JSON:-$HOME/.pi/agent/models.json}"
# Per-seat health ledger (authority). Written atomically by the pi
# seat-health extension (one file per provider+model). Read-only here:
# no polling, no network — file reads only.
LEDGER_DIR="${PI_SEAT_HEALTH_LEDGER_DIR:-/home/nish/workspaces/agent-state/lanes/seats}"
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
HEAVY_PKT_BYTES="${PI_PACKET_HEAVY_BYTES:-8192}"

mkdir -p "$ATTEMPTS_DIR" "$ACTIVE_SEATS_DIR"

seat_log() {
    local line ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf -v line '[%s] %s\n' "$ts" "$*"
    # Durable audit trail in watch.log. Also emit to stderr so systemd's
    # journal / `systemctl status` shows the reason (fleet-ops#342).
    printf '%s' "$line" >>"$LOG_FILE"
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

# --- capacity map (P4-A) ----------------------------------------------------
# Read once per shell. Returns 0 on success, 1 if the map is missing/unreadable.
# Caller is expected to fall back to "no caps" behaviour (allow everything)
# rather than fail the spawn, because missing caps is a CONFIG problem, not
# a seat problem — a broken config must not brick the whole ladder.
_seat_caps_loaded=0
declare -A SEAT_PROVIDER_CAP=()
declare -A SEAT_MODEL_CAP=()
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
SEAT_FREE_ORDER=""
SEAT_PREPAID_ORDER=""
SEAT_VOLUME_ORDER=""
declare -A SEAT_KEYSTONE_ONLY=()
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

load_seat_caps() {
    SEAT_PROVIDER_CAP=()
    SEAT_MODEL_CAP=()
    SEAT_PROVIDER_CLASS=()
    SEAT_PROVIDER_BENCH_DEFAULT=()
    SEAT_PROVIDER_OVERLOAD_BENCH_DEFAULT=()
    SEAT_PROVIDER_QUOTA_WINDOW=()
    SEAT_PROVIDER_WEEKLY_BUDGET=()
    SEAT_FREE_ORDER=""
    SEAT_PREPAID_ORDER=""
    SEAT_VOLUME_ORDER=""
    SEAT_KEYSTONE_ONLY=()
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

    [[ -f "$SEAT_CAPS_JSON" ]] || { seat_log "seat-caps: NO CAPS FILE at $SEAT_CAPS_JSON — falling back to no-cap behaviour"; return 1; }
    if ! jq -e . "$SEAT_CAPS_JSON" >/dev/null 2>&1; then
        seat_log "seat-caps: $SEAT_CAPS_JSON unparseable — falling back to no-cap behaviour"
        return 1
    fi

    local ram ores
    ram=$(jq -r '.ram_gb_per_worker // 1.5' "$SEAT_CAPS_JSON")
    [[ "$ram" =~ ^[0-9]+(\.[0-9]+)?$ ]] && SEAT_RAM_GB_PER_WORKER="$ram"
    ores=$(jq -r '.org_reserve // 2' "$SEAT_CAPS_JSON")
    [[ "$ores" =~ ^[0-9]+$ ]] && SEAT_ORG_RESERVE="$ores"

    # fleet-ops#602: the read loops below must use LOCAL variables. bash's
    # `local` is DYNAMIC scoping, so a bare `p`/`m` here would write into the
    # caller's variable of the same name — a lazy-loading model_cap()/class_of()
    # would have its own $p/$m clobbered to the last jq line before its lookup
    # ran, returning 0 for every unlisted-model seat and NO-USABLE-SEAT for
    # the whole free role (pi-audit@ free-glm-5-3 unit-failure loop 2026-08-27).
    local p m cap class bench_def window budget ko ov_model ov_ex ov_usd cb
    while IFS=$'\t' read -r p cap class bench_def; do
        [[ -n "$p" ]] || continue
        SEAT_PROVIDER_CAP["$p"]="$cap"
        # subscription is the pre-#387 name for prepaid-quota.
        [[ "$class" == "subscription" ]] && class="prepaid-quota"
        SEAT_PROVIDER_CLASS["$p"]="$class"
        [[ "$bench_def" =~ ^[0-9]+$ ]] && SEAT_PROVIDER_BENCH_DEFAULT["$p"]="$bench_def"
    # A provider may be a bare number (shorthand for cap=N, class=free, no
    # models — e.g. "devin": 0). Indexing .value.cap on a number crashes jq
    # and, with `2>/dev/null || true`, silently empties the whole cap map —
    # which then makes total_seat_cap() return 0 and the intake ceiling fall
    # back to the (inflated) RAM governor. Normalise by type first.
    # quota_bench_default_s (fleet-ops#90) is optional; absent -> empty ->
    # provider_quota_bench_default returns 0 (no default, writer fails open).
    done < <(jq -r '.providers | to_entries[] | .key as $k | .value as $v | [$k, (if ($v|type)=="number" then $v else ($v.cap // 0) end), (if ($v|type)=="number" then "free" else ($v.class // "free") end), (if ($v|type)=="object" then ($v.quota_bench_default_s // "") else "" end)] | @tsv' "$SEAT_CAPS_JSON" 2>/dev/null || true)

    while IFS=$'\t' read -r p m cap; do
        [[ -n "$p" && -n "$m" ]] || continue
        SEAT_MODEL_CAP["$p/$m"]="$cap"
    # Same bare-number guard as the providers loop: .value.models on a bare
    # number crashes jq before `// {}` can rescue it, emptying all model caps.
    done < <(jq -r '.providers | to_entries[] | .key as $p | .value as $v | (if ($v|type)=="object" then ($v.models // {}) else {} end) | to_entries[] | [$p, .key, (.value // 0)] | @tsv' "$SEAT_CAPS_JSON" 2>/dev/null || true)

    SEAT_FREE_ORDER=$(jq -r '.free_providers_in_order // [] | join(" ")' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    SEAT_PREPAID_ORDER=$(jq -r '.prepaid_providers_in_order // [] | join(" ")' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    # fleet-ops#1178: cross-class volume front-of-ladder (ollama -> devin ->
    # commandcode -> cline FIRST). Empty means legacy free-then-prepaid behaviour.
    SEAT_VOLUME_ORDER=$(jq -r '.volume_providers_in_order // [] | join(" ")' "$SEAT_CAPS_JSON" 2>/dev/null || true)

    # fleet-ops#1167: cursor (and any listed provider) is keystone/senior-review only.
    while IFS= read -r ko; do
        [[ -n "$ko" ]] || continue
        SEAT_KEYSTONE_ONLY["$ko"]=1
    done < <(jq -r '.keystone_only_providers // [] | .[]' "$SEAT_CAPS_JSON" 2>/dev/null || true)
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

    _seat_caps_loaded=1
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
    if (( sz > HEAVY_PKT_BYTES )); then
        echo "heavy"; return
    fi
    if grep -qiE '(edit|refactor|rewrite|fix|implement|modify|update|patch)[[:space:]]+.*(file|\.py|\.sh|\.ts|\.tsx|\.js|\.jsx|\.go|\.rs|\.rb|/home/|src/|lib/)' "$pkt" 2>/dev/null; then
        echo "heavy"; return
    fi
    echo "light"
}

# fleet-ops#1133: explicit difficulty marker on a packet.
# Scans the packet for a `difficulty: keystone|senior-review|heavy|light` line
# (or `keystone: true` / `senior-review: true`). First match wins. Falls
# back to task_weight() when no marker is present. Missing file -> light.
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
_provider_is_keystone_only() {
    local p="$1"
    [[ "$p" == "cursor" ]] && return 0
    [[ -n "${SEAT_KEYSTONE_ONLY[$p]:-}" ]] && return 0
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

# Seat health: read the per-seat ledger and decide if a SPECIFIC seat is usable
# right now. Returns 0 if usable, non-zero otherwise.
#
# Authority: $LEDGER_DIR/<provider>__<sanitised-model>.json, written by the pi
# seat-health extension. No polling, no network — file reads only.
#
# Decision:
#   - no file / unparseable / stale observed_at (> STALE_SECS) -> USABLE, but
#     log a loud "no health data" line (do not brick the ladder).
#   - seat_dead=true                              -> unusable (credentials_bad)
#   - health_class in {credentials_bad, quota_exhausted} -> unusable
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
#   - otherwise                                   -> usable.
seat_usable() {
    local p="$1" m="$2" f hc dead observed usable_at bench_until
    f=$(seat_ledger_path "$p" "$m")
    if [[ ! -f "$f" ]]; then
        seat_log "seat $p/$m: NO HEALTH DATA (no ledger file) — assuming usable"
        return 0
    fi
    # Unit-separator join (not TSV): bash `read` treats tab as IFS whitespace
    # and collapses consecutive tabs, which would shift bench_until left when
    # usable_at is empty (the 9d fixture and any ledger without usable_at).
    # \x1f is not whitespace, so empty fields survive. Include newline in IFS
    # so the trailing jq newline is not glued onto bench_until.
    IFS=$'\x1f'$'\n' read -r hc dead observed usable_at bench_until < <(
        jq -r '[(.health_class//""),(.seat_dead|tostring),(.observed_at//""),(.usable_at//""),(.bench_until//"")] | join("\u001f")' "$f" 2>/dev/null || true
    )
    if [[ -z "$hc" ]]; then
        seat_log "seat $p/$m: NO HEALTH DATA (ledger unparseable) — assuming usable"
        return 0
    fi
    # quota_bench BEFORE stale-observed_at: bench_until is the source of truth
    # for the advertised reset window, which can outlive STALE_SECS.
    if [[ "$hc" == "quota_bench" ]]; then
        if [[ -n "$bench_until" ]] && _seat_in_future "$bench_until"; then
            seat_log "seat $p/$m: benched until $bench_until (quota_bench)"
            return 1
        fi
        if [[ -n "$bench_until" ]]; then
            seat_log "seat $p/$m: bench expired ($bench_until passed) — assuming usable (fail-open)"
            return 0
        fi
        seat_log "seat $p/$m: UNUSABLE (quota_bench with no bench_until — defensive block)"
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
            seat_log "seat $p/$m: benched until $bench_until (overload_bench)"
            return 1
        fi
        if [[ -n "$bench_until" ]]; then
            seat_log "seat $p/$m: bench expired ($bench_until passed) — assuming usable (fail-open)"
            return 0
        fi
        seat_log "seat $p/$m: UNUSABLE (overload_bench with no bench_until — defensive block)"
        return 1
    fi
    # Auditor 2026-08-27: hang_bench (model accepted request but never
    # finalised before TimeoutStartSec / PI_HANG_TIMEOUT_S). Same fail-open
    # semantics as overload_bench; a 180s default is short so the ladder
    # is not starved if the hang self-clears.
    if [[ "$hc" == "hang_bench" ]]; then
        if [[ -n "$bench_until" ]] && _seat_in_future "$bench_until"; then
            seat_log "seat $p/$m: benched until $bench_until (hang_bench)"
            return 1
        fi
        if [[ -n "$bench_until" ]]; then
            seat_log "seat $p/$m: hang bench expired ($bench_until passed) — assuming usable (fail-open)"
            return 0
        fi
        seat_log "seat $p/$m: UNUSABLE (hang_bench with no bench_until — defensive block)"
        return 1
    fi
    if ! _seat_observed_fresh "$observed"; then
        seat_log "seat $p/$m: NO HEALTH DATA (observed_at ${observed:-<empty>} stale >${STALE_SECS}s) — assuming usable"
        return 0
    fi
    if [[ "$dead" == "true" ]]; then
        seat_log "seat $p/$m: UNUSABLE (seat_dead=true, class=$hc)"
        return 1
    fi
    if [[ "$hc" == "quota_exhausted" || "$hc" == "credentials_bad" ]]; then
        seat_log "seat $p/$m: UNUSABLE (health_class=$hc)"
        return 1
    fi
    # rate_limited: trust only while the marker is fresh (<30 min) AND usable_at
    # is still in the future. A fresh marker with usable_at in the past means the
    # window already reset -> usable. A stale marker (>30 min) means the rate
    # limit may have reset -> retry (usable).
    if [[ "$hc" == "rate_limited" ]]; then
        if _seat_rate_limit_fresh "$observed" && [[ -n "$usable_at" ]] && _seat_in_future "$usable_at"; then
            seat_log "seat $p/$m: UNUSABLE (rate_limited until $usable_at, observed ${observed:-<empty>})"
            return 1
        fi
        seat_log "seat $p/$m: retrying after rate_limited (observed ${observed:-<empty>} aged past ${RATE_LIMIT_FRESH_SECS}s or usable_at passed) — assuming usable"
        return 0
    fi
    if [[ -n "$usable_at" ]] && _seat_in_future "$usable_at"; then
        seat_log "seat $p/$m: UNUSABLE (backoff until $usable_at, class=$hc)"
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
    active_since=$(systemctl --user show "$sysunit" --property=ExecMainStartTimestampMonotonic --value 2>/dev/null || echo 0)
    # Both timestamps are in MICROSECONDS since boot; /proc/uptime is in
    # SECONDS. Compare in seconds to avoid ms/us mixing.
    if [[ "$active_since" =~ ^[0-9]+$ ]] && (( active_since > 0 )); then
        now_s=$(awk '{print int($1)}' /proc/uptime)
        age_s=$(( now_s - active_since / 1000000 ))
        if (( age_s > PI_SEAT_ACTIVATING_MAX_S )); then
            seat_log "seat registry: unit $sysunit stuck activating ${age_s}s (> ${PI_SEAT_ACTIVATING_MAX_S}s) — wedged pi, reaping seat"
            return 1
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

count_active_on_seat() {
    local prov="$1" mdl="$2"
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

# Pick a different seat than the failed one(s).
# Args: fail_provider fail_model [need_capable:1|0] [tried_seats_file] [difficulty]
# The tried_seats_file (optional) lists all already-tried "provider/model" pairs
# (one per line); all are excluded. If not given, only fail_provider/fail_model
# is excluded.
# difficulty (fleet-ops#1133): keystone forces need_capable=1, walks strongest
# class first (prepaid -> metered -> free), and returns empty after 2 strikes
# so the caller escalates to the senior conference instead of another cheap
# retry. heavy/light (default) keep the #387/#1178 walk (volume first).
# Prints: "provider\tmodel" or nothing if none available.
pick_seat() {
    local fail_p="$1" fail_m="$2" need_capable="${3:-0}" tried_file="${4:-}" difficulty="${5:-light}"

    # Ensure caps are loaded (P4-A).
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    if (( ! _quality_routing_loaded )); then load_quality_routing || true; fi

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

    # fleet-ops#1133: two strikes on a keystone packet end cheap retries.
    # tried_count is lines already recorded by the wrapper BEFORE this pick,
    # so 0 = first attempt, 1 = one retry left, >=2 = escalate.
    if _is_keystone_class "$difficulty" && (( tried_count >= 2 )); then
        seat_log "pick_seat: KEYSTONE ESCALATION — ${tried_count} strikes; refusing further cheap retries (senior conference via OnFailure)"
        keystone_record_event escalated
        return 1
    fi

    # Buckets (fleet-ops#387):
    #   1) free lanes first (true free — never a prepaid seat mislabeled free)
    #   2) prepaid-quota, alternating across live prepaid so one weekly-quota
    #      seat cannot be drained dry while others sit idle
    #   3) metered last (per-token; spend after prepaid/free)
    local -a free_seats=() prepaid_seats=() metered_seats=()

    local p m free capable p_cap m_cap p_active m_active class
    # `free` is emitted by enumerate_seats for parity with the legacy contract;
    # the new bucketing uses class_of() instead. Unused but stable in the pipe.
    # shellcheck disable=SC2034
    while IFS=$'\t' read -r p m free capable; do
        [[ -n "$p" ]] || continue
        # must differ from all tried seats
        [[ -n "${tried[$p/$m]:-}" ]] && continue
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
            seat_log "seat $p/$m skipped (not capable for heavy task)"
            continue
        fi
        if (( need_capable )) && [[ -n "${QUALITY_HEAVY_BAN[$p/$m]:-}" ]]; then
            seat_log "seat $p/$m skipped (quality-routing: over threshold, light work only)"
            continue
        fi
        if ! seat_usable "$p" "$m"; then
            # seat_usable already logged the UNUSABLE reason from the ledger.
            continue
        fi
        # P4-A: per-provider and per-model caps.
        p_active=$(count_active_on_provider "$p")
        if (( p_cap > 0 )) && (( p_active >= p_cap )); then
            seat_log "seat $p/$m skipped (provider $p cap=$p_cap reached: $p_active active)"
            continue
        fi
        m_active=$(count_active_on_seat "$p" "$m")
        if (( m_cap > 0 )) && (( m_active >= m_cap )); then
            seat_log "seat $p/$m skipped (model $p/$m cap=$m_cap reached: $m_active active)"
            continue
        fi

        class=$(class_of "$p")
        # Bucket by CLASS from the cap map, not by provider name. prepaid-quota
        # includes the old "subscription" alias (normalized in class_of).
        case "$class" in
            prepaid-quota) prepaid_seats+=("$p"$'\t'"$m") ;;
            metered)       metered_seats+=("$p"$'\t'"$m") ;;
            *)             free_seats+=("$p"$'\t'"$m") ;;
        esac
    done < <(enumerate_seats)

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
    # Skip volume front-of-ladder (#1178) on keystone so reliability beats
    # cheap. Unmarked packets keep volume-first, then leftover free,
    # leftover prepaid (alternate), then metered.
    local -a volume_seats=() leftover_free=() leftover_prepaid=()
    if ! _is_keystone_class "$difficulty" && [[ -n "$SEAT_VOLUME_ORDER" ]]; then
        declare -A _vol_seen=()
        local _vp _fm
        for _vp in $SEAT_VOLUME_ORDER; do
            _vol_seen["$_vp"]=1
        done
        for _fm in "${free_seats[@]:-}" "${prepaid_seats[@]:-}"; do
            [[ -n "$_fm" ]] || continue
            p="${_fm%%$'\t'*}"
            if [[ -n "${_vol_seen[$p]:-}" ]]; then
                volume_seats+=("$_fm")
            fi
        done
        if (( ${#volume_seats[@]} > 0 )); then
            mapfile -t volume_seats < <(_order_seats_by "$SEAT_VOLUME_ORDER" "${volume_seats[@]}")
        fi
        for _fm in "${free_seats[@]:-}"; do
            [[ -n "$_fm" ]] || continue
            p="${_fm%%$'\t'*}"
            [[ -n "${_vol_seen[$p]:-}" ]] && continue
            leftover_free+=("$_fm")
        done
        for _fm in "${prepaid_seats[@]:-}"; do
            [[ -n "$_fm" ]] || continue
            p="${_fm%%$'\t'*}"
            [[ -n "${_vol_seen[$p]:-}" ]] && continue
            leftover_prepaid+=("$_fm")
        done
        if (( ${#leftover_free[@]} > 0 )); then
            free_seats=("${leftover_free[@]}")
        else
            free_seats=()
        fi
        if (( ${#leftover_prepaid[@]} > 0 )); then
            prepaid_seats=("${leftover_prepaid[@]}")
        else
            prepaid_seats=()
        fi
    fi

    local chosen="" chosen_p=""
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
    elif (( ${#volume_seats[@]} > 0 )); then
        chosen="${volume_seats[0]}"
        chosen_p="${chosen%%$'\t'*}"
        # Prepaid members of the volume set still burn weekly pacing.
        if [[ "$(class_of "$chosen_p")" == "prepaid-quota" ]]; then
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

    # P15: loud stall beats a garbage seat. Every allowlisted seat was dead or
    # capped — return 1 (caller must not spawn anything) and say so, rather
    # than falling back to a non-allowlisted model.
    seat_log "pick_seat: NO USABLE SEAT — every allowlisted seat is dead/capped/rate-limited. Refusing to route outside the cap map."
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

mark_seat_spawn_fail() {
    local p="$1" m="$2" reason="${3:-spawn_etimeout}"
    local path
    path=$(seat_ledger_path "$p" "$m")
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true
    local tmp="$path.spawn.$$.$RANDOM.tmp"
    local now_utc
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local backoff="$SPAWN_FAIL_BACKOFF_S"
    # Compute usable_at = now + backoff (ISO 8601, bash portable: -d @ + offsets).
    local usable_at
    usable_at=$(date -u -d "@$(($(date -u +%s) + backoff))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now_utc")

    # Merge consecutive_failure_count from any existing entry (so a real
    # session-time 429 resetting later doesn't briefly flip us back to 0).
    local prev_count=0
    if [[ -f "$path" ]]; then
        prev_count=$(jq -r '.consecutive_failure_count // 0' "$path" 2>/dev/null || echo 0)
        [[ "$prev_count" =~ ^[0-9]+$ ]] || prev_count=0
    fi
    local merged_count=$((prev_count + 1))

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
        return 0
    fi
    seat_log "spawn-fail: rename FAILED for $p/$m at $path (reason=$reason)"
    rm -f "$tmp" 2>/dev/null || true
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
    if ! grep -qiE 'weekly[[:space:]]+(clinepass[[:space:]]+)?limit|daily[[:space:]]+limit|quota[[:space:]]+(exhausted|exceeded|reached)|INFERENCE_CAP_ERROR|usage[[:space:]]+limit|plan[[:space:]]+limit|out[[:space:]]+of[[:space:]]+credits|message[[:space:]]+rate[[:space:]]+limit|rate[[:space:]]+limit[[:space:]]+(exceeded|reached)|cap[[:space:]]+(exceeded|reached)|exceeded[[:space:]]+your' <<<"$combined"; then
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
    if grep -qiE 'weekly[[:space:]]+(clinepass[[:space:]]+)?limit|daily[[:space:]]+limit|INFERENCE_CAP_ERROR' <<<"$combined"; then
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

    local tmp="$path.bench.$$.$RANDOM.tmp"
    if ! jq -nc \
        --arg provider "$p" --arg model "$m" \
        --arg observed "$now_utc" --arg bench "$bench_until" --arg usable "$bench_until" \
        --argjson window "$window_s" --argjson merged "$merged_count" \
        --argjson http_status 429 --argjson retry_after null \
        --argjson retryable true --argjson seat_dead false --argjson poison_ladder false \
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
        seat_log "quota-bench: benched $p/$m until $bench_until (window=${window_s}s, count=$merged_count)"
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
        return 0
    fi
    seat_log "hang-bench: rename FAILED for $p/$m at $path"
    rm -f "$tmp" 2>/dev/null || true
    return 1
}
