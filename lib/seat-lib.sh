# shellcheck shell=bash
# pi-packet seat-lib.sh — shared seat enumeration and selection logic.
# Sourced by pi-packet-run and pi-issue-run. NOT executed directly.
#
# P4-A (2026-08-25): per-seat caps replace the legacy single '4 Devin workers'
# cap. Caps live in config/seat-caps.json (not hardcoded) so fleet-ops PRs can
# tune them without touching code. Selection order stays expiry-first
# (devin -> cursor -> cline -> free -> minimax-metered); caps add an UPPER
# bound per provider and per model, never a lower one.
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
PI_BIN="${PI_BIN:-$HOME/.local/bin/pi}"
# Capacity map (P4-A). The file is the source of truth; this env var lets
# tests and fleet-ops overrides point at a different map without editing
# the install path.
SEAT_CAPS_JSON="${SEAT_CAPS_JSON:-$HOME/.local/state/pi-packet/seat-caps.json}"
HEAVY_PKT_BYTES="${PI_PACKET_HEAVY_BYTES:-8192}"

mkdir -p "$ATTEMPTS_DIR" "$ACTIVE_SEATS_DIR"

seat_log() {
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_FILE"
}

now_s() { date -u +%s; }

# --- capacity map (P4-A) ----------------------------------------------------
# Read once per shell. Returns 0 on success, 1 if the map is missing/unreadable.
# Caller is expected to fall back to "no caps" behaviour (allow everything)
# rather than fail the spawn, because missing caps is a CONFIG problem, not
# a seat problem — a broken config must not brick the whole ladder.
_seat_caps_loaded=0
declare -A SEAT_PROVIDER_CAP=()
declare -A SEAT_MODEL_CAP=()
declare -A SEAT_PROVIDER_CLASS=()
declare -A SEAT_PROVIDER_HAS_MODELS=()
SEAT_FREE_ORDER=""
SEAT_RAM_GB_PER_WORKER=1.5

load_seat_caps() {
    SEAT_PROVIDER_CAP=()
    SEAT_MODEL_CAP=()
    SEAT_PROVIDER_CLASS=()
    SEAT_PROVIDER_HAS_MODELS=()
    SEAT_FREE_ORDER=""
    SEAT_RAM_GB_PER_WORKER=1.5

    [[ -f "$SEAT_CAPS_JSON" ]] || { seat_log "seat-caps: NO CAPS FILE at $SEAT_CAPS_JSON — falling back to no-cap behaviour"; return 1; }
    if ! jq -e . "$SEAT_CAPS_JSON" >/dev/null 2>&1; then
        seat_log "seat-caps: $SEAT_CAPS_JSON unparseable — falling back to no-cap behaviour"
        return 1
    fi

    local ram
    ram=$(jq -r '.ram_gb_per_worker // 1.5' "$SEAT_CAPS_JSON")
    [[ "$ram" =~ ^[0-9]+(\.[0-9]+)?$ ]] && SEAT_RAM_GB_PER_WORKER="$ram"

    while IFS=$'\t' read -r p cap class; do
        [[ -n "$p" ]] || continue
        SEAT_PROVIDER_CAP["$p"]="$cap"
        SEAT_PROVIDER_CLASS["$p"]="$class"
    # A provider may be a bare number (shorthand for cap=N, class=free, no
    # models — e.g. "devin": 0). Indexing .value.cap on a number crashes jq
    # and, with `2>/dev/null || true`, silently empties the whole cap map —
    # which then makes total_seat_cap() return 0 and the intake ceiling fall
    # back to the (inflated) RAM governor. Normalise by type first.
    done < <(jq -r '.providers | to_entries[] | .key as $k | .value as $v | [$k, (if ($v|type)=="number" then $v else ($v.cap // 0) end), (if ($v|type)=="number" then "free" else ($v.class // "free") end)] | @tsv' "$SEAT_CAPS_JSON" 2>/dev/null || true)

    while IFS=$'\t' read -r p m cap; do
        [[ -n "$p" && -n "$m" ]] || continue
        SEAT_MODEL_CAP["$p/$m"]="$cap"
    # Same bare-number guard as the providers loop: .value.models on a bare
    # number crashes jq before `// {}` can rescue it, emptying all model caps.
    done < <(jq -r '.providers | to_entries[] | .key as $p | .value as $v | (if ($v|type)=="object" then ($v.models // {}) else {} end) | to_entries[] | [$p, .key, (.value // 0)] | @tsv' "$SEAT_CAPS_JSON" 2>/dev/null || true)

    # Record which providers declare a per-model allowlist. A provider with a
    # cap but NO `models` key allows ALL its models (the cap is the only gate);
    # the per-model allowlist is OPTIONAL granularity. This generalizes the old
    # hardcoded zenmux exemption (auditor 2026-08-25: devin/hetzner/openrouter
    # had no `models` key and were being fully skipped, bricking the fleet).
    while IFS=$'\t' read -r p; do
        [[ -n "$p" ]] && SEAT_PROVIDER_HAS_MODELS["$p"]=1
    done < <(jq -r '.providers | to_entries[] | .key as $p | .value as $v | select(($v|type)=="object" and ($v.models // {}) | length > 0) | $p' "$SEAT_CAPS_JSON" 2>/dev/null || true)

    SEAT_FREE_ORDER=$(jq -r '.free_providers_in_order // [] | join(" ")' "$SEAT_CAPS_JSON" 2>/dev/null || true)

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
    local p="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    echo "${SEAT_PROVIDER_CLASS[$p]:-free}"
}

