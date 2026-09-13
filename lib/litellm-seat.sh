# shellcheck shell=bash
# litellm-seat.sh — LiteLLM group routing + leftover helpers (fleet-ops#4263 P3b).
# Sourced by worker wrappers. NOT executed directly.
#
# Routing lives in the LiteLLM proxy (fallbacks, cooldown, budgets).
# Callers pick a group and run: pi --print --provider litellm --model <group>
# Groups: worker-cheap, worker-capable, worker-private, senior, judge.
#
# Keep-list from the P0 design: packet/privacy helpers, worker_memory/env
# drop-ins from seat-caps.json, active-seat registry, verdict-log stubs. The
# retired seat picker and its RAM-charge governor are deleted (fleet-ops#4263):
# admission is systemd MemoryMax/oomd plus the proxy's group routing.

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export HOME="${HOME:-/home/nish}"

STATE_DIR="${PI_PACKET_STATE:-$HOME/.local/state/pi-packet}"
ATTEMPTS_DIR="$STATE_DIR/attempts"
ACTIVE_SEATS_DIR="$STATE_DIR/active-seats"
LOG_FILE="${SEAT_LOG_FILE:-$STATE_DIR/watch.log}"
PI_ISSUES_DIR="${PI_ISSUES_DIR:-$HOME/.local/state/pi-issues}"
PI_BIN="${PI_BIN:-$HOME/.local/bin/pi}"
SEAT_CAPS_JSON="${SEAT_CAPS_JSON:-$HOME/.local/state/pi-packet/seat-caps.json}"
LEDGER_DIR="${PI_SEAT_HEALTH_LEDGER_DIR:-$STATE_DIR/seat-health}"
HEAVY_PKT_BYTES="${PI_PACKET_HEAVY_BYTES:-8192}"
LITELLM_HEALTH_URL="${LITELLM_HEALTH_URL:-http://127.0.0.1:4000/health/readiness}"

mkdir -p "$ATTEMPTS_DIR" "$ACTIVE_SEATS_DIR"

_SEAT_SYSTEMD_CAT="$(command -v systemd-cat 2>/dev/null || true)"

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
        printf '%s' "$line" >>"$LOG_FILE"
    elif [[ -n "$_SEAT_SYSTEMD_CAT" ]]; then
        printf '%s' "$line" | "$_SEAT_SYSTEMD_CAT" --identifier=pi-packet --priority=info 2>/dev/null || \
            printf '%s' "$line" >>"$LOG_FILE"
    else
        printf '%s' "$line" >>"$LOG_FILE"
    fi
    printf '%s' "$line" >&2
}

# Args: $1 = LiteLLM model group. Prints provider<TAB>model.
litellm_seat() {
    local group="${1:-worker-cheap}"
    printf 'litellm\t%s\n' "$group"
}

# Public vs private packet -> group. Private repos use the private key pool.
litellm_group_for_privacy() {
    local privacy="${1:-public}"
    if [[ "$privacy" == "private" ]]; then
        echo "worker-private"
    else
        echo "worker-cheap"
    fi
}

# True when the proxy answers /health/readiness with status=healthy.
# Fail-open for tests (no proxy): return 0 unless LITELLM_REQUIRE_LIVE=1.
litellm_ready() {
    local body status
    body=$(curl -fsS -m 3 "$LITELLM_HEALTH_URL" 2>/dev/null || true)
    status=$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null || true)
    if [[ "$status" == "healthy" ]]; then
        return 0
    fi
    if [[ "${LITELLM_REQUIRE_LIVE:-0}" == "1" ]]; then
        return 1
    fi
    # Tests and hosts without a live proxy: fail-open so intake does not freeze.
    if [[ -z "$body" && "${GITHUB_ACTIONS:-}" == "true" ]]; then
        return 0
    fi
    [[ -z "$body" ]] && return 1
    return 1
}

# Headroom for intake claim bounding. Prints an integer or empty (fail-open).
# The proxy owns routing; the count is the declared cap sum minus live worker
# units — a worker COUNT, not a RAM charge (fleet-ops#4263).
litellm_headroom() {
    if litellm_ready; then
        local cap active
        cap=$(seat_max_concurrent)
        active=$(count_active_workers)
        awk -v c="$cap" -v a="$active" 'BEGIN{ s=c-a; if(s<0)s=0; print int(s) }'
        return 0
    fi
    echo ""
    return 1
}

