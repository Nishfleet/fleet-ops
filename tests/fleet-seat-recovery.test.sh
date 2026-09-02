#!/usr/bin/env bash
# tests/fleet-seat-recovery.test.sh
#
# Instant seat-recovery (fleet-ops#468, decisions-ledger 2026-08-27 TOP
# GEAR): when NO-USABLE-SEAT flips to seat-available, intake fires the
# INSTANT the seat-health ledger write lands (.path event trigger), not on
# the next 15-min tick. No polling.
#
# What we prove:
#   1. usable->no-usable transition: NOT an intake event, nothing fired.
#   2. no-usable->usable transition: fires pi-intake@<repo>.service for
#      every enrolled repo (DRY_RUN prints the argv).
#   3. No transition (usable->usable): nothing fired.
#   4. Cooldown: a second transition within COOLDOWN secs does not re-fire.
#   5. Repos come from FLEET_SEAT_RECOVERY_REPOS when set.
#   6. Fires for every enrolled repo from intake-repos.json when no override.
#   7. systemctl mock records real invocations (not DRY).
#
# fleet-ops#622: the unit-shape + live wedge-recovery assertions live in the
# split file tests/fleet-seat-recovery-units.test.sh, invoked first below so
# they run independently of the bin-transition logic in this file (and before
# any pre-existing failure in the bin section can abort the run).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-seat-recovery"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# fleet-ops#622: run the unit-shape + wedge-recovery assertions first, in
# their own process, so a regression there is reported independently of the
# bin-transition checks below.
bash "$here/fleet-seat-recovery-units.test.sh"

# fleet-ops#2421: the ACTIVE come-back release path (re-probe + unwall of
# expired-wall seats) is the release half of seat recovery — hosted here so
# the P14 closure reaches it without a ci.yml edit (workers cannot touch
# .github/workflows/**). Runs in its own process (scratch ledger + stub pi).
bash "$here/fleet-seat-comeback-release.test.sh"

# fleet-ops#2469 + fleet-ops#2716: the PHYSICAL retirement path (move
# corpse ledgers out of lanes/seats/ into seats-corpse-retired-<ts>/). The
# release half (above) handles active un-walling; this handles terminal
# corpses that no probe can recover. Hosted alongside so the P14 closure
# reaches it without a ci.yml edit. Hermetic scenarios pin the threshold /
# quota_exhausted / Path C (credentials_bad→corpse grace) cases plus the
# prom metric shape.
bash "$here/fleet-seat-corpse-retire.test.sh"

[[ -f "$bin" ]] || fail "fleet-seat-recovery not found: $bin"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seatrecover.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Seat-lib needs a models.json + seat-caps.json. SINGLE provider so the
# only pick is devin/glm-5-2 — a second provider with no ledger file would
# fail-open as "usable" (no health data -> assumed usable) and mask the
# dead-seat verdict.
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "devin":  { "models": [ { "id": "glm-5-2", "cost": { "input": 0 } } ] }
  }
}
JSON
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["ollama"],
  "providers": {
    "devin":  { "cap": 2, "class": "subscription", "models": { "glm-5-2": 2 } }
  }
}
JSON

# Seat ledger: write one seat file per verdict.
ledger="$scratch/seats"
mkdir -p "$ledger"
dead_seat() {
  cat >"$ledger/devin__glm-5-2.json" <<'JSON'
{"provider":"devin","model":"glm-5-2","health_class":"quota_bench","seat_dead":false,"observed_at":"2026-08-27T00:00:00Z","bench_until":"2099-01-01T00:00:00Z"}
JSON
}
live_seat() {
  cat >"$ledger/devin__glm-5-2.json" <<'JSON'
{"provider":"devin","model":"glm-5-2","health_class":"healthy","seat_dead":false,"observed_at":"2026-08-27T00:00:00Z"}
JSON
}

state="$scratch/state.txt"
: > "$state"

# systemctl spy: logs each start.
sysctl_spy="$scratch/systemctl-spy.sh"
cat >"$sysctl_spy" <<'FAKE'
#!/usr/bin/env bash
echo "SYSTEMCTL $*" >> "$SYSTEMCTL_LOG"
exit 0
FAKE
chmod +x "$sysctl_spy"
SYSTEMCTL_LOG="$scratch/systemctl.log"
: > "$SYSTEMCTL_LOG"

run_bin() {
  local dry="$1" repos="$2" now="$3"
  set +e
  # Pin seat-lib to the in-repo copy. The bin prefers
  # ~/.local/lib/pi-packet/seat-lib.sh if it exists, which on this host
  # is a symlink to a different worktree's seat-lib and would silently
  # undo the FLEET_SEAT_RECOVERY_NOW pin (fleet-ops#735).
  PI_PACKET_SEAT_LIB="$repo_root/lib/seat-lib.sh" \
  # Isolate the active-seats registry (fleet-ops#739). seat-lib's
  # count_active_on_provider reads $PI_PACKET_STATE/active-seats to gate
  # the at-capacity skip in pick_seat. Without this pin the test reads the
  # HOST's real registry, so on a live VPS with active devin workers the
  # single fixture seat reads as at-capacity (cap=2, N active) and
  # any_seat_usable returns no-usable for a HEALTHY ledger — the
  # no-usable->usable transition never fires and test 2 trips
  # "missing SEAT-RECOVERY line". CI is clean (no workers) so this only
  # fails locally on a busy seat; the pin makes the test hermetic.
  PI_PACKET_STATE="$scratch/pi-packet-state" \
  PI_MODELS_JSON="$scratch/models.json" \
  SEAT_CAPS_JSON="$scratch/seat-caps.json" \
  PI_SEAT_HEALTH_LEDGER_DIR="$ledger" \
  FLEET_SEAT_LEDGER_DIR="$ledger" \
  FLEET_SEAT_RECOVERY_STATE="$state" \
  FLEET_SEAT_RECOVERY_COOLDOWN="120" \
  FLEET_SEAT_RECOVERY_REPOS="$repos" \
  FLEET_SEAT_RECOVERY_DRY_RUN="$dry" \
  FLEET_SEAT_RECOVERY_SYSTEMCTL="$sysctl_spy" \
  FLEET_SEAT_RECOVERY_NOW="$now" \
  SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    "$bin" >/dev/null 2>"$scratch/err.log"
  local rc=$?
  set -e
  echo "$rc"
}

