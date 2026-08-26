#!/usr/bin/env bash
# tests/fleet-heartbeat-blind-audit-trigger.test.sh
#
# fleet-ops#157 acceptance: "gap-board empty -> unit started + stamp;
# board non-empty -> no start; daily timer fires regardless; findings file
# -> N issues created ...". The audit unit itself (bin/fleet-blind-audit)
# is proven by tests/fleet-blind-audit.test.sh. This test pins the OTHER
# half of the trigger contract: the heartbeat tier1 §10 block that decides
# WHEN to start fleet-blind-audit.service.
#
# We do not run the full tick (it depends on gh + a live repo across 11
# sections). We:
#   Phase A: shape-lock the §10 wiring in fleet-heartbeat-tier1 (grep).
#   Phase B: reproduce the §10 decision predicate with a fake gh + fake
#            systemctl and prove every branch:
#              - gap-board empty + audit inactive -> start called + stamp
#              - gap-board non-empty              -> no start, no stamp
#              - audit active / activating        -> no-op (no start)
#              - FLEET_BLIND_AUDIT_DISABLE=1      -> no start
#              - start failure                    -> loud BLIND-AUDIT-START-FAIL
#   Phase C: the daily floor timer is independent of the heartbeat
#            (OnCalendar=*-*-*, Persistent=true) so the floor fires
#            regardless of gap-board state.
#   Then: fleet-ops#378 cadence + prove-one-run tests (same CI step).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
audit_bin="$repo_root/bin/fleet-blind-audit"
timer="$repo_root/systemd/fleet-blind-audit.timer"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tier1" ]] || fail "missing: $tier1"
[[ -x "$audit_bin" ]] || fail "missing: $audit_bin"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# ============================================================================
# Phase A: shape-lock the §10 wiring in fleet-heartbeat-tier1
# ============================================================================
# The gap-board count must come from gh issue list with the gap-audit label,
# state open. Pin the exact call so a future edit cannot silently change the
# trigger source.
grep -F -- 'gh issue list -R Nishfleet/fleet-ops -l gap-audit --state open' "$tier1" >/dev/null \
    || fail "tier1 §10 must count open gap-audit issues via gh issue list -l gap-audit --state open"
grep -F -- '--json number --jq length' "$tier1" >/dev/null \
    || fail "tier1 §10 must count issues with --json number --jq length"
ok "A: gap-board count source locked (gh issue list -l gap-audit --state open)"

# Empty board -> start the audit unit. Pin the start call.
grep -F -- 'systemctl --user start fleet-blind-audit.service' "$tier1" >/dev/null \
    || fail "tier1 §10 must start fleet-blind-audit.service when the gap-board is empty"
# Active/activating -> no-op (one audit at a time; a running audit blocks
# re-trigger via the unit itself, not a hand-built lock).
grep -F -- 'systemctl --user is-active fleet-blind-audit.service' "$tier1" >/dev/null \
    || fail "tier1 §10 must check is-active before starting (one audit at a time)"
grep -F -- 'fleet-blind-audit.service is $audit_state — no-op' "$tier1" >/dev/null \
    || fail "tier1 §10 must no-op when the audit unit is active/activating"
ok "A: empty -> start; active/activating -> no-op (one at a time via the unit)"

# Stamp + disable guard + fail-loud.
grep -F -- 'last-blind-audit-dispatch:' "$tier1" >/dev/null \
    || fail "tier1 §10 must stamp last-blind-audit-dispatch: in the plan file"
grep -F -- 'FLEET_BLIND_AUDIT_DISABLE' "$tier1" >/dev/null \
    || fail "tier1 §10 must honour FLEET_BLIND_AUDIT_DISABLE=1"
grep -F -- 'loud "BLIND-AUDIT-START-FAIL"' "$tier1" >/dev/null \
    || fail "tier1 §10 must fail loud (BLIND-AUDIT-START-FAIL) when start fails"
ok "A: stamp + disable guard + fail-loud on start failure locked"

# ============================================================================
# Phase B: reproduce the §10 decision predicate with fakes
# ============================================================================
# We re-implement the exact §10 decision (same gh + systemctl calls, same
# branches) and drive it with fakes. This proves the predicate behaves
# correctly without depending on a live repo or the other 10 tier1 sections.
scratch="$(mktemp -d -t blind-trigger.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

