#!/usr/bin/env bash
set -euo pipefail
cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-4896
scratch=$(mktemp -d)
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_PACKET_STATE="$scratch/state"
export PI_ISSUES_DIR="$scratch/issues"
mkdir -p "$PI_PACKET_STATE/active-seats" "$PI_ISSUES_DIR"
printf 'difficulty: heavy\nTARGET: repo Nishfleet/fleet-ops issue 1 unit pi-issue-fleet-ops-1\n' > "$PI_ISSUES_DIR/fleet-ops-1.in"
printf 'difficulty: light\nTARGET: repo Nishfleet/fleet-ops issue 2 unit pi-issue-fleet-ops-2\n' > "$PI_ISSUES_DIR/fleet-ops-2.in"
jq -nc --arg u 'pi-issue-fleet-ops-1' --arg t 'x' '{unit:$u,provider:"p",model:"m",started_at:$t}' > "$PI_PACKET_STATE/active-seats/pi-issue-fleet-ops-1.json"
jq -nc --arg u 'pi-issue-fleet-ops-2' --arg t 'x' '{unit:$u,provider:"p",model:"m",started_at:$t}' > "$PI_PACKET_STATE/active-seats/pi-issue-fleet-ops-2.json"
export SEAT_CAPS_JSON="$PWD/config/seat-caps.json"
source lib/seat-lib.sh
echo "heavy=$(count_active_heavy)"
echo "charge=$(active_ram_charge)"
