#!/usr/bin/env bash
# tests/fleet-heartbeat-rc-propagation.test.sh
#
# fleet-ops#486: fleet-heartbeat logged `tier 1: FAILED (rc=0)` on every
# real tier1 failure. Cause: `if ! "$TIER1"; then rc=$?` — `!` inverts the
# status so the then-branch always sees 0. The unit still exited 1
# (hb_finish 1), so systemd went red, but the log lied and the child's
# real rc (1 vs 2 vs 7) was discarded.
#
# Class lock:
#   A. A stub TIER1 that exits 7 must log FAILED (rc=7) and the wrapper
#      must exit 7 (not 0, not a collapsed 1, not a logged 0).
#   B. A stub TIER1 that exits 0 must log `tier 1: done` and exit 0.
#   C. A stub TIER2 that exits 3 (after a needs-judgment triage line)
#      must log rc=3 and the wrapper must exit 3.
#   D. Source gate: bin/fleet-heartbeat must not capture $? immediately
#      after `if !`. A planted fixture of that shape MUST be rejected
#      (fleet-ops#366: the guard has to fire, not just exist).
# Nested under tests/seat-lib.test.sh because workers cannot add a
# .github/workflows/ci.yml line.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
hb="$repo_root/bin/fleet-heartbeat"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$hb" ]] || fail "not executable: $hb"

scratch="$(mktemp -d -t hb-rc-prop.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

plan="$scratch/plan.md"
printf 'last-heartbeat: 2000-01-01T00:00:00Z (durable-timer)\n' >"$plan"
triage="$scratch/triage.md"
: >"$triage"
prompt="$scratch/prompt.md"
printf 'heartbeat prompt fixture\n' >"$prompt"
logs="$scratch/logs"
mkdir -p "$logs"

tier1_ok="$scratch/tier1-ok"
printf '#!/bin/sh\nexit 0\n' >"$tier1_ok"
chmod +x "$tier1_ok"

tier1_seven="$scratch/tier1-seven"
printf '#!/bin/sh\nexit 7\n' >"$tier1_seven"
chmod +x "$tier1_seven"

tier2_three="$scratch/tier2-three"
printf '#!/bin/sh\nexit 3\n' >"$tier2_three"
chmod +x "$tier2_three"

tier2_ok="$scratch/tier2-ok"
printf '#!/bin/sh\nexit 0\n' >"$tier2_ok"
chmod +x "$tier2_ok"

run_hb() {
  FLEET_PLAN_FILE="$plan" \
  FLEET_HEARTBEAT_TIER1="$1" \
  FLEET_HEARTBEAT_TIER2="$2" \
  FLEET_HEARTBEAT_PROMPT="$prompt" \
  FLEET_HEARTBEAT_TRIAGE="$triage" \
  FLEET_HEARTBEAT_LOG_DIR="$logs" \
  FLEET_HEARTBEAT_WATCHMAN="$scratch/no-such-watchman.sh" \
    "$hb"
}

# --- A. non-zero TIER1 rc must survive into the log and the wrapper exit ----
set +e
out="$(run_hb "$tier1_seven" "$tier2_ok" 2>&1)"
rc=$?
set -e
[[ "$rc" == "7" ]] || fail "A: wrapper must exit 7 when TIER1 exits 7, got $rc ($out)"
printf '%s\n' "$out" | grep -q 'tier 1: FAILED (rc=7)' \
  || fail "A: log must say FAILED (rc=7), not rc=0. got: $out"
printf '%s\n' "$out" | grep -q 'FAILED (rc=0)' \
  && fail "A: inverted capture still logs FAILED (rc=0): $out"
ok "A: TIER1 exit 7 -> log rc=7, wrapper exit 7"

# --- B. TIER1 success stays green -------------------------------------------
: >"$triage"
set +e
out="$(run_hb "$tier1_ok" "$tier2_ok" 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "B: wrapper must exit 0 when TIER1 exits 0, got $rc ($out)"
printf '%s\n' "$out" | grep -q 'tier 1: done' \
  || fail "B: log must say tier 1: done, got: $out"
printf '%s\n' "$out" | grep -q 'FAILED' \
  && fail "B: success path must not log FAILED: $out"
ok "B: TIER1 exit 0 -> done, wrapper exit 0"

# --- C. TIER2 non-zero rc must survive --------------------------------------
printf '[ORPHAN] fixture-needs-judgment\n' >"$triage"
set +e
out="$(run_hb "$tier1_ok" "$tier2_three" 2>&1)"
rc=$?
set -e
[[ "$rc" == "3" ]] || fail "C: wrapper must exit 3 when TIER2 exits 3, got $rc ($out)"
printf '%s\n' "$out" | grep -q 'tier 2: all seats exhausted (rc=3)' \
  || fail "C: log must say exhausted (rc=3), got: $out"
