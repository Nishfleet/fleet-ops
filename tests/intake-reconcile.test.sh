#!/usr/bin/env bash
# tests/intake-reconcile.test.sh
#
# Proves the intake reconciler (fleet-ops#32) converges systemd state to
# config/intake-repos.json — entirely offline with mocked systemctl + gh.
# The hard rule from the issue: workers implementing this MUST NEVER
# exercise systemd state on the live user manager; tests run against a
# stubbed systemctl (this file); live convergence happens only via the
# installed unit after merge.
#
# What we prove:
#   1. Enrolled repos with passing preconditions get their pi-intake +
#      pi-scout timers enabled AND started, with an audit log line per
#      state change naming actor=reconciler.
#   2. Enrolled repos failing the checkout precondition get their units
#      DISABLED (not silently no-op'd) and a loud alert written to the
#      triage file naming the missing precondition.
#   3. Enrolled repos failing the labels precondition get the same
#      disable + loud treatment.
#   4. Deferred repos get their units disabled; re-enrolment is a PR,
#      never a sweep decision.
#   5. Permanently-excluded repos (fleet2) get disabled + loud; the
#      reconciler does NOT auto-mask an operator's intentional state.
#   6. A unit that IS masked is left masked and logged loud — the
#      silent-mutation defect this issue was filed for. No auto-unmask.
#   7. UNDECLARED repos with live units (drift) get disabled + a
#      LOUD INTAKE-UNDECLARED line; the file is the source of truth.
#   8. Already-converged state is a no-op (idempotent): no extra audit
#      lines, no extra systemctl calls.
#   9. Every audit line carries timestamp + unit + action + actor=reconciler
#      + a why= token. The grep is the missing record that made the
#      2026-08-25/26 reversions undiagnosable.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/intake-reconcile"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# --- scratch environment ----------------------------------------------------
scratch="$(mktemp -d -t intake-reconcile.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
mkdir -p "$scratch/products"

intake_json="$scratch/intake-repos.json"
audit_log="$scratch/audit.log"
triage="$scratch/triage.md"
: >"$triage"
mkdir -p "$scratch/checkout_root"
# Used in the intake-repos.json heredoc below. Single-quoted heredocs would
# literalise the value, but the bin needs a real path so checkout_exists()
# can find it (or fail to find it on purpose for scenario 2).
CHECKOUT_ROOT="$scratch/checkout_root"

# --- fake gh ----------------------------------------------------------------
# Driven by $LABEL_FILE: one label name per line.
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"label list"*)
    if [[ -f "${LABEL_FILE:-/dev/null}" ]]; then
      cat "$LABEL_FILE"
    else
      printf 'agent-ready\nagent-in-progress\nagent-blocked\n'
    fi
    exit 0
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$gh_fake"

# --- fake systemctl ---------------------------------------------------------
# Behavior driven by state files:
#   $UNIT_FILES          one <unit> <state> per line (state ∈ enabled, disabled,
#                        static, masked, generated, transient, bad).
#   $UNIT_ACTIVE         one <unit> per line (active/activating pi-*-timers).
#   $UNIT_MASKED         one <unit> per line (currently masked units).
# Mutating calls (enable, disable, start, stop) append to $CALLS.
systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
shift  # consume --user
cmd="$1"; shift

emit_unit_state() {
    local unit="$1"
    if [[ -f "${UNIT_FILES:-/dev/null}" ]]; then
        awk -v u="$unit" '$1 == u { print $2; exit }' "$UNIT_FILES"
    fi
}

is_active_in_set() {
    local unit="$1"
    [[ -f "${UNIT_ACTIVE:-/dev/null}" ]] \
        && grep -qxF "$unit" "${UNIT_ACTIVE:-/dev/null}" 2>/dev/null
}