calls="$scratch/calls.log"
: >"$calls"
triage="$scratch/triage.md"
: >"$triage"
plan="$scratch/plan.md"
printf 'last-heartbeat: 2026-08-26T05:43:00Z (durable-timer)\n' >"$plan"

# Put the fake gh + systemctl on PATH so the reproducer's bare `gh` /
# `systemctl` calls resolve to them.
export PATH="$scratch:$PATH"

# Fake gh: `issue list -l gap-audit --state open` returns $GAPS_JSON length.
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*gap-audit*)
    jq 'length' "${GAPS_JSON:-/dev/null}" 2>/dev/null || echo 0
    exit 0
    ;;
  *)
    # tier1 §10 only calls the gap-audit list; any other gh call is a bug
    # in the reproducer.
    echo "unexpected gh call: $*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$gh_fake"

# Fake systemctl: is-active reads $AUDIT_STATE; start appends to $CALLS and
# honours $START_RC (0 success, non-zero failure).
systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
shift  # --user
cmd="$1"; shift
case "$cmd" in
  is-active)
    echo "${AUDIT_STATE:-inactive}"
    exit 0
    ;;
  start)
    printf 'start %s\n' "$1" >>"${CALLS:-/dev/null}"
    exit "${START_RC:-0}"
    ;;
  *)
    echo "unexpected systemctl call: $cmd $*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$systemctl_fake"

# The §10 decision predicate, lifted verbatim in shape from tier1.
run_section10() {
    if [ "${FLEET_BLIND_AUDIT_DISABLE:-0}" = "1" ]; then
        return 0
    fi
    n_gaps=$(gh issue list -R Nishfleet/fleet-ops -l gap-audit --state open \
        --json number --jq length 2>/dev/null || echo 999)
    if [ "$n_gaps" -eq 0 ] 2>/dev/null; then
        audit_state=$(systemctl --user is-active fleet-blind-audit.service 2>/dev/null || echo "unknown")
        case "$audit_state" in
            active|activating)
                return 0
                ;;
            *)
                if systemctl --user start fleet-blind-audit.service 2>/dev/null; then
                    new_ts="2026-08-26T06:20:00Z"
                    python3 - "$plan" "$new_ts" <<'PY'
import sys, re
path, ts = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as f:
    lines = f.readlines()
new, hit = [], False
for ln in lines:
    if not hit and re.match(r'^last-blind-audit-dispatch:', ln):
        new.append(f'last-blind-audit-dispatch: {ts} (heartbeat)\n')
        hit = True
    else:
        new.append(ln)
if not hit:
    if new and not new[-1].endswith('\n'):
        new.append('\n')
    new.append(f'\nlast-blind-audit-dispatch: {ts} (heartbeat)\n')
with open(path, 'w', encoding='utf-8') as f:
    f.writelines(new)
PY
                else
                    printf '[%s] [BLIND-AUDIT-START-FAIL] systemctl start fleet-blind-audit.service failed\n' \
                        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$triage"
                fi
                ;;
        esac
    fi
    return 0
}

count_starts() { local n; n=$(grep -c '^start fleet-blind-audit.service' "$calls" 2>/dev/null || true); echo "${n:-0}"; }
has_stamp()    { grep -qE '^last-blind-audit-dispatch:' "$plan" 2>/dev/null; }
has_loud()     { grep -q 'BLIND-AUDIT-START-FAIL' "$triage" 2>/dev/null; }

# --- B1: gap-board empty + inactive -> start + stamp -------------------------
GAPS_JSON="$scratch/empty.json" printf '[]' >"$scratch/empty.json"
export GAPS_JSON="$scratch/empty.json"
export CALLS="$calls"
AUDIT_STATE=inactive START_RC=0 run_section10
[[ "$(count_starts)" == "1" ]] || fail "B1: empty+inactive must start once, got $(count_starts)"
has_stamp || fail "B1: empty+inactive must stamp last-blind-audit-dispatch"
ok "B1: gap-board empty + inactive -> start + stamp"

# --- B2: gap-board non-empty -> no start, no stamp --------------------------
: >"$calls"
printf 'last-heartbeat: 2026-08-26T05:43:00Z (durable-timer)\n' >"$plan"
GAPS_JSON="$scratch/two.json" printf '[{"number":1},{"number":2}]' >"$scratch/two.json"
export GAPS_JSON="$scratch/two.json"
AUDIT_STATE=inactive START_RC=0 run_section10
[[ "$(count_starts)" == "0" ]] || fail "B2: non-empty board must NOT start, got $(count_starts)"
has_stamp && fail "B2: non-empty board must NOT stamp"
ok "B2: gap-board non-empty -> no start, no stamp"