# RAM governor: max concurrent workers = floor(MemAvailable_GB / RAM_PER_WORKER).
# If /proc/meminfo can't be read, returns 9999 (effectively unbounded) and logs.
ram_governor_cap() {
    local mem_avail_kb ram_budget
    mem_avail_kb=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)
    if (( mem_avail_kb <= 0 )); then
        seat_log "ram_governor: /proc/meminfo unavailable — returning 9999 (unbounded)"
        echo 9999
        return
    fi
    # 1.5 GB default. floor(MemAvailable_GB / per_worker). per_worker may be a
    # decimal (1.5), so do the division in awk — bash integer math can't, and
    # `${x%.*}` turns "1.5" into "1", inflating the cap ~1.5x.
    ram_budget=$(awk -v m="$mem_avail_kb" -v per="$SEAT_RAM_GB_PER_WORKER" 'BEGIN{ if (per+0 <= 0) per=1.5; r=int((m/1024/1024)/per); if (r<1) r=1; print r }')
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
#   - contextWindow >= 200000
#   - the provider is one of the known flagship lanes (devin, opencode-anthropic)
#     whose cheapest seat is already a real coder
#
# cursor is NOT in the capable whitelist (2026-08-25): cursor flakes on long
# jobs (spawnSync ETIMEDOUT). It still works fine for short probes, so
# heavy-task routing skips cursor — devin/cline carry the heavy load and
# cursor only fills in when the task is light and the higher-priority seats
# are full. cursor's only heavy-capable model (cursor-grok-4.6-high) remains
# eligible through the contextWindow branch.
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
                or ((.contextWindow // 0) >= 200000)
                or ($p | IN("devin","opencode-anthropic")) )
           then "1" else "0" end)
        ]
      ),
      (
        (.value.modelOverrides // {}) | to_entries[] |
        [ $p, .key, "0",
          (if ( ((.value.reasoning // false) == true)
                or ((.value.contextWindow // 0) >= 200000)
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
    now=$(date -u +%s)
    obs_s=$(date -u -d "$obs" +%s 2>/dev/null || echo 0)
    [[ "$obs_s" =~ ^[0-9]+$ ]] || return 1
    (( obs_s > 0 && now - obs_s <= STALE_SECS ))
}

# True if the given ISO timestamp is strictly in the future relative to now.
_seat_in_future() {
    local ts="$1" now ts_s
    [[ -n "$ts" ]] || return 1
    now=$(date -u +%s)
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
#   - usable_at non-null and in the future        -> unusable (honour retry-after)
#   - otherwise                                   -> usable.
seat_usable() {
    local p="$1" m="$2" f hc dead observed usable_at
    f=$(seat_ledger_path "$p" "$m")
    if [[ ! -f "$f" ]]; then
        seat_log "seat $p/$m: NO HEALTH DATA (no ledger file) — assuming usable"
        return 0
    fi
    read -r hc dead observed usable_at < <(
        jq -r '[(.health_class//""),(.seat_dead|tostring),(.observed_at//""),(.usable_at//"")] | @tsv' "$f" 2>/dev/null || true
    )
    if [[ -z "$hc" ]]; then
        seat_log "seat $p/$m: NO HEALTH DATA (ledger unparseable) — assuming usable"
        return 0
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
    if [[ -n "$usable_at" ]] && _seat_in_future "$usable_at"; then
        seat_log "seat $p/$m: UNUSABLE (backoff until $usable_at, class=$hc)"
        return 1
    fi
    return 0
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
#
# Note on iteration: `for u in $(list-units ...)` word-splits the multi-word
# output of each line (e.g. "unit.service loaded active running /bin/sh ..."),
# so only the first unit in each line is seen and the rest are silently
# dropped. We use `while IFS= read -r line` and parse the unit name from the
# first token. A line that doesn't start with a unit pattern is skipped.
_seat_list_unit() {
    # Echo the unit names (first whitespace-delimited token per line) of
    # active or activating pi-* worker units. Skips lines that don't look
    # like a unit.
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # First whitespace-delimited token.
        local u="${line%% *}"
        # Only accept unit names (must end with .service).
        [[ "$u" == *.service ]] || continue
        echo "$u"
    done < <(systemctl --user list-units 'pi-issue-*.service' 'pi-packet-*.service' --state=active,activating --no-legend --plain 2>/dev/null || true)
}

count_active_on_seat() {
    local prov="$1" mdl="$2"
    local n=0
    # State-dir based (new path)
    local f fp fm
    for f in "$ACTIVE_SEATS_DIR"/pi-*.json; do
        [[ -f "$f" ]] || continue
        read -r fp fm < <(jq -r '[.provider // "", .model // ""] | @tsv' "$f" 2>/dev/null) || continue
        [[ "$fp" == "$prov" && "$fm" == "$mdl" ]] && n=$((n+1))
    done
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
    for f in "$ACTIVE_SEATS_DIR"/pi-*.json; do
        [[ -f "$f" ]] || continue
        read -r fp _ < <(jq -r '[.provider // "", .model // ""] | @tsv' "$f" 2>/dev/null) || continue
        [[ "$fp" == "$prov" ]] && n=$((n+1))
    done
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

# Total active workers across all seats.
count_active_total() {
    local n=0
    local f
    for f in "$ACTIVE_SEATS_DIR"/pi-*.json; do
        [[ -f "$f" ]] || continue
        n=$((n+1))
    done
    local u cmd
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        cmd=$(systemctl --user show "$u" --property=ExecStart --value 2>/dev/null || true)
        _parse_exec_provider_model "$cmd"
        if [[ -n "$_exec_p" && -n "$_exec_m" ]]; then
            n=$((n+1))
        fi
    done < <(_seat_list_unit)
    echo "$n"
}

# Pick a different seat than the failed one(s).
# Args: fail_provider fail_model [need_capable:1|0] [tried_seats_file]
# The tried_seats_file (optional) lists all already-tried "provider/model" pairs
# (one per line); all are excluded. If not given, only fail_provider/fail_model
# is excluded.
# Prints: "provider\tmodel" or nothing if none available.
pick_seat() {
    local fail_p="$1" fail_m="$2" need_capable="${3:-0}" tried_file="${4:-}"

    # Ensure caps are loaded (P4-A).
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi

    # Build the set of tried seats for exclusion.
    declare -A tried=()
    tried["$fail_p/$fail_m"]=1
    if [[ -n "$tried_file" && -f "$tried_file" ]]; then
        local tp tm
        while IFS=/ read -r tp tm; do
            [[ -n "$tp" ]] && tried["$tp/$tm"]=1
        done <"$tried_file"
    fi

    # Buckets for the expiry-first selection order:
    #   1) devin (subscription, prepaid allowance that expires first)
    #   2) cursor (subscription)
    #   3) cline (subscription)
    #   4) free tier (config-driven order, default ollama -> commandcode -> hetzner)
    #   5) minimax direct — METERED (per-token); tried LAST so the prepaid
    #      allowances burn down before we spend money.
    local -a devin_seats=() cursor_seats=() cline_seats=() free_seats=() metered_seats=()

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
        # P4-A: cap-map allowlist. If a model is not listed in the cap map for
        # its provider (and the provider has a cap entry), it is forbidden —
        # e.g. ollama models other than deepseek-v4-flash:0731.
        p_cap=$(provider_cap "$p")
        if [[ -z "${SEAT_PROVIDER_CAP[$p]:-}" ]]; then
            # The cap map is an ALLOWLIST. A provider with no entry is not
            # approved for the fleet. Previously these fell through and were
            # tried FIRST, so uncredentialed seats (groq, opencode, orcarouter)
            # headed the ladder and every attempt failed in ~1s.
            seat_log "seat $p/$m skipped (provider not in cap-map allowlist)"
            continue
        fi
        if (( p_cap == 0 )); then
            # Provider explicitly capped at 0 (e.g. zenmux via config, though the
            # zenmux hard-skip above already covers it; this is the catch-all).
            seat_log "seat $p/$m skipped (provider cap=0)"
            continue
        fi
        m_cap=$(model_cap "$p" "$m")
        if (( p_cap > 0 )) && [[ -n "${SEAT_PROVIDER_HAS_MODELS[$p]:-}" ]] && [[ -z "${SEAT_MODEL_CAP[$p/$m]:-}" ]]; then
            # Provider declares a per-model allowlist and this model isn't on it
            # -> standing-rule block (e.g. ollama DeepSeek-flash-only). Providers
            # with NO `models` key allow all models (cap is the only gate).
            seat_log "seat $p/$m skipped (not in cap-map allowlist for $p)"
            continue
        fi
        if (( need_capable )) && [[ "$capable" != "1" ]]; then
            seat_log "seat $p/$m skipped (not capable for heavy task)"
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
        # Bucket by CLASS from the cap map, not by provider name. The old
        # case matched literal names and dropped everything else into
        # free_seats, so class_of() was computed and discarded and any
        # credit-bearing provider that was not named "minimax" (openrouter,
        # zenmux) was spent as if it were free.
        case "$class" in
            subscription)
                case "$p" in
                    devin)  devin_seats+=("$p"$'\t'"$m") ;;
                    cursor) cursor_seats+=("$p"$'\t'"$m") ;;
                    cline)  cline_seats+=("$p"$'\t'"$m") ;;
                    *)      cline_seats+=("$p"$'\t'"$m") ;;
                esac ;;
            metered)      metered_seats+=("$p"$'\t'"$m") ;;
            *)            free_seats+=("$p"$'\t'"$m") ;;
        esac
    done < <(enumerate_seats)

    # Free-tier order: explicit from the cap map (default ollama, commandcode, hetzner).
    # Re-bucket free_seats in that order. Stable: anything not in the configured
    # order keeps its relative enumerate_seats order at the end.
    if [[ -n "$SEAT_FREE_ORDER" ]]; then
        local -a free_ordered=()
        local fprov fm
        for fprov in $SEAT_FREE_ORDER; do
            for fm in "${free_seats[@]}"; do
                if [[ "$fm" == "$fprov"* ]]; then
                    free_ordered+=("$fm")
                fi
            done
        done
        for fm in "${free_seats[@]}"; do
            local in_ordered=0
            for x in "${free_ordered[@]:-}"; do
                [[ "$x" == "$fm" ]] && in_ordered=1 && break
            done
            (( in_ordered )) || free_ordered+=("$fm")
        done
        free_seats=("${free_ordered[@]}")
    fi

    # Expiry-first: devin -> cursor -> cline -> free -> minimax (metered).
    local -n arr
    for arr in devin_seats cursor_seats cline_seats free_seats metered_seats; do
        if (( ${#arr[@]} > 0 )); then
            printf '%s\n' "${arr[0]}"
            return 0
        fi
    done
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
