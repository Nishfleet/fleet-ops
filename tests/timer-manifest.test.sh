#!/usr/bin/env bash
# Timer Manifest Validation Test
# Validates that every live user timer has a manifest entry with a named reason.
# Fails if: live timer missing from manifest, manifest entry missing reason, or manifest has invalid JSON.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/systemd/timer-manifest.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err() { echo -e "${RED}[ERR]${NC} $*"; }

# Check manifest exists and is valid JSON
if [[ ! -f "$MANIFEST" ]]; then
    log_err "Manifest not found at $MANIFEST"
    exit 1
fi

if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
    log_err "Manifest is not valid JSON"
    exit 1
fi

log_info "Manifest JSON is valid"

# Get live user timers (unit names that activate a service)
# Filter out system timers and headers
LIVE_TIMERS=$(XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-timers --all --no-pager --no-legend 2>/dev/null | \
    awk '/^\S+\.timer/ {print $NF}' | \
    sed 's/\.service$/.timer/' | \
    sort -u)

# Also get timers from systemctl list-unit-files to catch inactive ones
LIVE_TIMERS_ALL=$(XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-unit-files '*.timer' --no-pager --no-legend 2>/dev/null | \
    awk '/\.timer/ {print $1}' | \
    sort -u)

# Combine and deduplicate
ALL_LIVE_TIMERS=$(echo -e "$LIVE_TIMERS\n$LIVE_TIMERS_ALL" | sort -u | grep -v '^$' || true)

log_info "Found live user timers:"
echo "$ALL_LIVE_TIMERS" | sed 's/^/  /'

# Get manifest timer names
MANIFEST_TIMERS=$(jq -r '.timers | keys[]' "$MANIFEST" | sort)
log_info "Manifest timer entries:"
echo "$MANIFEST_TIMERS" | sed 's/^/  /'

# Check each manifest entry has required fields
MISSING_FIELDS=0
while IFS= read -r timer; do
    [[ -z "$timer" ]] && continue
    reason=$(jq -r ".timers[\"$timer\"].reason // empty" "$MANIFEST")
    classification=$(jq -r ".timers[\"$timer\"].classification // empty" "$MANIFEST")
    cadence=$(jq -r ".timers[\"$timer\"].cadence // empty" "$MANIFEST")
    source=$(jq -r ".timers[\"$timer\"].source // empty" "$MANIFEST")
    
    if [[ -z "$reason" ]]; then
        log_err "Manifest entry for $timer missing 'reason'"
        MISSING_FIELDS=1
    fi
    if [[ -z "$classification" ]]; then
        log_err "Manifest entry for $timer missing 'classification'"
        MISSING_FIELDS=1
    fi
    if [[ -z "$cadence" ]]; then
        log_err "Manifest entry for $timer missing 'cadence'"
        MISSING_FIELDS=1
    fi
    if [[ -z "$source" ]]; then
        log_err "Manifest entry for $timer missing 'source'"
        MISSING_FIELDS=1
    fi
done <<< "$MANIFEST_TIMERS"

if [[ $MISSING_FIELDS -eq 1 ]]; then
    exit 1
fi

log_info "All manifest entries have required fields (reason, classification, cadence, source)"

# Check live timers against manifest (excluding system timers)
# System timers we know about and exclude
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

MISSING_FROM_MANIFEST=0
while IFS= read -r timer; do
    [[ -z "$timer" ]] && continue
    
    # Skip system timers
    is_system=0
    for sys in "${SYSTEM_TIMERS[@]}"; do
        if [[ "$timer" == "$sys" ]]; then
            is_system=1
            break
        fi
    done
    if [[ $is_system -eq 1 ]]; then
        continue
    fi
    
    # Check if in manifest (exact match or template match for pi-intake@, pi-scout@)
    in_manifest=0
    if jq -e ".timers[\"$timer\"]" "$MANIFEST" >/dev/null 2>&1; then
        in_manifest=1
    else
        # Check for template match (pi-intake@*, pi-scout@*)
        base_timer="${timer%@*}.timer"
        if [[ "$timer" == *"@"* ]] && jq -e ".timers[\"$base_timer\"]" "$MANIFEST" >/dev/null 2>&1; then
            in_manifest=1
        fi
    fi
    
    if [[ $in_manifest -eq 0 ]]; then
        log_err "Live timer '$timer' is MISSING from manifest"
        MISSING_FROM_MANIFEST=1
    fi
done <<< "$ALL_LIVE_TIMERS"

if [[ $MISSING_FROM_MANIFEST -eq 1 ]]; then
    log_err "One or more live timers missing from manifest"
    exit 1
fi

log_info "All live user timers have manifest entries with named reasons"
exit 0