case "$cmd" in
    list-unit-files)
        # Emit "<unit> <state>" lines for the templates' instances that
        # are tracked in UNIT_FILES. The reconciler filters to pi-intake@* +
        # pi-scout@*; we mirror that filter so the live_repos computation
        # only sees the right units.
        if [[ -f "${UNIT_FILES:-/dev/null}" ]]; then
            awk '$1 ~ /^pi-(intake|scout)@[^\.]+\.timer$/ { print $1, $2 }' \
                "$UNIT_FILES"
        fi
        exit 0
        ;;
    is-enabled)
        unit="$1"; quiet=""
        [[ "$1" == "--quiet" ]] && { quiet=1; unit="$2"; }
        s="$(emit_unit_state "$unit")"
        case "$s" in
            enabled|enabled-runtime|alias|static|generated|indirect|transient)
                [[ -n "$quiet" ]] || echo "$s"
                exit 0
                ;;
            masked)
                [[ -n "$quiet" ]] || echo "masked"
                exit 1   # is-enabled returns 1 for masked; is-enabled --quiet echoes nothing AND exits 1
                ;;
            disabled|"")
                [[ -n "$quiet" ]] || echo "disabled"
                exit 1
                ;;
            *)
                [[ -n "$quiet" ]] || echo "$s"
                exit 0
                ;;
        esac
        ;;
    is-active)
        unit="$1"; quiet=""
        [[ "$1" == "--quiet" ]] && { quiet=1; unit="$2"; }
        if is_active_in_set "$unit"; then
            [[ -n "$quiet" ]] || echo "active"
            exit 0
        else
            [[ -n "$quiet" ]] || echo "inactive"
            exit 3
        fi
        ;;
    enable)
        # Filter --now from the arg list. The remaining last token is the
        # unit name (reconciler uses `systemctl --user enable --now UNIT`).
        # Note: even with --now, the fake does NOT mark the unit active —
        # the reconciler calls `start` separately after enable, and the
        # test asserts BOTH calls. Marking active here would let `start`
        # become a no-op and break the scenario.
        unit=""
        for a in "$@"; do
            case "$a" in --now) ;; *) unit="$a" ;; esac
        done
        printf 'enable %s\n' "$unit" >>"${CALLS:-/dev/null}"
        # Update UNIT_FILES only.
        if [[ -f "${UNIT_FILES:-/dev/null}" ]]; then
            tmp="$(mktemp)"
            awk -v u="$unit" '$1 == u { print $1, "enabled"; next } { print }' \
                "$UNIT_FILES" >"$tmp" && mv "$tmp" "$UNIT_FILES"
        fi
        exit 0
        ;;
    start)
        unit="$1"
        printf 'start %s\n' "$unit" >>"${CALLS:-/dev/null}"
        if [[ -f "${UNIT_ACTIVE:-/dev/null}" ]]; then
            grep -qxF "$unit" "${UNIT_ACTIVE:-/dev/null}" \
                || printf '%s\n' "$unit" >>"$UNIT_ACTIVE"
        fi
        exit 0
        ;;
    disable)
        unit=""
        for a in "$@"; do
            case "$a" in --now) ;; *) unit="$a" ;; esac
        done
        printf 'disable %s\n' "$unit" >>"${CALLS:-/dev/null}"
        if [[ -f "${UNIT_FILES:-/dev/null}" ]]; then
            tmp="$(mktemp)"
            awk -v u="$unit" '$1 == u { print $1, "disabled"; next } { print }' \
                "$UNIT_FILES" >"$tmp" && mv "$tmp" "$UNIT_FILES"
        fi
        if [[ -f "${UNIT_ACTIVE:-/dev/null}" ]]; then
            tmp="$(mktemp)"
            grep -vxF "$unit" "${UNIT_ACTIVE:-/dev/null}" >"$tmp" \
                && mv "$tmp" "${UNIT_ACTIVE:-/dev/null}"
        fi
        exit 0
        ;;
    *)
        printf 'unexpected systemctl call: %s %s\n' "$cmd" "$*" >&2
        exit 1
        ;;
esac
FAKE
chmod +x "$systemctl_fake"

