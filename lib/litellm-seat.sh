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

# --- #6032: previously-removed routing helpers, restored verbatim from 5411da097^ (pre-5993).
# Only these were still called; see tests/no-undefined-call.test.sh for the enforcement.

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

_exec_is_pi_worker() {
    local line="$1"
    [[ "$line" == *"pi --print"* ]]
}

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

_is_keystone_class() {
    [[ "${1:-}" == "keystone" || "${1:-}" == "senior-review" ]]
}

_learned_audit() {
    local line="$1"
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >>"$LEARNED_CAPS_AUDIT" 2>/dev/null || true
}

_learned_ramp_stale() {
    local ts="$1" epoch now
    [[ -n "$ts" ]] || return 1
    epoch=$(date -u -d "$ts" +%s 2>/dev/null) || return 1
    [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
    now=$(date -u +%s)
    (( now - epoch >= LEARNED_RAMP_STALE_S ))
}

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

_prepaid_iso_week() { date -u +%G-W%V; }


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

_prepaid_usage_path() {
    echo "$STATE_DIR/prepaid-usage/${1}.json"
}

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

_provider_is_keystone_only() {
    local p="$1"
    [[ "$p" == "cursor" ]] && return 0
    return 1
}

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

_sanitise_seat() {
    local p="$1" m="$2"
    local ps="${p//[^A-Za-z0-9._-]/_}"
    local ms="${m//[^A-Za-z0-9._-]/_}"
    printf '__dead__/%s/%s\n' "$ps" "$ms"
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

_seat_floor_is_failopen_class() {
    local hc="$1" fm="${2:-}"
    case " $SEAT_FLOOR_FAILOPEN_CLASSES " in
        *" $hc "*) return 0 ;;
    esac
    return 1
}

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

_seat_is_dead() {
    local p="$1" m="$2"
    local k
    k=$(_sanitise_seat "$p" "$m")
    [[ -n "${_EXCLUDED_REASON[$k]:-}" ]]
}

_seat_key_guard() {
    local p="$1" m="$2" writer="$3"
    if _seat_key_in_caps "$p" "$m"; then
        return 0
    fi
    seat_log "LOUD SEAT-KEY-INVALID $p/$m writer=$writer"
    return 1
}

_seat_key_in_caps() {
    local p="$1" m="$2"
    # Never a real model id — reject regardless of the caps fail-open.
    [[ "$m" != *.out ]] || return 1
    [[ -f "$SEAT_CAPS_JSON" ]] || return 0
    jq -e --arg p "$p" --arg m "$m" \
        '.providers[$p].models[$m] != null' "$SEAT_CAPS_JSON" >/dev/null 2>&1
}

_seat_list_org_unit() {
    _seat_list_pi_exec
}

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

_seat_list_unit() {
    _seat_list_pi_exec
}

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

_seat_liveness_bound_s() {
    local sysunit="$1" raw parsed
    raw=$(systemctl --user show "$sysunit" --property=TimeoutStartUSec --value 2>/dev/null || true)
    parsed=$(_seat_duration_to_s "$raw" 2>/dev/null || true)
    if [[ "$parsed" =~ ^[0-9]+$ ]] && (( parsed > 0 )); then
        echo "$parsed"; return 0
    fi
    echo "${PI_SEAT_ACTIVATING_MAX_S:-3300}"
}

_seat_now_epoch() {
    if [[ -n "${FLEET_SEAT_RECOVERY_NOW:-}" ]]; then
        date -u -d "$FLEET_SEAT_RECOVERY_NOW" +%s 2>/dev/null || date -u +%s
        return
    fi
    date -u +%s
}

_seat_parked_by_ceiling() {
    local count="${1:-0}" ceil_override="${2:-}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    local ceil="${SEAT_FAILURE_CEILING:-20}"
    [[ -n "$ceil_override" ]] && ceil="$ceil_override"
    [[ "$ceil" =~ ^[0-9]+$ ]] || ceil=20
    (( count >= ceil ))
}

_seat_rate_limit_fresh() {
    local obs="$1" now obs_s
    [[ -n "$obs" ]] || return 1
    now=$(_seat_now_epoch)
    obs_s=$(date -u -d "$obs" +%s 2>/dev/null || echo 0)
    [[ "$obs_s" =~ ^[0-9]+$ ]] || return 1
    (( obs_s > 0 && now - obs_s <= RATE_LIMIT_FRESH_SECS ))
}

_seat_reap_stale_registry() {
    local f="$1" unit
    unit=$(jq -r '.unit // "unknown"' "$f" 2>/dev/null || true)
    seat_log "seat registry: reaping stale entry $f (unit $unit not active)"
    rm -f "$f" 2>/dev/null || true
}

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

_seat_remaining_s() {
    local ts="$1" now ts_s
    [[ -n "$ts" ]] || return 1
    now=$(_seat_now_epoch)
    ts_s=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
    [[ "$ts_s" =~ ^[0-9]+$ ]] || return 1
    (( ts_s > now )) || return 1
    printf '%s\n' "$((ts_s - now))"
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

_tick_spawn_count() {
    local p="$1"
    [[ -f "$SEAT_TICK_SPAWN_COUNTS_JSON" ]] || { echo 0; return; }
    local n
    n=$(jq -r --arg p "$p" '.[$p] // 0' "$SEAT_TICK_SPAWN_COUNTS_JSON" 2>/dev/null || echo 0)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    echo "$n"
}

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

class_of() {
    local p="$1" c
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    c="${SEAT_PROVIDER_CLASS[$p]:-free}"
    [[ "$c" == "subscription" ]] && c="prepaid-quota"
    echo "$c"
}

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

count_active_total() {
    local issue org reserve charge
    issue=$(count_active_issue)
    org=$(count_active_org)
    reserve=$(org_reserve)
    charge=$org
    (( charge > reserve )) && charge=$reserve
    echo $(( issue + charge ))
}

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

model_cap() {
    local p="$1" m="$2"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    echo "${SEAT_MODEL_CAP[$p/$m]:-0}"
}

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

org_reserve() {
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    echo "${SEAT_ORG_RESERVE:-2}"
}

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

provider_cap() {
    local p="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    echo "${SEAT_PROVIDER_CAP[$p]:-0}"
}

provider_hard_ceiling() {
    local p="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    [[ "${SEAT_PROVIDER_HARD_CEILING[$p]:-0}" == "1" ]]
}

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

provider_quota_bench_default() {
    local p="$1"
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    echo "${SEAT_PROVIDER_BENCH_DEFAULT[$p]:-0}"
}

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

seat_cost_for() {
    local p="${1:-}" m="${2:-}"
    [[ -n "$p" && -n "$m" ]] || return 1
    if (( ! _seat_yield_loaded )); then load_seat_yield || true; fi
    echo "${SEAT_COST[$p/$m]:-0}"
}

seat_is_audition() {
    local p="${1:-}" m="${2:-}"
    [[ -n "$p" && -n "$m" ]] || return 1
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    [[ -n "${SEAT_AUDITION[$p]:-}" || -n "${SEAT_AUDITION[$p/$m]:-}" ]]
}

seat_is_reprobe_light_only() {
    local p="${1:-}" m="${2:-}"
    [[ -n "$p" && -n "$m" ]] || return 1
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    [[ -n "${SEAT_REPROBE_LIGHT_ONLY[$p]:-}" || -n "${SEAT_REPROBE_LIGHT_ONLY[$p/$m]:-}" ]]
}

seat_spawn_bench_path() {
    local p="$1" m="$2" ps ms
    ps="${p//[^A-Za-z0-9._-]/_}"
    ms="${m//[^A-Za-z0-9._-]/_}"
    printf '%s/%s__%s.spawn-bench.json\n' "$LEDGER_DIR" "$ps" "$ms"
}

seat_yield_for() {
    local p="${1:-}" m="${2:-}"
    [[ -n "$p" && -n "$m" ]] || return 1
    if (( ! _seat_yield_loaded )); then load_seat_yield || true; fi
    echo "${SEAT_YIELD[$p/$m]:-0.5}"
}

target_concurrent() {
    if (( ! _seat_caps_loaded )); then load_seat_caps || true; fi
    echo "${SEAT_TARGET_CONCURRENT:-25}"
}

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