# --- 1. usable -> no-usable is NOT an intake event ---------------------------
live_seat
rc=$(run_bin 1 "" "2026-08-27T00:00:00Z")   # first run: unknown -> usable
dead_seat
rc=$(run_bin 1 "" "2026-08-27T00:01:00Z")   # usable -> no-usable
[[ "$rc" == "0" ]] || fail "usable->no-usable should exit 0 (got $rc)"
grep -q "nothing to fire" "$scratch/err.log" || fail "missing nothing-to-fire log"
[[ ! -s "$SYSTEMCTL_LOG" ]] || fail "no systemctl call expected (DRY)"
ok "usable -> no-usable does not fire"

# --- 2. no-usable -> usable fires every repo (DRY shows argv) -----------------
live_seat
rc=$(run_bin 1 "repo-a repo-b" "2026-08-27T00:10:00Z")
[[ "$rc" == "0" ]] || fail "no-usable->usable should exit 0 (got $rc)"
grep -q "SEAT-RECOVERY" "$scratch/err.log" || fail "missing SEAT-RECOVERY line"
grep -q "would start pi-intake@repo-a.service" "$scratch/err.log" || fail "missing repo-a DRY line"
grep -q "would start pi-intake@repo-b.service" "$scratch/err.log" || fail "missing repo-b DRY line"
[[ ! -s "$SYSTEMCTL_LOG" ]] || fail "DRY must not invoke systemctl"
ok "no-usable -> usable fires all repos (DRY argv printed)"

# --- 3. no transition (usable -> usable) -> nothing --------------------------
rc=$(run_bin 1 "repo-a" "2026-08-27T00:11:00Z")
[[ "$rc" == "0" ]] || fail "usable->usable should exit 0 (got $rc)"
grep -q "nothing to fire" "$scratch/err.log" || fail "missing nothing-to-fire log"
ok "usable -> usable does not fire"

# --- 4. cooldown: second transition within 120s does not re-fire ------------
dead_seat
rc=$(run_bin 1 "repo-a" "2026-08-27T00:12:00Z")   # usable -> no-usable
live_seat
rc=$(run_bin 1 "repo-a" "2026-08-27T00:13:00Z")   # no-usable -> usable, 60s later
[[ "$rc" == "0" ]] || fail "cooldown skip should exit 0 (got $rc)"
grep -q "cooldown" "$scratch/err.log" || fail "missing cooldown log"
ok "transition within cooldown does not re-fire"

# --- 5. repos override via env -------------------------------------------------
# Wait past cooldown: use a NOW far in the future.
# First flip to no-usable, then to usable with the override repo list.
dead_seat
rc=$(run_bin 1 "only-repo" "2026-08-27T01:00:00Z")   # usable -> no-usable
live_seat
rc=$(run_bin 1 "only-repo" "2026-08-27T01:10:00Z")   # no-usable -> usable
[[ "$rc" == "0" ]] || fail "override fire should exit 0 (got $rc)"
grep -q "would start pi-intake@only-repo.service" "$scratch/err.log" || fail "missing override repo"
! grep -q "repo-a" "$scratch/err.log" || fail "override must replace default repos"
ok "FLEET_SEAT_RECOVERY_REPOS overrides the repo list"

# --- 6. enrolled repos from intake-repos.json (no override) -------------------
# Set a scratch intake-repos.json and clear the override.
intake="$scratch/intake-repos.json"
cat >"$intake" <<'JSON'
{"repos": [{"name": "nish/product-a"}, {"name": "nish/product-b"}]}
JSON
# Reset state so the next transition fires.
dead_seat
rc=$(run_bin 1 "" "2026-08-27T02:00:00Z")   # no-usable (first after reset: unknown -> no-usable)
live_seat
rc=$(FLEET_INTAKE_REPOS_JSON="$intake" run_bin 1 "" "2026-08-27T02:30:00Z")
[[ "$rc" == "0" ]] || fail "intake-repos fire should exit 0 (got $rc)"
grep -q "would start pi-intake@nish/product-a.service" "$scratch/err.log" || fail "missing product-a"
grep -q "would start pi-intake@nish/product-b.service" "$scratch/err.log" || fail "missing product-b"
ok "intake-repos.json drives the enrolled repo list"

# --- 7. real systemctl invocation (not DRY) ------------------------------------
: > "$SYSTEMCTL_LOG"
dead_seat
rc=$(run_bin 1 "" "2026-08-27T03:00:00Z")   # no-usable
live_seat
rc=$(run_bin 0 "real-repo" "2026-08-27T03:30:00Z")
[[ "$rc" == "0" ]] || fail "live fire should exit 0 (got $rc)"
grep -q "started pi-intake@real-repo.service" "$scratch/err.log" || fail "missing started log"
grep -q "SYSTEMCTL --user start pi-intake@real-repo.service" "$SYSTEMCTL_LOG" \
  || { cat "$SYSTEMCTL_LOG"; fail "systemctl spy not invoked with the right argv"; }
ok "live fire invokes systemctl start pi-intake@<repo>.service"

echo "OK: fleet-seat-recovery: transition fire, cooldown, repo list, live systemctl"