# --- helper: run reconciler with the fakes wired in -------------------------
# Note on bash quoting: env-var prefixes attach to a *simple* command, not
# to an assignment whose RHS is a command substitution. So we wrap the
# whole "set env + invoke bin" into a single env command via `bash -c`
# and capture its combined output. This is what makes the env overrides
# actually reach the bin, instead of being silently swallowed as plain
# shell assignments.
run_reconcile() {
    set +e
    env_out=$(
        INTAKE_RECONCILE_SYSTEMCTL="$systemctl_fake" \
        INTAKE_RECONCILE_GH="$gh_fake" \
        INTAKE_RECONCILE_INTAKE_JSON="$1" \
        INTAKE_RECONCILE_AUDIT_LOG="$audit_log" \
        INTAKE_RECONCILE_TRIAGE="$triage" \
        INTAKE_RECONCILE_NOW="2026-08-26T02:00:00Z" \
        "$bin" 2>&1
    )
    env_rc=$?
    set -e
}

reset_world() {
    : >"$triage"
    : >"$audit_log"
    : >"${CALLS:=$scratch/calls.log}"
    : >"${UNIT_FILES:=$scratch/unit_files}"
    : >"${UNIT_ACTIVE:=$scratch/unit_active}"
    : >"${LABEL_FILE:=$scratch/labels}"
    rm -rf "$scratch/checkout_root"/*
    mkdir -p "$scratch/checkout_root"
}

export CALLS UNIT_FILES UNIT_ACTIVE LABEL_FILE

# ============================================================================
# Scenario 1: enrolled repo with passing preconditions → enable + start
# ============================================================================
reset_world
cat >"$intake_json" <<JSON
{
  "checkout_root": "$CHECKOUT_ROOT",
  "required_labels": ["agent-ready","agent-in-progress","agent-blocked"],
  "repos": [{ "name": "demo" }],
  "excluded": [],
  "deferred": []
}
JSON
mkdir -p "$scratch/checkout_root/demo"
printf 'agent-ready\nagent-in-progress\nagent-blocked\n' >"$LABEL_FILE"
: >"$UNIT_FILES"
: >"$UNIT_ACTIVE"

run_reconcile "$intake_json"
[[ "$env_rc" == 0 ]] || fail "scenario1: clean converge must exit 0, got $env_rc ($env_out)"

# Two enable + two start calls (one each for intake-timer + scout-timer).
grep -qx 'enable pi-intake@demo.timer' "$CALLS" \
    || fail "scenario1: enable pi-intake@demo.timer missing ($(cat "$CALLS"))"
grep -qx 'enable pi-scout@demo.timer' "$CALLS" \
    || fail "scenario1: enable pi-scout@demo.timer missing"
grep -qx 'start pi-intake@demo.timer' "$CALLS" \
    || fail "scenario1: start pi-intake@demo.timer missing"
grep -qx 'start pi-scout@demo.timer' "$CALLS" \
    || fail "scenario1: start pi-scout@demo.timer missing"
# Audit log carries actor=reconciler + why for each.
grep -q 'pi-intake@demo.timer enable actor=reconciler why=declared-enrolled:declared-in-repos' "$audit_log" \
    || fail "scenario1: audit line missing for intake enable ($(cat "$audit_log"))"
grep -q 'pi-scout@demo.timer enable actor=reconciler why=declared-enrolled:declared-in-repos' "$audit_log" \
    || fail "scenario1: audit line missing for scout enable"
ok "scenario1: enrolled repo with passing preconditions → enable+start, audit line per state change"

# Idempotence: re-run with already-enabled state.
calls_before=$(wc -l <"$CALLS")
audit_before=$(wc -l <"$audit_log")
# Mark the units enabled+active so the second run is a no-op.
printf 'pi-intake@demo.timer enabled\npi-scout@demo.timer enabled\n' >>"$UNIT_FILES"
printf 'pi-intake@demo.timer\npi-scout@demo.timer\n' >>"$UNIT_ACTIVE"
run_reconcile "$intake_json"
[[ "$env_rc" == 0 ]] || fail "scenario1 idempotent: must exit 0"
calls_after=$(wc -l <"$CALLS")
audit_after=$(wc -l <"$audit_log")
[[ "$calls_before" == "$calls_after" ]] \
    || fail "scenario1 idempotent: extra systemctl calls ($calls_before → $calls_after): $(cat "$CALLS")"
[[ "$audit_before" == "$audit_after" ]] \
    || fail "scenario1 idempotent: extra audit lines ($audit_before → $audit_after): $(cat "$audit_log")"
ok "scenario1 idempotent: already-converged state is a no-op"

# ============================================================================
# Scenario 2: enrolled repo missing checkout → DISABLE + LOUD
# ============================================================================
reset_world
cat >"$intake_json" <<JSON
{
  "checkout_root": "$CHECKOUT_ROOT",
  "required_labels": ["agent-ready","agent-in-progress","agent-blocked"],
  "repos": [{ "name": "demo" }],
  "excluded": [],
  "deferred": []
}
JSON
# No checkout_root/demo dir → precondition fails on (a).
printf 'agent-ready\nagent-in-progress\nagent-blocked\n' >"$LABEL_FILE"
printf 'pi-intake@demo.timer enabled\npi-scout@demo.timer enabled\n' >"$UNIT_FILES"
printf 'pi-intake@demo.timer\npi-scout@demo.timer\n' >>"$UNIT_ACTIVE"

run_reconcile "$intake_json"
[[ "$env_rc" == 0 ]] || fail "scenario2: must exit 0 (drift is recoverable), got $env_rc ($env_out)"
grep -qx 'disable pi-intake@demo.timer' "$CALLS" \
    || fail "scenario2: disable pi-intake@demo.timer missing: $(cat "$CALLS")"
grep -qx 'disable pi-scout@demo.timer' "$CALLS" \
    || fail "scenario2: disable pi-scout@demo.timer missing"
grep -q 'pi-intake@demo.timer disable actor=reconciler why=precondition-fail:checkout-missing' "$audit_log" \
    || fail "scenario2: audit line names the precondition: $(cat "$audit_log")"
grep -q 'INTAKE-PRECOND-FAIL' "$triage" \
    || fail "scenario2: triage must record LOUD INTAKE-PRECOND-FAIL: $(cat "$triage")"
grep -q 'demo: preconditions failed' "$triage" \
    || fail "scenario2: triage must name the failed repo: $(cat "$triage")"
ok "scenario2: missing checkout → disable + LOUD INTAKE-PRECOND-FAIL"

# ============================================================================
# Scenario 3: enrolled repo missing labels → DISABLE + LOUD
# ============================================================================
reset_world
cat >"$intake_json" <<JSON
{
  "checkout_root": "$CHECKOUT_ROOT",
  "required_labels": ["agent-ready","agent-in-progress","agent-blocked"],
  "repos": [{ "name": "demo" }],
  "excluded": [],
  "deferred": []
}
JSON
mkdir -p "$scratch/checkout_root/demo"
# Repo has only 2 of 3 required labels.
printf 'agent-ready\nagent-in-progress\n' >"$LABEL_FILE"
printf 'pi-intake@demo.timer enabled\n' >"$UNIT_FILES"
printf 'pi-intake@demo.timer\n' >"$UNIT_ACTIVE"

run_reconcile "$intake_json"
grep -qx 'disable pi-intake@demo.timer' "$CALLS" \
    || fail "scenario3: must disable when labels missing: $(cat "$CALLS")"
grep -q 'INTAKE-PRECOND-FAIL' "$triage" \
    || fail "scenario3: triage must record LOUD INTAKE-PRECOND-FAIL: $(cat "$triage")"
grep -q 'repo-missing-labels' "$audit_log" \
    || fail "scenario3: audit must name repo-missing-labels: $(cat "$audit_log")"
ok "scenario3: missing labels → disable + LOUD INTAKE-PRECOND-FAIL"

# ============================================================================
# Scenario 4: deferred repo → DISABLE
# ============================================================================
reset_world
cat >"$intake_json" <<JSON
{
  "checkout_root": "$CHECKOUT_ROOT",
  "required_labels": ["agent-ready","agent-in-progress","agent-blocked"],
  "repos": [{ "name": "demo" }],
  "excluded": [],
  "deferred": [{ "name": "0509-telemetry" }]
}
JSON
mkdir -p "$scratch/checkout_root/demo"
printf 'agent-ready\nagent-in-progress\nagent-blocked\n' >"$LABEL_FILE"
printf 'pi-intake@0509-telemetry.timer enabled\npi-scout@0509-telemetry.timer enabled\n' >"$UNIT_FILES"

run_reconcile "$intake_json"
grep -qx 'disable pi-intake@0509-telemetry.timer' "$CALLS" \
    || fail "scenario4: deferred intake timer not disabled: $(cat "$CALLS")"
grep -qx 'disable pi-scout@0509-telemetry.timer' "$CALLS" \
    || fail "scenario4: deferred scout timer not disabled"
# Demo is still enrolled and active.
grep -qx 'enable pi-intake@demo.timer' "$CALLS" \
    || fail "scenario4: enrolled repo not enabled: $(cat "$CALLS")"
ok "scenario4: deferred repo → disable; enrolled repo still enrolled"

# ============================================================================
# Scenario 5: permanently-excluded repo → DISABLE + LOUD; NOT auto-masked
# ============================================================================
reset_world
cat >"$intake_json" <<JSON
{
  "checkout_root": "$CHECKOUT_ROOT",
  "required_labels": ["agent-ready","agent-in-progress","agent-blocked"],
  "repos": [{ "name": "demo" }],
  "excluded": [{ "name": "fleet2", "permanent": true, "reason": "no second dispatcher" }],
  "deferred": []
}
JSON
mkdir -p "$scratch/checkout_root/demo"
printf 'agent-ready\nagent-in-progress\nagent-blocked\n' >"$LABEL_FILE"
printf 'pi-intake@fleet2.timer enabled\n' >"$UNIT_FILES"

run_reconcile "$intake_json"
grep -qx 'disable pi-intake@fleet2.timer' "$CALLS" \
    || fail "scenario5: fleet2 timer not disabled: $(cat "$CALLS")"
grep -q 'INTAKE-PERM-EXCLUDED' "$triage" \
    || fail "scenario5: triage must record LOUD INTAKE-PERM-EXCLUDED: $(cat "$triage")"
# Reconciler does NOT call `systemctl mask` — that is an operator choice.
grep -q 'mask' "$CALLS" && fail "scenario5: must not auto-mask: $(cat "$CALLS")"
ok "scenario5: perm-excluded → disable + LOUD; no auto-mask"

# ============================================================================
# Scenario 6: a unit that IS masked → leave masked + LOUD; no auto-unmask
# ============================================================================
reset_world
cat >"$intake_json" <<JSON
{
  "checkout_root": "$CHECKOUT_ROOT",
  "required_labels": ["agent-ready","agent-in-progress","agent-blocked"],
  "repos": [{ "name": "demo" }],
  "excluded": [],
  "deferred": []
}
JSON
mkdir -p "$scratch/checkout_root/demo"
printf 'agent-ready\nagent-in-progress\nagent-blocked\n' >"$LABEL_FILE"
# pi-intake@demo.timer is masked; pi-scout@demo.timer is enabled but inactive.
printf 'pi-intake@demo.timer masked\npi-scout@demo.timer enabled\n' >"$UNIT_FILES"

run_reconcile "$intake_json"
grep -q 'INTAKE-MASKED' "$triage" \
    || fail "scenario6: triage must record LOUD INTAKE-MASKED: $(cat "$triage")"
# Reconciler MUST NOT issue `systemctl unmask`. It only emits enable / start /
# disable on a clean convergence.
grep -q 'unmask' "$CALLS" && fail "scenario6: must not auto-unmask: $(cat "$CALLS")"
# scout timer (not masked) gets started; intake timer (masked) is left alone.
grep -qx 'start pi-scout@demo.timer' "$CALLS" \
    || fail "scenario6: scout timer not started: $(cat "$CALLS")"
grep -q 'mask-detected' "$audit_log" \
    || fail "scenario6: audit must record mask-detected: $(cat "$audit_log")"
ok "scenario6: masked unit left masked + LOUD; scout timer still reconciled"

# ============================================================================
# Scenario 7: UNDECLARED drift (live unit for repo not in declared set)
# ============================================================================
reset_world
cat >"$intake_json" <<JSON
{
  "checkout_root": "$CHECKOUT_ROOT",
  "required_labels": ["agent-ready","agent-in-progress","agent-blocked"],
  "repos": [{ "name": "demo" }],
  "excluded": [],
  "deferred": []
}
JSON
mkdir -p "$scratch/checkout_root/demo"
printf 'agent-ready\nagent-in-progress\nagent-blocked\n' >"$LABEL_FILE"
# `rogue` is NOT declared anywhere, but its timer is enabled+active.
printf 'pi-intake@rogue.timer enabled\npi-intake@demo.timer disabled\n' >"$UNIT_FILES"
printf 'pi-intake@rogue.timer\n' >"$UNIT_ACTIVE"

run_reconcile "$intake_json"
grep -qx 'disable pi-intake@rogue.timer' "$CALLS" \
    || fail "scenario7: rogue timer not disabled: $(cat "$CALLS"))"
grep -q 'INTAKE-UNDECLARED' "$triage" \
    || fail "scenario7: triage must record LOUD INTAKE-UNDECLARED: $(cat "$triage")"
grep -q 'undeclared-drift' "$audit_log" \
    || fail "scenario7: audit must record undeclared-drift: $(cat "$audit_log")"
ok "scenario7: undeclared drift → disable + LOUD INTAKE-UNDECLARED"

# ============================================================================
# Scenario 8: full audit trail captures every state change with the right shape
# ============================================================================
reset_world
cat >"$intake_json" <<JSON
{
  "checkout_root": "$CHECKOUT_ROOT",
  "required_labels": ["agent-ready","agent-in-progress","agent-blocked"],
  "repos": [{ "name": "demo" }, { "name": "0509" }],
  "excluded": [],
  "deferred": []
}
JSON
mkdir -p "$scratch/checkout_root/demo" "$scratch/checkout_root/0509"
printf 'agent-ready\nagent-in-progress\nagent-blocked\n' >"$LABEL_FILE"
# 0509 is already enabled+active; demo is not configured at all.
printf 'pi-intake@0509.timer enabled\npi-scout@0509.timer enabled\n' >"$UNIT_FILES"
printf 'pi-intake@0509.timer\npi-scout@0509.timer\n' >"$UNIT_ACTIVE"

run_reconcile "$intake_json"

# Every audit line has: <iso8601> <unit> <action> actor=reconciler why=<token>
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[0-9-]+T[0-9:]+Z\ [a-zA-Z0-9@.-]+\ [a-z-]+\ actor=reconciler\ why=.+ ]] \
        || fail "scenario8: malformed audit line: $line"
done <"$audit_log"
# demo got enabled+started (2 lines per unit, 2 units → 4 lines minimum).
grep -c 'pi-intake@demo.timer enable actor=reconciler' "$audit_log" | grep -qx 1 \
    || fail "scenario8: demo intake enable audit line missing"
grep -c 'pi-scout@demo.timer enable actor=reconciler' "$audit_log" | grep -qx 1 \
    || fail "scenario8: demo scout enable audit line missing"
# 0509 is already converged — no audit lines for it (idempotence).
grep -q 'pi-intake@0509.timer enable' "$audit_log" \
    && fail "scenario8: idempotent — must NOT log enable when already enabled: $(cat "$audit_log")"
ok "scenario8: audit log shape locked; idempotence respected"

# Snapshot file written, JSON parseable.
snap="$(dirname "$audit_log")/snapshot.json"
[[ -f "$snap" ]] || fail "scenario8: snapshot.json not written"
n=$(jq '.repos | length' "$snap")
[[ "$n" == "2" ]] || fail "scenario8: snapshot must list 2 repos, got $n"
ok "scenario8: snapshot file lists converged repos"

# ============================================================================
# Scenario 9: dry-run makes no systemctl calls but still records audit
# ============================================================================
reset_world
cat >"$intake_json" <<JSON
{
  "checkout_root": "$CHECKOUT_ROOT",
  "required_labels": ["agent-ready","agent-in-progress","agent-blocked"],
  "repos": [{ "name": "demo" }],
  "excluded": [],
  "deferred": []
}
JSON
mkdir -p "$scratch/checkout_root/demo"
printf 'agent-ready\nagent-in-progress\nagent-blocked\n' >"$LABEL_FILE"
: >"$UNIT_FILES"

set +e
env_out=$(
    INTAKE_RECONCILE_SYSTEMCTL="$systemctl_fake" \
    INTAKE_RECONCILE_GH="$gh_fake" \
    INTAKE_RECONCILE_INTAKE_JSON="$intake_json" \
    INTAKE_RECONCILE_AUDIT_LOG="$audit_log" \
    INTAKE_RECONCILE_TRIAGE="$triage" \
    INTAKE_RECONCILE_DRY_RUN=1 \
    INTAKE_RECONCILE_NOW="2026-08-26T02:00:00Z" \
    "$bin" 2>&1
) || fail "scenario9: dry-run must exit 0: $env_out"
set -e
[[ ! -s "$CALLS" ]] || fail "scenario9: dry-run must NOT call systemctl: $(cat "$CALLS")"
printf '%s\n' "$env_out" | grep -q 'DRY enable' || fail "scenario9: dry-run logs DRY enable: $env_out"
grep -q 'demo.timer enable actor=reconciler' "$audit_log" \
    || fail "scenario9: dry-run still writes audit: $(cat "$audit_log")"
ok "scenario9: dry-run short-circuits systemctl, still records audit"

# ============================================================================
# Scenario 10: contracts — file talks about the reconciler + tests run it
# ============================================================================
grep -q 'fleet-ops#32' "$repo_root/config/intake-repos.json" \
    || fail "intake-repos.json description must reference fleet-ops#32"
grep -q 'intake-reconcile' "$repo_root/README.md" \
    || fail "README.md must mention intake-reconcile (the declared set is meaningless without it)"
[[ -x "$repo_root/bin/intake-reconcile" ]] \
    || fail "bin/intake-reconcile not executable"
[[ -f "$repo_root/systemd/intake-reconcile.path" ]] \
    || fail "systemd/intake-reconcile.path missing"
[[ -f "$repo_root/systemd/intake-reconcile.service" ]] \
    || fail "systemd/intake-reconcile.service missing"
[[ -f "$repo_root/systemd/intake-reconcile.timer" ]] \
    || fail "systemd/intake-reconcile.timer missing"
grep -q 'bin/intake-reconcile' "$repo_root/MANIFEST" \
    || fail "MANIFEST must list bin/intake-reconcile"
grep -q 'systemd/intake-reconcile.service' "$repo_root/MANIFEST" \
    || fail "MANIFEST must list systemd/intake-reconcile.service"
grep -q 'systemd/intake-reconcile.timer' "$repo_root/MANIFEST" \
    || fail "MANIFEST must list systemd/intake-reconcile.timer"
grep -q 'systemd/intake-reconcile.path' "$repo_root/MANIFEST" \
    || fail "MANIFEST must list systemd/intake-reconcile.path"
ok "scenario10: MANIFEST + README + description all reference the reconciler"

echo "OK: intake-reconcile converges declared set → systemd, drift surfaces loud"
exit 0