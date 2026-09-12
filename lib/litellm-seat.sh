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
    litellm_ready || [[ "${GITHUB_ACTIONS:-}" == "true" ]]
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
    local p="${1:-}" val
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    [[ -f "$SEAT_CAPS_JSON" ]] || { echo 2520; return; }
    val=$(jq -r --arg p "$p" '.providers[$p].hang_timeout_s // empty' "$SEAT_CAPS_JSON" 2>/dev/null || true)
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

# Verdict-path stubs. Cooldown lives in the proxy; wrappers still call these
# so a failure is logged without writing routing ledgers.
mark_seat_spawn_fail() { seat_log "mark_seat_spawn_fail: $* (proxy cooldown owns routing)"; return 0; }
mark_seat_empty_run() { seat_log "mark_seat_empty_run: $* (proxy cooldown owns routing)"; return 0; }
mark_seat_quota_bench() { seat_log "mark_seat_quota_bench: $* (proxy cooldown owns routing)"; return 0; }
mark_seat_overload_bench() { seat_log "mark_seat_overload_bench: $* (proxy cooldown owns routing)"; return 0; }
mark_seat_hang_bench() { seat_log "mark_seat_hang_bench: $* (proxy cooldown owns routing)"; return 0; }
mark_seat_worked_no_text() { return 1; }
reset_seat_worked_no_text() { return 0; }
seat_worked_no_text_path() { echo ""; }
# Local consecutive-count bench is gone. Wrappers still call this; false
# means "not a remote agent classified here" so the loud-fail path runs.
provider_remote_agent() { return 1; }
session_tool_calls() { echo 0; }
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
is_overload_error() { return 1; }
is_quota_error() { return 1; }
is_quota_cap_error() { return 1; }
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

# --- credential-bad bench family: restored from pre-#5993 seat-lib.sh (fleet-ops#6028 class); callers bin/pi-issue-run:827-829 and bin/stop-escalation-dispatch:456-458 were left calling these by the litellm migration ---
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

_seat_key_guard() {
    local p="$1" m="$2" writer="$3"
    if _seat_key_in_caps "$p" "$m"; then
        return 0
    fi
    seat_log "LOUD SEAT-KEY-INVALID $p/$m writer=$writer"
    return 1
}

_seat_now_epoch() {
    if [[ -n "${FLEET_SEAT_RECOVERY_NOW:-}" ]]; then
        date -u -d "$FLEET_SEAT_RECOVERY_NOW" +%s 2>/dev/null || date -u +%s
        return
    fi
    date -u +%s
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


_seat_observed_fresh() {
    local obs="$1" now obs_s
    [[ -n "$obs" ]] || return 1
    now=$(_seat_now_epoch)
    obs_s=$(date -u -d "$obs" +%s 2>/dev/null || echo 0)
    [[ "$obs_s" =~ ^[0-9]+$ ]] || return 1
    (( obs_s > 0 && now - obs_s <= STALE_SECS ))
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





is_credentials_error() {
    local out="$1" err="$2"
    local combined="$out"$'\n'"$err"
    [[ -n "$combined" ]] || return 1
    grep -qiE '\b401\b|invalid[[:space:]]+token|unauthorized|authentication[[:space:]]+failed|authentication_error|invalid[[:space:]]+api[[:space:]]+key|invalid_api_key|(invalid|incorrect|missing|expired|revoked)[[:space:]]+(api|access)[[:space:]]+(key|token)|\blogin[[:space:]]+fail|carry[[:space:]]+the[[:space:]]+api[[:space:]]+secret[[:space:]]+key' <<<"$combined"
}

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