# --- B3: audit active -> no-op (no start) -----------------------------------
: >"$calls"
printf 'last-heartbeat: 2026-08-26T05:43:00Z (durable-timer)\n' >"$plan"
export GAPS_JSON="$scratch/empty.json"
AUDIT_STATE=active START_RC=0 run_section10
[[ "$(count_starts)" == "0" ]] || fail "B3: active audit must NOT start a second, got $(count_starts)"
has_stamp && fail "B3: active audit must NOT stamp"
ok "B3: audit active -> no-op (one audit at a time)"

# --- B3b: audit activating -> no-op -----------------------------------------
: >"$calls"
AUDIT_STATE=activating START_RC=0 run_section10
[[ "$(count_starts)" == "0" ]] || fail "B3b: activating audit must NOT start a second, got $(count_starts)"
ok "B3b: audit activating -> no-op"

# --- B4: FLEET_BLIND_AUDIT_DISABLE=1 -> no start ----------------------------
: >"$calls"
export GAPS_JSON="$scratch/empty.json"
AUDIT_STATE=inactive START_RC=0 FLEET_BLIND_AUDIT_DISABLE=1 run_section10
[[ "$(count_starts)" == "0" ]] || fail "B4: disabled flag must prevent start, got $(count_starts)"
ok "B4: FLEET_BLIND_AUDIT_DISABLE=1 -> no start"

# --- B5: start failure -> loud BLIND-AUDIT-START-FAIL -----------------------
: >"$calls"
: >"$triage"
printf 'last-heartbeat: 2026-08-26T05:43:00Z (durable-timer)\n' >"$plan"
export GAPS_JSON="$scratch/empty.json"
AUDIT_STATE=inactive START_RC=1 run_section10
[[ "$(count_starts)" == "1" ]] || fail "B5: start must still be attempted on failure path, got $(count_starts)"
has_loud || fail "B5: start failure must emit BLIND-AUDIT-START-FAIL to triage"
ok "B5: start failure -> loud BLIND-AUDIT-START-FAIL"

# ============================================================================
# Phase C: the daily floor timer is independent of the heartbeat (#378)
# ============================================================================
# fleet-ops#378: weekly was structurally defeated because the gap-board held
# 70+ open issues and rarely drained, so the only practical trigger was the
# weekly timer. That meant a broken audit could sit unnoticed for up to a
# week. The floor is now daily; the drainage dispatch in tier1 §10 stays as
# a bonus. The cadence-overdue canary in tier1 §11 makes a stuck audit scream.
[[ -f "$timer" ]] || fail "missing daily floor timer: $timer"
grep -F -- 'OnCalendar=*-*-*' "$timer" >/dev/null \
    || fail "fleet-blind-audit.timer must have OnCalendar=*-*-* (daily floor, not weekly)"
grep -F -- 'Persistent=true' "$timer" >/dev/null \
    || fail "fleet-blind-audit.timer must be Persistent=true (survives downtime)"
# The timer must NOT gate on live state — it is the unconditional floor. A
# Condition*= or ExecCondition= directive tying it to gap-board state would
# make the floor conditional. Comments may mention the gap-board (they
# explain the design); only active directives are checked here.
if grep -qE '^[[:space:]]*(Condition|ExecCondition)' "$timer"; then
    fail "fleet-blind-audit.timer must not carry a Condition*/ExecCondition* directive (the floor is unconditional)"
fi
ok "C: daily floor timer fires regardless of gap-board state (OnCalendar=*-*-*, Persistent=true, no state gate)"

# fleet-ops#378: cadence canary + prove-one-run live in this CI step
# (ci.yml already runs this file; nishfleet-worker cannot add a new
# verify-command line because that is a workflow edit).
bash "$here/fleet-heartbeat-blind-audit-cadence.test.sh"
bash "$here/prove-one-run-check.test.sh"
# fleet-ops#517: new bin/ files need a research: line (same CI step).
bash "$here/research-before-build-check.test.sh"
# fleet-ops#368: stale-host Telegram page literals (blind-audit rank 2).
bash "$here/fleet-heartbeat-failed-notify-shape.test.sh"

echo "all phases passed"
