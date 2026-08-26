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
RATE_LIMIT_FRESH_SECS=1800  # 30 min — a rate_limited marker is only trusted while freshly observed; older than this, retry the seat
PI_BIN="${PI_BIN:-$HOME/.local/bin/pi}"
# Capacity map (P4-A). The file is the source of truth; this env var lets
# tests and fleet-ops overrides point at a different map without editing
# the install path.
SEAT_CAPS_JSON="${SEAT_CAPS_JSON:-$HOME/.local/state/pi-packet/seat-caps.json}"
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
SEAT_FREE_ORDER=""
SEAT_RAM_GB_PER_WORKER=1.5

load_seat_caps() {
    SEAT_PROVIDER_CAP=()
    SEAT_MODEL_CAP=()
    SEAT_PROVIDER_CLASS=()
    SEAT_PROVIDER_BENCH_DEFAULT=()
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

    while IFS=$'\t' read -r p cap class bench_def; do
        [[ -n "$p" ]] || continue
        SEAT_PROVIDER_CAP["$p"]="$cap"
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

# Default bench window (seconds) for a provider's quota/cap 429 when the
# error text carries no explicit reset window (fleet-ops#90). 0 = no default
# configured; the writer then fails open (no marker) and relies on the
# reactive seat-health ledger's existing quota_exhausted block.
provider_quota_bench_default() {
    local p="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    echo "${SEAT_PROVIDER_BENCH_DEFAULT[$p]:-0}"
}

# RAM governor: max concurrent workers = floor(MemAvailable_GB / RAM_PER_WORKER).
# If /proc/meminfo can't be read, returns 9999 (effectively unbounded) and logs.
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
    # 1.5 GB default. floor(MemAvailable_GB / per_worker). per_worker may be a
    # decimal (1.5), so do the division in awk — bash integer math can't, and
    # `${x%.*}` turns "1.5" into "1", inflating the cap ~1.5x.
    # Launch FLOOR, restored from the pre-2026-08-23 lane-manager design
    # (MIN_FREE_RAM_MB = 2500): reserve headroom for the rest of the host
    # FIRST, then divide what is genuinely spare. Dividing raw MemAvailable
    # let the fleet plan to consume every last byte.
    local floor_mb=${SEAT_MIN_FREE_RAM_MB:-2500}
    ram_budget=$(awk -v m="$mem_avail_kb" -v per="$SEAT_RAM_GB_PER_WORKER" -v fl="$floor_mb" 'BEGIN{ if (per+0 <= 0) per=1.5; spare=(m/1024)-fl; if (spare<0) spare=0; r=int((spare/1024)/per); if (r<1) r=1; print r }')
    (( ram_budget < 1 )) && ram_budget=1
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

# True if observed_at is within RATE_LIMIT_FRESH_SECS of now. A rate_limited
# marker older than this is treated as stale: the seat is retried (the rate
# limit may have reset), which is the P15 retry-after-window semantics.
_seat_rate_limit_fresh() {
    local obs="$1" now obs_s
    [[ -n "$obs" ]] || return 1
    now=$(date -u +%s)
    obs_s=$(date -u -d "$obs" +%s 2>/dev/null || echo 0)
    [[ "$obs_s" =~ ^[0-9]+$ ]] || return 1
    (( obs_s > 0 && now - obs_s <= RATE_LIMIT_FRESH_SECS ))
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
# session) keep working without a systemctl call. The installed wrapper
# (pi-issue-run / pi-packet-run) exports PI_SEAT_LIB_CHECK_SYSTEMD=1 by
# default; tests and callers that pre-seed the registry explicitly may
# disable it.
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
    active_since=$(systemctl --user show "$sysunit" --property=ActiveEnterTimestampMonotonic --value 2>/dev/null || echo 0)
    # ActiveEnterTimestampMonotonic is in MICROSECONDS since boot. /proc/uptime
    # is in SECONDS. Compare in seconds to avoid ms/us mixing.
    if [[ "$active_since" =~ ^[0-9]+$ ]]; then
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

# Total active workers across all seats.
count_active_total() {
    local n=0
    local f
    while IFS= read -r f; do
        n=$((n+1))
    done < <(_seat_live_registry_files)
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
    # Legacy grep path: scan pi-issue-*/pi-packet-* units in activating
    # state (cheap) and filter by SubState=auto-restart. Same as
    # _seat_list_unit but restricted to the activating state, so the
    # filter is bounded.
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
    done < <(systemctl --user list-units 'pi-issue-*.service' 'pi-packet-*.service' --state=activating --no-legend --plain 2>/dev/null \
                | awk '{print $1}' | grep -E '\.service$' || true)
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

    # Reset the per-call credential cache so a provider is resolved once
    # per selection pass (fleet-ops#36). A provider with several models
    # shares one credential; the cache stops us re-running its apiKey
    # command per model.
    _cred_cache=()

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
    if ! grep -qiE 'weekly[[:space:]]+(clinepass[[:space:]]+)?limit|daily[[:space:]]+limit|quota[[:space:]]+(exhausted|exceeded|reached)|INFERENCE_CAP_ERROR|usage[[:space:]]+limit|plan[[:space:]]+limit|out[[:space:]]+of[[:space:]]+credits|rate[[:space:]]+limit[[:space:]]+exceeded|cap[[:space:]]+(exceeded|reached)|exceeded[[:space:]]+your' <<<"$combined"; then
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
