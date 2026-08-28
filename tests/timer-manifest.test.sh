#!/usr/bin/env bash
# tests/timer-manifest.test.sh
#
# Validates the fleet timer manifest (systemd/timer-manifest.json).
# Every user timer must have an entry with a named reason — the standing
# rule "a schedule needs a named reason" made mechanical (fleet-ops#1460).
#
# Two modes, auto-selected by environment:
#
#   1. SHAPE LOCK (CI — no systemctl, no VPS). Validates:
#      - Manifest is valid JSON.
#      - Every entry has reason, classification, cadence, source.
#      - classification is one of: scheduled, converting, template,
#        deprecated, disabled.
#      - source is one of: repo, user-config.
#      - Every .timer file in systemd/ has a manifest entry.
#
#   2. LIVE CHECK (VPS — systemctl --user available). Additionally:
#      - Every live user timer has a manifest entry (exact or template match).
#      - Reports any live timer missing from the manifest.
#
# Lock-and-leave. If any invariant fails, the test exits 1 and CI fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/systemd/timer-manifest.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$MANIFEST" ]] || fail "manifest not found: $MANIFEST"
jq '.' "$MANIFEST" >/dev/null || fail "manifest is not valid JSON"

ok "manifest JSON is valid"

# --- Shape lock: every entry has required fields + valid enums ---

REQUIRED_FIELDS=(reason classification cadence source)
VALID_CLASSIFICATIONS=("scheduled" "converting" "template" "deprecated" "disabled")
VALID_SOURCES=("repo" "user-config")

field_errors=0
while IFS= read -r timer; do
    [[ -z "$timer" ]] && continue
    for field in "${REQUIRED_FIELDS[@]}"; do
        val=$(jq -r ".timers[\"$timer\"].$field // empty" "$MANIFEST")
        if [[ -z "$val" ]]; then
            echo "FAIL: entry '$timer' missing required field '$field'" >&2
            field_errors=1
        fi
    done

    classification=$(jq -r ".timers[\"$timer\"].classification // empty" "$MANIFEST")
    valid_cls=0
    for vc in "${VALID_CLASSIFICATIONS[@]}"; do
        [[ "$classification" == "$vc" ]] && valid_cls=1 && break
    done
    if [[ $valid_cls -eq 0 && -n "$classification" ]]; then
        echo "FAIL: entry '$timer' has invalid classification '$classification'" >&2
        field_errors=1
    fi

    source=$(jq -r ".timers[\"$timer\"].source // empty" "$MANIFEST")
    valid_src=0
    for vs in "${VALID_SOURCES[@]}"; do
        [[ "$source" == "$vs" ]] && valid_src=1 && break
    done
    if [[ $valid_src -eq 0 && -n "$source" ]]; then
        echo "FAIL: entry '$timer' has invalid source '$source'" >&2
        field_errors=1
    fi
done < <(jq -r '.timers | keys[]' "$MANIFEST" | sort)

[[ $field_errors -eq 0 ]] || fail "one or more manifest entries have missing or invalid fields"

ok "all manifest entries have required fields with valid enum values"

# --- Shape lock: every .timer in systemd/ has a manifest entry ---

missing_repo=0
while IFS= read -r timer_file; do
    [[ -z "$timer_file" ]] && continue
    timer_name=$(basename "$timer_file")
    # Exact match
    if jq -e ".timers[\"$timer_name\"]" "$MANIFEST" >/dev/null 2>&1; then
        continue
    fi
    # Template match: pi-intake@0509.timer → pi-intake@.timer
    base="${timer_name%%@*}@.timer"
    if [[ "$timer_name" == *"@"* ]] && jq -e ".timers[\"$base\"]" "$MANIFEST" >/dev/null 2>&1; then
        continue
    fi
    echo "FAIL: systemd/$timer_name has no manifest entry" >&2
    missing_repo=1
done < <(find "$REPO_ROOT/systemd" -maxdepth 1 -name '*.timer' -type f 2>/dev/null | sort)

[[ $missing_repo -eq 0 ]] || fail "one or more repo .timer files missing from manifest"

ok "all repo .timer files have manifest entries"

# --- Live check: only when systemctl --user is available ---

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_RUNTIME_DIR

if ! systemctl --user list-timers --no-pager >/dev/null 2>&1; then
    ok "systemctl --user not available (CI mode) — live check skipped"
    exit 0
fi

ok "systemctl --user available — running live check"