ok "C: TIER2 exit 3 -> log rc=3, wrapper exit 3"

# --- D. source gate + drill (fleet-ops#366) ---------------------------------
# Scope is the heartbeat wrappers this issue owns. The same inversion in
# other bins is a follow-up, not a silent ignore.
scan_inverted() {
  python3 - "$@" <<'PY'
import re, sys
from pathlib import Path

def has_inverted_capture(path: Path) -> bool:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return False
    for i, line in enumerate(lines):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        if not re.match(r"if[ \t]+!.+then[ \t]*$", stripped):
            continue
        j = i + 1
        while j < len(lines) and (not lines[j].strip() or lines[j].lstrip().startswith("#")):
            j += 1
        if j >= len(lines):
            continue
        nxt = lines[j].lstrip()
        if re.match(r"\w+=\$\?[ \t]*$", nxt):
            return True
    return False

hits = []
for arg in sys.argv[1:]:
    path = Path(arg)
    if path.is_dir():
        for child in sorted(path.rglob("*")):
            if child.is_file() and has_inverted_capture(child):
                hits.append(str(child))
    elif path.is_file() and has_inverted_capture(path):
        hits.append(str(path))
if hits:
    print("\n".join(hits))
    sys.exit(1)
sys.exit(0)
PY
}

set +e
scan_out="$(scan_inverted \
  "$repo_root/bin/fleet-heartbeat" \
  "$repo_root/bin/fleet-heartbeat-tier1" \
  "$repo_root/bin/fleet-heartbeat-tier2" 2>&1)"
scan_rc=$?
set -e
[[ "$scan_rc" == "0" ]] || fail "D: inverted if-! / rc=\$? capture still in heartbeat wrappers: $scan_out"
ok "D: heartbeat wrappers have no if-! then rc=\$? capture"

drill="$scratch/drill"
mkdir -p "$drill"
cat >"$drill/bad.sh" <<'SH'
#!/usr/bin/env bash
if ! "$TIER1"; then
    rc=$?
    echo "FAILED (rc=$rc)"
fi
SH
set +e
drill_out="$(scan_inverted "$drill" 2>&1)"
drill_rc=$?
set -e
[[ "$drill_rc" != "0" ]] || fail "D: drill planted if-! then rc=\$? and the scanner stayed quiet"
ok "D: drill: planted inverted capture is rejected"

# --- E. alarm (rc=1) vs crash (rc>=2) (fleet-ops#1156) ----------------------
# Live hot-patch: detector findings (rc=1) stay loud but must not fail the
# unit. Helper crashes (rc>=2) still propagate. Extract the live function
# so this drill dies if the helper is renamed or its contract changes.
tier1="$repo_root/bin/fleet-heartbeat-tier1"
[[ -x "$tier1" ]] || fail "E: not executable: $tier1"
prop_src=$(awk '
  /^_propagate_crash\(\)/ {grab=1}
  grab {print}
  grab && /^}/ {exit}
' "$tier1")
[[ -n "$prop_src" ]] || fail "E: _propagate_crash missing from bin/fleet-heartbeat-tier1"
eval "$prop_src"
run_prop() {
  eval "$1=$2"
  set +e
  _propagate_crash "$1"
  local got=$?
  set -e
  [[ "$got" == "$3" ]] || fail "E: $1=$2 must return $3, got $got"
}
run_prop deploy_rc 0 0
run_prop deploy_rc 1 0
run_prop deploy_rc 2 2
run_prop canary_rc 7 7
ok "E: _propagate_crash swallows rc=1, forwards rc>=2"

# --- F. every captured *_rc is crash-propagated, old if-chain gone ---------
python3 - "$tier1" <<'PY' || fail "F: crash-propagation source gate failed"
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
if "if [ \"$deploy_rc\" -ne 0 ]; then" in text:
    print("old deploy_rc fail-loud if-chain still present")
    sys.exit(1)
# Tail after the final complete-log is the only propagation site.
tail = text.rsplit('log "tier 1 complete:', 1)[-1]
missing = []
for name in re.findall(r"\b([a-z0-9_]+_rc)=", text.split('log "tier 1 complete:', 1)[-1].splitlines()[0]):
    if f"_propagate_crash {name}" not in tail:
        missing.append(name)
if missing:
    print("missing _propagate_crash for: " + ", ".join(missing))
    sys.exit(1)
sys.exit(0)
PY
ok "F: every logged *_rc has _propagate_crash; old if-chain gone"

# Nested CI host (workers cannot add a ci.yml line).
grep -Fq 'bash "$here/fleet-heartbeat-rc-propagation.test.sh"' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "nested under seat-lib.test.sh"

echo "ALL OK"
