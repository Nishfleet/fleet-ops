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