# Stale-checkout guard (fleet-ops#1555): the live check compares the LOCAL
# checkout's manifest against live timers. A checkout behind origin/main has
# a stale manifest and would false-alarm on entries already landed on main
# (e.g. grok-token-refresh.timer, #1547). Before failing on a missing live
# timer, check origin/main's manifest: if it already covers the timer, the
# local checkout is simply behind — SKIP that timer with a note rather than
# filing a false gap. Real gaps (missing from both local AND origin/main)
# still fail. If the fetch/show is unavailable, the guard is a no-op and the
# original fail-on-missing behavior is preserved.
ORIGIN_MANIFEST=""
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ORIGIN_MANIFEST="$(mktemp)"
    if ! git -C "$REPO_ROOT" fetch origin main:refs/timer-manifest-test-main >/dev/null 2>&1 || \
       ! git -C "$REPO_ROOT" show refs/timer-manifest-test-main:systemd/timer-manifest.json >"$ORIGIN_MANIFEST" 2>/dev/null || \
       ! jq '.' "$ORIGIN_MANIFEST" >/dev/null 2>&1; then
        rm -f "$ORIGIN_MANIFEST"
        ORIGIN_MANIFEST=""
    fi
    git -C "$REPO_ROOT" update-ref -d refs/timer-manifest-test-main 2>/dev/null || true
fi
[[ -n "$ORIGIN_MANIFEST" ]] && ok "origin/main manifest fetched for stale-checkout guard"

# System timers we exclude (OS-managed, not fleet)
SYSTEM_TIMERS=(
    "launchpadlib-cache-clean.timer"
    "systemd-tmpfiles-clean.timer"
    "apt-daily-upgrade.timer"
    "apt-daily.timer"
    "logrotate.timer"
    "man-db.timer"
    "fwupd-refresh.timer"
    "motd-news.timer"
    "ureadahead-stop.timer"
    "systemd-tmpfiles-setup.timer"
)

# Get all live user timers (unit files — covers active + inactive + disabled)
ALL_LIVE_TIMERS=$(
    systemctl --user list-unit-files '*.timer' --no-pager --no-legend 2>/dev/null | \
        awk '/\.timer/ {print $1}' | sort -u | grep -v '^$'
)

missing_live=0
while IFS= read -r timer; do
    [[ -z "$timer" ]] && continue

    # Skip system timers
    is_system=0
    for sys in "${SYSTEM_TIMERS[@]}"; do
        [[ "$timer" == "$sys" ]] && is_system=1 && break
    done
    [[ $is_system -eq 1 ]] && continue

    # Check exact match
    if jq -e ".timers[\"$timer\"]" "$MANIFEST" >/dev/null 2>&1; then
        continue
    fi

    # Check template match (pi-intake@0509.timer → pi-intake@.timer)
    base="${timer%%@*}@.timer"
    if [[ "$timer" == *"@"* ]] && jq -e ".timers[\"$base\"]" "$MANIFEST" >/dev/null 2>&1; then
        continue
    fi

    # Stale-checkout guard: if origin/main's manifest already covers this
    # timer (exact or template), the local checkout is behind main, not a
    # real gap. SKIP with a note instead of failing (fleet-ops#1555).
    if [[ -n "$ORIGIN_MANIFEST" ]]; then
        if jq -e ".timers[\"$timer\"]" "$ORIGIN_MANIFEST" >/dev/null 2>&1; then
            echo "SKIP: live timer '$timer' missing from LOCAL manifest but present on origin/main — checkout is behind, not a real gap" >&2
            continue
        fi
        obase="${timer%%@*}@.timer"
        if [[ "$timer" == *"@"* ]] && jq -e ".timers[\"$obase\"]" "$ORIGIN_MANIFEST" >/dev/null 2>&1; then
            echo "SKIP: live timer '$timer' (template '$obase') missing from LOCAL manifest but present on origin/main — checkout is behind, not a real gap" >&2
            continue
        fi
    fi

    echo "FAIL: live timer '$timer' missing from manifest" >&2
    missing_live=1
done <<< "$ALL_LIVE_TIMERS"

rm -f "$ORIGIN_MANIFEST"

[[ $missing_live -eq 0 ]] || fail "one or more live timers missing from manifest"

timer_count=$(echo "$ALL_LIVE_TIMERS" | grep -c '\.timer' || true)
manifest_count=$(jq -r '.timers | keys | length' "$MANIFEST")
ok "all $timer_count live user timers have manifest entries ($manifest_count manifest entries total)"
exit 0