find_senior_seat() {
    if litellm_ready || [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        printf 'litellm\tsenior\n'
        return 0
    fi
    return 1
}

senior_seat_available() {
    # fleet-ops#3709: a senior seat is available when an entry of
    # senior_seats_in_order is not benched in the seat-health ledger. The
    # real enumeration lived in the routing library deleted by #4263; what
    # replaced it (`litellm_ready || GITHUB_ACTIONS == true`) is always true
    # under CI, so the reviewer-round fallback gate could never fire there
    # and tests/fleet-review-arm-check.test.sh case 1 failed on main.
    local seats seat p m
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    [[ -f "$SEAT_CAPS_JSON" ]] || { litellm_ready; return $?; }
    seats=$(jq -r '.senior_seats_in_order[]? // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    # No senior list configured: fall back to proxy reachability.
    [[ -n "$seats" ]] || { litellm_ready; return $?; }
    while IFS= read -r seat; do
        [[ -n "$seat" ]] || continue
        p="${seat%%/*}"
        m="${seat#*/}"
        [[ -n "$p" && -n "$m" && "$p" != "$seat" ]] || continue
        if seat_usable "$p" "$m"; then
            return 0
        fi
    done <<<"$seats"
    return 1
}

# --- repo privacy (free-tier privacy line, vault 2026-08-18) ----------------
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

repo_privacy() {
    local repo="$1" v
    if (( ! _repo_privacy_loaded )); then load_repo_privacy || true; fi
    v="${REPO_PRIVACY_MAP[$repo]:-}"
    [[ "$v" == "public" || "$v" == "private" ]] || v="$REPO_PRIVACY_DEFAULT"
    echo "$v"
}

packet_repo() {
    local pkt="$1" line repo
    [[ -f "$pkt" ]] || return 0
    line=$(grep -m1 -E '^TARGET(:| REPO:)' "$pkt" 2>/dev/null || true)
    [[ -n "$line" ]] || return 0
    repo=${line##*Nishfleet/}
    repo=${repo%%[[:space:],]*}
    printf '%s' "$repo"
}

# --- repo product flag (intake-repos.json product flag, fleet-ops#3724) -----
# Resolves next to the running code so a stale sibling checkout cannot shadow
# the deployed config (fleet-ops#4450). repo_is_product is still called by
# lib/work-supply.sh; the picker is gone but this utility survived the P3b cut.
INTAKE_REPOS_JSON="${FLEET_INTAKE_REPOS_JSON:-}"
declare -A REPO_PRODUCT_MAP=()
_intake_repos_loaded=0
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

# --- spawn helpers from seat-caps.json (not routing) --------------------------
# Per-worker RAM is bounded by the per-instance systemd MemoryMax drop-in
# (worker_memory_for_* below) and oomd — there is no hand-set charge.
_seat_caps_loaded=0
SEAT_ORG_RESERVE=2
SEAT_SPAWN_STAGGER_S=0

load_seat_caps() {
    _seat_caps_loaded=1
    SEAT_ORG_RESERVE=2
    SEAT_SPAWN_STAGGER_S=0
    [[ -f "$SEAT_CAPS_JSON" ]] || return 1
    if ! jq -e . "$SEAT_CAPS_JSON" >/dev/null 2>&1; then
        return 1
    fi
    local ores stagger
    ores=$(jq -r '.org_reserve // 2' "$SEAT_CAPS_JSON")
    [[ "$ores" =~ ^[0-9]+$ ]] && SEAT_ORG_RESERVE="$ores"
    stagger=$(jq -r '.spawn_stagger_s // 0' "$SEAT_CAPS_JSON")
    [[ "$stagger" =~ ^[0-9]+$ ]] && SEAT_SPAWN_STAGGER_S="$stagger"
    return 0
}

worker_memory_for_repo() {
    local repo="$1" max high
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    [[ -f "$SEAT_CAPS_JSON" ]] || return 0
    max=$(jq -r --arg r "$repo" '.worker_memory[$r].MemoryMax // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    high=$(jq -r --arg r "$repo" '.worker_memory[$r].MemoryHigh // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
    [[ -n "$max" || -n "$high" ]] || return 0
    printf '%s\t%s\n' "$max" "$high"
}

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

worker_env_for_repo() {
    local repo="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    [[ -f "$SEAT_CAPS_JSON" ]] || return 0
    jq -r --arg r "$repo" '.worker_env[$r] // empty | to_entries[] | "\(.key)=\(.value)"' "$SEAT_CAPS_JSON" 2>/dev/null || true
}

# Per-model wiring cap (fleet-ops#6074). Deleted with the routing library in
# fleet-ops#4263 while eight callers survived (bin/pi-audit-run x3,
# bin/fleet-gap-closure-conference x5). Every one of them guards with
# `|| echo 0`, so an undefined model_cap read as "cap 0 / not wired" and the
# audit panel silently fell back to its hardcoded unwired ladder slug
# (zenmux/z-ai/glm-5.3-free) on every termination conference.
# A provider at cap 0 unwires all of its models (that is how a seat is
# retired, e.g. devin/swe-1-7); a provider without a models map answers with
# its own cap.
model_cap() {
    local p="${1:-}" m="${2:-}" cap
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    [[ -f "$SEAT_CAPS_JSON" ]] || { echo 0; return; }
    cap=$(jq -r --arg p "$p" --arg m "$m" '
        .providers[$p] as $prov
        | if $prov == null then 0
          elif (($prov.cap // 0) == 0) then 0
          elif (($prov.models | type) == "object") then ($prov.models[$m].cap // 0)
          else ($prov.cap // 0) end' "$SEAT_CAPS_JSON" 2>/dev/null || echo 0)
    [[ "$cap" =~ ^[0-9]+$ ]] || cap=0
    echo "$cap"
}

# Seat class ("free", "prepaid-quota", ...), model first then provider.
# Same deletion as model_cap: bin/fleet-gap-closure-conference uses it to
# prefer the free lane for the glm-5-3 role.
model_class_of() {
    local p="${1:-}" m="${2:-}"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    [[ -f "$SEAT_CAPS_JSON" ]] || return 0
    jq -r --arg p "$p" --arg m "$m" '
        .providers[$p] as $prov
        | if $prov == null then ""
          else (($prov.models[$m].class // $prov.class) // "") end' \
        "$SEAT_CAPS_JSON" 2>/dev/null || true
}

# Seat inventory source. Same default as the deleted routing library.
MODELS_JSON="${PI_MODELS_JSON:-$HOME/.pi/agent/models.json}"

# Wired-seat inventory: provider<TAB>model<TAB>zero_cost<TAB>capable.
# Restored verbatim-equivalent from the pre-#4263 routing library @5411da097~1 (fleet-ops#6074);
# deleted in fleet-ops#5993/#4263 while bin/pi-audit-run (x2) and
# bin/fleet-gap-closure-conference (x2) still read from it, so both audit
# panels enumerated nothing and fell back to their hardcoded ladder slugs.
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

# Provider seat class. The deleted original read a SEAT_PROVIDER_CLASS map
# that load_seat_caps no longer builds; this reads the same field straight
# from seat-caps.json with the same default and the same subscription alias.
class_of() {
    local p="${1:-}" c
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    c=free
    if [[ -f "$SEAT_CAPS_JSON" ]]; then
        c=$(jq -r --arg p "$p" '.providers[$p].class // "free"' "$SEAT_CAPS_JSON" 2>/dev/null || echo free)
    fi
    [[ -n "$c" && "$c" != "null" ]] || c=free
    [[ "$c" == "subscription" ]] && c="prepaid-quota"
    echo "$c"
}

# Fleet concurrency bound: sum of the declared provider caps in
# seat-caps.json. RAM safety is per-unit MemoryMax + oomd, not a charge.
seat_max_concurrent() {
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    local sum=0
    if [[ -f "$SEAT_CAPS_JSON" ]]; then
        sum=$(jq '[.providers[]?.cap // 0] | add // 0' "$SEAT_CAPS_JSON" 2>/dev/null || echo 0)
    fi
    [[ "$sum" =~ ^[0-9]+$ ]] || sum=0
    echo "$sum"
}

# Undersaturation admit ceiling (fleet-heartbeat-undersaturation): was
# min(target_concurrent, RAM governor); the RAM charge is gone, so it is
# min(target_concurrent, declared cap sum).
admit_ceiling() {
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    local tgt=25 sum
    if [[ -f "$SEAT_CAPS_JSON" ]]; then
        tgt=$(jq -r '.target_concurrent // 25' "$SEAT_CAPS_JSON" 2>/dev/null || echo 25)
    fi
    [[ "$tgt" =~ ^[0-9]+$ ]] || tgt=25
    sum=$(seat_max_concurrent)
    if (( sum > 0 && sum < tgt )); then echo "$sum"; else echo "$tgt"; fi
}

# Per-seat hang watchdog (seconds). Default 2520 (42 min).
seat_hang_timeout_s() {
    # fleet-ops#6154: callers (bin/pi-issue-run) have always passed the model as
    # $2, but this function only ever read $1, so a per-MODEL hang_timeout_s in
    # config/seat-caps.json was dead config - it silently resolved to the
    # provider value (or the 2520 default) and the seat kept getting rc=124
    # killed mid-session. Model override wins, then provider, then 2520.
    local p="${1:-}" m="${2:-}" val
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    [[ -f "$SEAT_CAPS_JSON" ]] || { echo 2520; return; }
    # A models entry is either a bare cap number or an object; only an object
    # can carry hang_timeout_s, so guard the index or jq errors out and the
    # provider-level value is lost too.
    val=$(jq -r --arg p "$p" --arg m "$m" \
        '((.providers[$p].models[$m] | if type == "object" then .hang_timeout_s else null end)
          // .providers[$p].hang_timeout_s // empty)' \
        "$SEAT_CAPS_JSON" 2>/dev/null || true)
    if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 60 )); then
        echo "$val"
        return
    fi
    echo 2520
}

# Count of live worker units registered under ACTIVE_SEATS_DIR (a count, not
# a RAM charge). Feeds the intake claim bound.
count_active_workers() {
    local n=0
    if [[ -d "$ACTIVE_SEATS_DIR" ]]; then
        n=$(find "$ACTIVE_SEATS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
        n=${n//[^0-9]/}
    fi
    echo "${n:-0}"
}

task_weight() {
    local pkt="$1" sz
    if [[ ! -f "$pkt" ]]; then
        echo "light"; return
    fi
    sz=$(wc -c < "$pkt" 2>/dev/null || echo 0)
    sz=${sz//[^0-9]/}; sz=${sz:-0}
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

packet_id_from_path() {
    local pkt="$1" base
    base=$(basename "$pkt")
    base="${base%.txt}"
    echo "${base//[^A-Za-z0-9._-]/_}"
}

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

seat_ledger_path() {
    local p="$1" m="$2" ps ms
    ps="${p//[^A-Za-z0-9._-]/_}"
    ms="${m//[^A-Za-z0-9._-]/_}"
    printf '%s/%s__%s.json\n' "$LEDGER_DIR" "$ps" "$ms"
}

_seat_in_future() {
    local ts="$1" epoch now
    [[ -n "$ts" ]] || return 1
    epoch=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
    now=$(date -u +%s)
    [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch > now ))
}

# Ledger read for keep-list callers (reap, recovery, auditor preflight).
# Routing itself lives in the proxy. No file = fail-open usable.
seat_usable() {
    local p="$1" m="$2" f hc bench_until dead
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
    [[ -f "$f" ]] || return 0
    # bench_until // usable_at — the retired picker's wall filter (fleet-ops#4263).
    bench_until=$(jq -r '.bench_until // .usable_at // empty' "$f" 2>/dev/null || true)
    if [[ -n "$bench_until" ]] && _seat_in_future "$bench_until"; then
        return 1
    fi
    hc=$(jq -r '.health_class // empty' "$f" 2>/dev/null || true)
    case "$hc" in
        quota_bench|transient_fault|corpse|rate_limited) return 1 ;;
    esac
    dead=$(jq -r '.seat_dead // false' "$f" 2>/dev/null || echo false)
    [[ "$dead" == "true" ]] && return 1
    return 0
}

# Wrappers (pi-issue-run, agent-cron-run) compare spawn_elapsed_s against
# these under `set -u`. Defaults lived in the deleted routing library;
# without them CI dies at `(( spawn_elapsed_s < SPAWN_FAIL_MAX_S ))`.
SPAWN_FAIL_BACKOFF_S="${SPAWN_FAIL_BACKOFF_S:-300}"
SPAWN_FAIL_MAX_S="${SPAWN_FAIL_MAX_S:-120}"
SPAWN_FAIL_BACKOFF_CAP_S="${SPAWN_FAIL_BACKOFF_CAP_S:-3600}"

# fleet-ops#4263 fallout restore (red main #3): the #5993 routing deletion
# stubbed mark_seat_empty_run / mark_seat_spawn_fail into no-ops and stripped
# the spawn-bench marker check from seat_usable. pi-issue-run kept CALLING
# them, so empty-run seats were never parked — the 2026-09-01 openrouter
# churn class (fleet-ops#2627) ran undetected. Restored verbatim from the
# pre-#5993 routing library (5411da097^); the tests pinning every behaviour
# below never stopped being in P14 — they were simply never run on main.

SEAT_BENCH_GEOMETRIC_CAP_S="${SEAT_BENCH_GEOMETRIC_CAP_S:-21600}"
SEAT_NON_MONEY_WALL_MAX_S="${SEAT_NON_MONEY_WALL_MAX_S:-21600}"
SEAT_REMOTE_AGENT_EMPTY_RUN_CAP_S="${SEAT_REMOTE_AGENT_EMPTY_RUN_CAP_S:-1800}"
SEAT_FAILURE_CEILING="${SEAT_FAILURE_CEILING:-20}"
SEAT_PARK_WALL_S="${SEAT_PARK_WALL_S:-86400}"  # 24 h — probe once per day, not per 15min
SEAT_PARK_WALL_MAX_S="${SEAT_PARK_WALL_MAX_S:-604800}"  # 7 days — cap on the escalated park wall
SEAT_TRANSPORT_DOWN_MARKER="${SEAT_TRANSPORT_DOWN_MARKER:-$STATE_DIR/transport-down.json}"
SEAT_HEALTH_SIDECAR="${PI_SEAT_HEALTH_SIDECAR:-$HOME/workspaces/agent-state/lanes/pi-seat-health.json}"
EMPTY_RUN_BACKOFF_S="${EMPTY_RUN_BACKOFF_S:-900}"  # 15 min
EMPTY_RUN_MARKER_FRESH_S="${EMPTY_RUN_MARKER_FRESH_S:-1800}"  # 30 min — spawn-fail count-merge window
EMPTY_RUN_COUNT_WINDOW_S="${EMPTY_RUN_COUNT_WINDOW_S:-$SEAT_PARK_WALL_S}"
EMPTY_RUN_FAILURE_CEILING="${EMPTY_RUN_FAILURE_CEILING:-3}"
SEAT_DEAD_CONSECUTIVE_THRESHOLD="${SEAT_DEAD_CONSECUTIVE_THRESHOLD:-25}"

_seat_now_epoch() {
    if [[ -n "${FLEET_SEAT_RECOVERY_NOW:-}" ]]; then
        date -u -d "$FLEET_SEAT_RECOVERY_NOW" +%s 2>/dev/null || date -u +%s
        return
    fi
    date -u +%s
}

_seat_key_in_caps() {
    local p="$1" m="$2"
    # Never a real model id — reject regardless of the caps fail-open.
    [[ "$m" != *.out ]] || return 1
    [[ -f "$SEAT_CAPS_JSON" ]] || return 0
    jq -e --arg p "$p" --arg m "$m" \
        '.providers[$p].models[$m] != null' "$SEAT_CAPS_JSON" >/dev/null 2>&1
}

_seat_key_guard() {
    local p="$1" m="$2" writer="$3"
    if _seat_key_in_caps "$p" "$m"; then
        return 0
    fi
    seat_log "LOUD SEAT-KEY-INVALID $p/$m writer=$writer"
    return 1
}

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

seat_spawn_bench_path() {
    local p="$1" m="$2" ps ms
    ps="${p//[^A-Za-z0-9._-]/_}"
    ms="${m//[^A-Za-z0-9._-]/_}"
    printf '%s/%s__%s.spawn-bench.json\n' "$LEDGER_DIR" "$ps" "$ms"
}

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

_geometric_bench_window() {
    local base="${1:-300}" count="${2:-1}" cap="${3:-$SEAT_BENCH_GEOMETRIC_CAP_S}" ceil_ovr="${4:-}"
    [[ "$base" =~ ^[0-9]+$ ]] || base=300
    [[ "$count" =~ ^[0-9]+$ ]] || count=1
    [[ "$cap" =~ ^[0-9]+$ ]] || cap=21600
    local window
    window=$(_escalated_backoff "$base" "$count" "$cap")
    _failure_ceiling_wall "$count" "$window" "$ceil_ovr"
}

_seat_parked_by_ceiling() {
    local count="${1:-0}" ceil_override="${2:-}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    local ceil="${SEAT_FAILURE_CEILING:-20}"
    [[ -n "$ceil_override" ]] && ceil="$ceil_override"
    [[ "$ceil" =~ ^[0-9]+$ ]] || ceil=20
    (( count >= ceil ))
}

_seat_dead_by_threshold() {
    local count="${1:-0}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    local thr="${SEAT_DEAD_CONSECUTIVE_THRESHOLD:-25}"
    [[ "$thr" =~ ^[0-9]+$ ]] || thr=25
    (( count >= thr ))
}

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
        # and the picker re-offered the no-op'ing seat — live
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
mark_seat_quota_bench() { seat_log "mark_seat_quota_bench: $* (proxy cooldown owns routing)"; return 0; }
mark_seat_overload_bench() { seat_log "mark_seat_overload_bench: $* (proxy cooldown owns routing)"; return 0; }
mark_seat_hang_bench() { seat_log "mark_seat_hang_bench: $* (proxy cooldown owns routing)"; return 0; }
mark_seat_credentials_bad() { seat_log "mark_seat_credentials_bad: ${1:-}/${2:-} (proxy cooldown owns routing)"; return 0; }
mark_seat_worked_no_text() { return 1; }
reset_seat_worked_no_text() { return 0; }
seat_worked_no_text_path() { echo ""; }
# Local consecutive-count bench is gone. Wrappers still call this; false
# means "not a remote agent classified here" so the loud-fail path runs.
provider_remote_agent() { return 1; }
# Real counter, not a stub: pi-issue-run's provider-death resume (#5788) and
# hang-watchdog slow-session gate (#3883) both key on it. A stub returning 0
# silently disabled both after #4263 deleted the routing library.
# arg: session jsonl -> number of toolResult messages (0 when missing).
session_tool_calls() {
    local f="${1:-}" n
    [[ -n "$f" && -f "$f" ]] || { printf '0'; return 0; }
    n=$(jq -r 'select(.message.role? == "toolResult") | .message.toolCallId // empty' "$f" 2>/dev/null | grep -c . 2>/dev/null || true)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}
# Spawn-phase timeout / E2BIG (keep-list detector; routing stays in the proxy).
# fleet-ops#5309: spawnSync E2BIG must classify so a missed pre-flight cap
# benches instead of crash-looping the same seat to StartLimitBurst.
is_spawn_etimeout() {
    local out="$1" err="$2"
    local combined="$out"$'\n'"$err"
    [[ -n "$combined" ]] || return 1
    if ! grep -qiE 'ETIMEDOUT|E2BIG|connection timed out|connect ETIMEDOUT|timed out waiting' <<<"$combined"; then
        return 1
    fi
    if grep -qiE '.{0,120}(ETIMEDOUT|E2BIG|timed out).{0,120}(spawn|socket|connect|child|fetch|handshake)' <<<"$combined"; then
        return 0
    fi
    if grep -qiE '(spawn|socket|connect|child|fetch|handshake).{0,120}(ETIMEDOUT|E2BIG|timed out)' <<<"$combined"; then
        return 0
    fi
    return 1
}
is_mid_session_death() { return 1; }
# Restored pure matchers (fleet-ops#4263 fallout): pi-issue-run still branches
# on these; their deletion made every call return 127 (= silently false).
is_devin_writes_rejected() {
    local out="$1" err="$2"
    local combined="$out"$'\n'"$err"
    [[ -n "$combined" ]] || return 1
    grep -qiF 'rejected a tool call that requires confirmation' <<<"$combined"
}
is_sandbox_localhost_error() {
    local out="$1" err="$2"
    grep -qiF 'error connecting to localhost' <<<"$out"$'\n'"$err"
}
is_workspace_trust_error() {
    local out="$1" err="$2"
    local combined="$out"$'\n'"$err"
    [[ -n "$combined" ]] || return 1
    grep -qiF 'Refusing to run in an untrusted workspace' <<<"$combined"
}
# Bench/usage markers still called by keep-list wrappers; the proxy owns cooldown and /spend.
mark_seat_writes_refused_bench() { seat_log "mark_seat_writes_refused_bench: $* (proxy owns cooldown/spend)"; return 0; }
mark_seat_config_fault_bench() { seat_log "mark_seat_config_fault_bench: $* (proxy owns cooldown/spend)"; return 0; }
mark_seat_devin_writes_rejected_bench() { seat_log "mark_seat_devin_writes_rejected_bench: $* (proxy owns cooldown/spend)"; return 0; }
mark_seat_empty_success() { seat_log "mark_seat_empty_success: $* (proxy owns cooldown/spend)"; return 0; }
# Real matcher (restored, fleet-ops#4263 fallout): agent-cron-run classifies an
# approval-gate refusal with it behind `declare -F`, so its deletion silently
# disabled WRITES-REFUSED detection instead of failing.
is_writes_refused() {
    local out="$1" err="$2"
    local combined="$out"$'\n'"$err"
    [[ -n "$combined" ]] || return 1
    if grep -q 'WRITES-REFUSED' <<<"$combined"; then
        return 0
    fi
    grep -qiE 'approval[[:space:]-]?cards?[[:space:]]+(were|was[[:space:]]+)?(rejected|refused|denied)|blocked[[:space:]]+by[[:space:]]+(cursor[[:space:]]+)?auto-review|auto-review[[:space:]]+blocked|rejected[[:space:]]+a[[:space:]]+tool[[:space:]]+call' <<<"$combined"
}
# Real matcher, not a stub: pi-issue-run and stop-escalation-dispatch classify a
# 401/invalid-key death with it (fleet-ops#4640/#5788). #4263 deleted it with the
# routing library while both callers kept calling it, so every credentials
# failure fell through unclassified (a missing function returns 127 = false).
is_credentials_error() {
    local out="${1:-}" err="${2:-}"
    local combined="$out"$'\n'"$err"
    [[ -n "${out}${err}" ]] || return 1
    grep -qiE '\b401\b|invalid[[:space:]]+token|unauthorized|authentication[[:space:]]+failed|authentication_error|invalid[[:space:]]+api[[:space:]]+key|invalid_api_key|(invalid|incorrect|missing|expired|revoked)[[:space:]]+(api|access)[[:space:]]+(key|token)|\blogin[[:space:]]+fail|carry[[:space:]]+the[[:space:]]+api[[:space:]]+secret[[:space:]]+key' <<<"$combined"
}
# Restored real matcher (fleet-ops#4263 fallout): classify_death_error names the class.
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
is_quota_error() { return 1; }
# Restored real matcher (fleet-ops#4263 fallout): classify_death_error names the class.
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
_seat_is_benched() { return 1; }
_seat_merge_error_class() { return 0; }

# Observability only (fleet-ops#3766). Class matchers above are stubs, so
# the class is unknown unless the hang_etimedout grep hits. The literal
# still lands on PACKET-VERDICT; the proxy owns cooldown.
classify_death_error() {
    local out="${1:-}" err="${2:-}" sess="${3:-}"
    local out_text="" err_text=""
    [[ -n "$out" && -f "$out" ]] && out_text=$(cat "$out" 2>/dev/null || true)
    [[ -n "$err" && -f "$err" ]] && err_text=$(cat "$err" 2>/dev/null || true)
    local cls="unknown"
    if is_quota_cap_error "$out_text" "$err_text"; then
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

# --- fleet-ops#6032: AIMD learned-cap + parked-ledger primitives -------------
# #5993 deleted the routing library; #6095 restored its other callers' needs
# into this file. These four are the residue the #6032 sweep still found
# called (comeback-release overload wall + corpse retire). Restored verbatim
# from the pre-#5993 routing library (5411da097^), with the pick-side prose
# reworded off the retired-routing signature (freeze gate). Nobody reads
# learned-caps.json yet (the #4263 read side went to the proxy): the write
# side is the mechanism the comeback-release caller documents, and the audit
# line is the durable record.

LEARNED_CAPS_JSON="${LEARNED_CAPS_JSON:-$HOME/.local/state/pi-packet/learned-caps.json}"
LEARNED_CAPS_AUDIT="${LEARNED_CAPS_AUDIT:-$HOME/.local/state/pi-packet/learned-caps-audit.log}"

declare -A LEARNED_CAP=()
declare -A LEARNED_BENCH_UNTIL=()
declare -A LEARNED_RAMP=()

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
# current in-memory LEARNED_RAMP[$p] (so probes during a ramp keep the flag).
_learned_audit() {
    local line="$1"
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >>"$LEARNED_CAPS_AUDIT" 2>/dev/null || true
}

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
    # real bench; the picker never offers it) is recognisable as benched, never
    # fail-open.
    br="corpse-retired: cap=0 corpse bench, the picker never offers (durable, fleet-ops#2716/#3669)"
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
