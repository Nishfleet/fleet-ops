#!/usr/bin/env bash
# tests/fleet-heartbeat-verify-timers.test.sh
#
# fleet-ops#156 finding 9: heartbeat §5's verify_timers list must be derived
# from config/intake-repos.json `repos[]` (the same source the reconciler
# uses), not from a hand-maintained list in fleet-repos.json.
#
# This is a SHAPE lock: the fleet's enrolment source of truth is
# config/intake-repos.json. When a repo is added or removed there, the
# heartbeat must automatically verify its pi-scout@<repo>.timer and
# pi-intake@<repo>.timer on the next tick — no separate hand edit.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-heartbeat-tier1"
intake_json="$repo_root/config/intake-repos.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$intake_json" ]] || fail "missing: $intake_json"

# --- 1. Source path lock -----------------------------------------------------
# The script must reference the same intake config the reconciler uses and must
# not read a hand-maintained verify_timers field from fleet-repos.json.
grep -q 'FLEET_INTAKE_REPOS_JSON' "$bin" \
  || fail "fleet-heartbeat-tier1 must use FLEET_INTAKE_REPOS_JSON"
grep -q 'config/intake-repos.json' "$bin" \
  || fail "fleet-heartbeat-tier1 must point at config/intake-repos.json"
# The derivation must come from .repos[]?
grep -qF '.repos[]? |' "$bin" \
  || fail "fleet-heartbeat-tier1 must derive verify_timers from .repos[]?"
# Verify both timer unit patterns are produced.
grep -q 'pi-scout@' "$bin" \
  || fail "fleet-heartbeat-tier1 must generate pi-scout@<repo>.timer"
grep -q 'pi-intake@' "$bin" \
  || fail "fleet-heartbeat-tier1 must generate pi-intake@<repo>.timer"
# The old hand-maintained read from fleet-repos.json must be gone.
if grep -qF "jq -r '.verify_timers[]'" "$bin"; then
  fail "fleet-heartbeat-tier1 still reads .verify_timers[] from fleet-repos.json"
fi
ok "verify_timers source path + derivation expression locked"

# --- 2. Derivation output matches declared repo set --------------------------
# Create a scratch intake config with two repos and prove the jq filter that
# the script uses would produce the four expected timer units, in the declared
# order.
scratch="$(mktemp -d -t heartbeat-verify.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

cat >"$scratch/intake.json" <<'JSON'
{
  "repos": [
    {"name": "alpha"},
    {"name": "zulu"}
  ]
}
JSON

expected=$(printf 'pi-scout@alpha.timer\npi-intake@alpha.timer\npi-scout@zulu.timer\npi-intake@zulu.timer\n')
got=$(jq -r '.repos[]? | "pi-scout@\(.name).timer", "pi-intake@\(.name).timer"' "$scratch/intake.json")
[[ "$got" == "$expected" ]] \
  || fail "verify_timers derivation mismatch: got $(printf '%s' "$got" | tr '\n' ' '), expected $(printf '%s' "$expected" | tr '\n' ' ')"
ok "jq derivation produces two timer units per repo in declared order"

# --- 3. Live repo config verification ---------------------------------------
# The actual config/intake-repos.json must include all currently enrolled
# repos and the derivation must produce at least those units. We compare
# the declared set against the set of units the heartbeat would verify.
declared=$(jq -r '.repos[].name' "$intake_json" | LC_ALL=C sort)
units=$(jq -r '.repos[]? | "pi-scout@\(.name).timer", "pi-intake@\(.name).timer"' "$intake_json" | LC_ALL=C sort)
for repo in $declared; do
  printf '%s\n' "$units" | grep -qx "pi-scout@${repo}.timer" \
    || fail "missing pi-scout@$repo.timer in derived verify list"
  printf '%s\n' "$units" | grep -qx "pi-intake@${repo}.timer" \
    || fail "missing pi-intake@$repo.timer in derived verify list"
done
count=$(printf '%s\n' "$units" | wc -l)
[[ "$count" -eq $(( $(printf '%s\n' "$declared" | wc -l) * 2 )) ]] \
  || fail "verify list count mismatch (expected 2x repo count, got $count)"
ok "live intake-repos.json derives one scout and one intake timer per repo"

# --- 4. fleet-repos.json default no longer carries a hand-maintained list ----
# The default written when fleet-repos.json is missing must not contain a
# verify_timers key — the heartbeat now derives it from intake-repos.json.
default_block=$(awk '/cat > "\$REPOS_JSON"/,/^JSON$/' "$bin")
if printf '%s\n' "$default_block" | grep -q 'verify_timers'; then
  fail "default fleet-repos.json must not carry a hand-maintained verify_timers"
fi
ok "default fleet-repos.json has no verify_timers drift surface"

echo "OK: heartbeat verify_timers derived from intake-repos.json (fleet-ops#156 finding 9)"
