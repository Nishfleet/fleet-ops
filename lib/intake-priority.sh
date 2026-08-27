# shellcheck shell=bash
# intake-priority.sh — mechanical claim order for pi-intake (fleet-ops#379).
#
# Sourced by bin/pi-intake-priority. NOT executed directly.
#
# Verified absent before this file existed: Pi's stock extensions have no
# GitHub-issue priority pattern (docs/extensions.md + examples/extensions;
# github-issue-autocomplete only fuzzy-filters #N). prompts/intake.md claimed
# agent-ready issues in ascending issue-number order. This lib is the orderer.
#
# Rules:
#   1. A ready issue is critical if it carries `critical-path` (the
#      detector→queue reconciler, fleet-ops#362, adds it when it files a
#      keystone-signal issue). `escalate-senior` issues are NOT critical
#      work for a regular lane: they are routed to the senior-auditor panel
#      (fleet-ops#234) and excluded from the regular-worker claim order.
#   2. Critical issues are claimed before the agent-ready tail.
#   3. Anti-starvation: if the last INTAKE_PRIORITY_MAX_CRITICAL records
#      are all critical AND a tail issue is waiting, the next pick is the
#      lowest-number tail issue (kind=tail-ratio). Logged on the tick line
#      as ratio=k/window. Does not invent a tail when none exists.
#   4. Within a tier, lowest issue number first (stable, same as the old
#      total order inside each bucket).
#
# Pure: no network, no git. Callers pass issue JSON and a ratio-state file.

INTAKE_PRIORITY_MAX_CRITICAL="${INTAKE_PRIORITY_MAX_CRITICAL:-2}"
INTAKE_PRIORITY_WINDOW="${INTAKE_PRIORITY_WINDOW:-3}"
INTAKE_PRIORITY_LABEL="${INTAKE_PRIORITY_LABEL:-critical-path}"
INTAKE_PRIORITY_ESCALATE_LABEL="${INTAKE_PRIORITY_ESCALATE_LABEL:-escalate-senior}"

intake_priority_classify() {
    # stdin: gh issue list JSON array. stdout: classified JSON array.
    local label escalate
    label="$INTAKE_PRIORITY_LABEL"
    escalate="$INTAKE_PRIORITY_ESCALATE_LABEL"
    jq -c --arg label "$label" --arg escalate "$escalate" '
      def names:
        (.labels // [])
        | map(if type == "string" then . else (.name // empty) end);
      def has($l): names | index($l) != null;
      map({
        number: .number,
        title: (.title // ""),
        # fleet-ops#234: escalate-senior is senior-panel-owned, never a
        # regular-worker claim. Mark it escalation so the walk can exclude it.
        escalation: has($escalate),
        critical: has($label),
        display_kind: (
          if has($escalate) then $escalate
          elif has($label) then $label
          else "tail"
          end
        )
      })
      | map(select(.number != null))
      | sort_by(.number)
    '
}

intake_priority_recent_kinds() {
    local f="$1"
    local n="$2"
    if [[ ! -f "$f" ]]; then
        return 0
    fi
    grep -E '^(critical|tail)$' "$f" | tail -n "$n" || true
}

intake_priority_ratio_blocks_critical() {
    local f="$1"
    local max="$INTAKE_PRIORITY_MAX_CRITICAL"
    local recent crit
    recent="$(intake_priority_recent_kinds "$f" "$max")"
    [[ -n "$recent" ]] || return 1
    local lines
    lines="$(printf '%s\n' "$recent" | grep -c . || true)"
    [[ "$lines" -ge "$max" ]] || return 1
    crit="$(printf '%s\n' "$recent" | grep -c '^critical$' || true)"
    [[ "$crit" -ge "$max" ]]
}

intake_priority_ratio_string() {
    local f="$1"
    local window="$INTAKE_PRIORITY_WINDOW"
    local recent crit
    recent="$(intake_priority_recent_kinds "$f" "$window")"
    crit="$(printf '%s\n' "$recent" | grep -c '^critical$' || true)"
    printf '%s/%s' "$crit" "$window"
}

intake_priority_normalize_kind() {
    case "$1" in
        critical|critical-path|escalate-senior) printf 'critical\n' ;;
        *) printf 'tail\n' ;;
    esac
}

intake_priority_record() {
    local f="$1"
    local kind="$2"
    local dir
    dir="$(dirname "$f")"
    mkdir -p "$dir"
    intake_priority_normalize_kind "$kind" >>"$f"
    # Bound the ledger so a long-lived host cannot grow it without limit.
    if [[ -f "$f" ]]; then
        local trimmed
        trimmed="$(intake_priority_recent_kinds "$f" 20)"
        printf '%s\n' "$trimmed" >"$f"
    fi
}

intake_priority_walk() {
    # $1 classified JSON  $2 state file  $3 pick_one (0/1)
    local remaining="$1"
    local state_file="$2"
    local pick_one="${3:-0}"
    local sim
    sim="$(mktemp)"
    # fleet-ops#234: escalate-senior issues never enter the regular-worker
    # claim order; the senior-auditor panel owns them. Drop them up front.
    remaining="$(jq -c '[.[] | select(.escalation != true)]' <<<"$remaining")"
    intake_priority_recent_kinds "$state_file" 20 >"$sim" || true

    while jq -e 'length > 0' <<<"$remaining" >/dev/null; do
        local force=0
        local tail_count
        tail_count="$(jq -r '[.[] | select(.critical|not)] | length' <<<"$remaining")"
        if [[ "$tail_count" -gt 0 ]] && intake_priority_ratio_blocks_critical "$sim"; then
            force=1
        fi

        local pick rec kind num ratio
        if [[ "$force" == 1 ]]; then
            pick="$(jq -c '[.[] | select(.critical|not)] | .[0]' <<<"$remaining")"
            kind="tail-ratio"
            rec="tail"
        else
            pick="$(jq -c '([.[] | select(.critical)] + [.[] | select(.critical|not)]) | .[0]' <<<"$remaining")"
            if jq -e '.critical == true' <<<"$pick" >/dev/null; then
                kind="$(jq -r '.display_kind' <<<"$pick")"
                rec="critical"
            else
                kind="tail"
                rec="tail"
            fi
        fi
        if [[ -z "$pick" || "$pick" == "null" ]]; then
            break
        fi

        num="$(jq -r '.number' <<<"$pick")"
        [[ "$num" =~ ^[1-9][0-9]*$ ]] || {
            echo "intake-priority: refusing non-numeric issue number '$num'" >&2
            remaining="$(jq -c --argjson n "$num" '[.[] | select(.number != $n)]' <<<"$remaining" 2>/dev/null || echo '[]')"
            continue
        }

        printf '%s\n' "$rec" >>"$sim"
        ratio="$(intake_priority_ratio_string "$sim")"
        printf '%s\t%s\tratio=%s\n' "$num" "$kind" "$ratio"

        remaining="$(jq -c --argjson n "$num" '[.[] | select(.number != $n)]' <<<"$remaining")"
        if [[ "$pick_one" == 1 ]]; then
            break
        fi
    done
    rm -f "$sim"
}
