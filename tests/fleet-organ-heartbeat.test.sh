#!/usr/bin/env bash
# tests/fleet-organ-heartbeat.test.sh
#
# fleet-ops#1010: every fleet organ (timer/exporter/guard/canary) must export
# a heartbeat metric and ship an absent(<heartbeat_metric>) rule in
# config/fleet_rules.yml in the same PR. An organ without an absent-rule is
# an organ whose death is invisible.
#
# This is the mechanical-fix gate (#366) for the "organ died silently" class.
# Proves the REAL checker in bin/fleet-organ-heartbeat-check (and its Python
# lib) on the live repo + mocked PR diffs.
#
# Phase A: shape — registry, lib, bin, worker.md rule, MANIFEST install.
# Phase B: verify drill — every registered organ has an absent() rule in the
#           live config/fleet_rules.yml.
# Phase C: verify drill REJECT — a registry organ whose rule is missing.
# Phase D: gate SKIP — no organ touched.
# Phase E: gate OK — touched registered organ, rule present, no deletion.
# Phase F: gate REJECT — touched organ, rule missing, diff does not add it.
# Phase G: gate REJECT — touched organ, diff DELETES its absent() line.
# Phase H: gate OK — touched organ, rule missing, diff ADDS it.
# Phase I: gate REJECT — new candidate-organ file, not registered, no marker.
# Phase J: gate OK — new candidate-organ file declared not-an-organ.
# Phase K: gate REJECT — registry touched, new organ, no absent() rule added.
# Phase L: gate OK — registry touched, new organ, absent() rule added in diff.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-organ-heartbeat-check"
lib="$repo_root/lib/fleet-organ-heartbeat-check.py"
registry="$repo_root/config/fleet-organs.json"
rules="$repo_root/config/fleet_rules.yml"
worker="$repo_root/prompts/worker.md"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "missing or not executable: $bin"
[[ -f "$lib" ]] || fail "missing: $lib"
[[ -f "$registry" ]] || fail "missing: $registry"
[[ -f "$rules" ]] || fail "missing: $rules"
[[ -f "$worker" ]] || fail "missing: $worker"
[[ -f "$manifest" ]] || fail "missing: $manifest"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d.get("organs"),list) and d["organs"], "organs array missing"; [o for o in d["organs"] if not all(k in o for k in ("name","kind","heartbeat_metric","absent_alert","files"))]' "$registry" \
    || fail "registry is not valid JSON with the required organ fields"

scratch="$(mktemp -d -t organ-heartbeat.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# ============================================================================
# Phase A: shape — worker rule, MANIFEST install, lib syntax
# ============================================================================
grep -F -- 'fleet-organ-heartbeat-check' "$worker" >/dev/null \
    || fail "worker.md must tell authors to run bin/fleet-organ-heartbeat-check"
grep -F -- 'fleet-ops#1010' "$worker" >/dev/null \
    || fail "worker.md must reference fleet-ops#1010"
grep -F -- 'organ-heartbeat:' "$worker" >/dev/null \
    || fail "worker.md must name the organ-heartbeat: not-an-organ marker"
grep -F -- 'bin/fleet-organ-heartbeat-check' "$manifest" >/dev/null \
    || fail "MANIFEST must install bin/fleet-organ-heartbeat-check"
grep -F -- 'lib/fleet-organ-heartbeat-check.py' "$manifest" >/dev/null \
    || fail "MANIFEST must install lib/fleet-organ-heartbeat-check.py"
grep -F -- 'config/fleet-organs.json' "$manifest" >/dev/null \
    || fail "MANIFEST must install config/fleet-organs.json"
python3 -m py_compile "$lib" || fail "lib: python syntax error"
ok "A: shape (registry, lib, bin, worker rule, MANIFEST install)"

# ============================================================================
# Phase B: verify drill — live repo, every registered organ has its rule
# ============================================================================
"$bin" verify >/tmp/organ-verify.out 2>&1 || {
    cat /tmp/organ-verify.out >&2
    fail "verify drill must pass on the live repo (every organ has an absent() rule)"
}
# Sanity: the drill names the absent() shape for at least one organ.
grep -q 'absent(' /tmp/organ-verify.out || fail "verify output must name absent() rules"
ok "B: verify drill passes on the live repo"

# ============================================================================
# Helpers
# ============================================================================
empty_diff="$scratch/empty.diff"
: >"$empty_diff"

# A rules file with ONE organ's rule removed (used by Phase C/F).
build_rules_missing() {
    local metric="$1"
    # Drop any expr line that carries absent(<metric>).
    grep -v -E "absent\(${metric}\)" "$rules" >"$scratch/rules-missing.yml"
}

# A rules-diff that ADDS an absent(<metric>) expr line.
build_add_diff() {
    local metric="$1" alert="$2"
    {
        printf -- '+      - alert: %s\n' "$alert"
        printf -- '+        expr: absent(%s)\n' "$metric"
        printf -- '+        for: 3h\n'
        printf -- '+        labels:\n'
        printf -- '+          severity: critical\n'
        printf -- '+          service: fleet\n'
    } >"$scratch/add.diff"
}

# A rules-diff that DELETES an absent(<metric>) expr line.
build_del_diff() {
    local metric="$1"
    printf -- '-        expr: absent(%s) or (time() - %s) > 28800\n' "$metric" "$metric" >"$scratch/del.diff"
}

gate() {
    local ns="$1" rules_arg="$2" diff_arg="$3" body_arg="$4"
    "$bin" gate --name-status "$ns" --rules "$rules_arg" --rules-diff "$diff_arg" --body "$body_arg"
}

# ============================================================================
# Phase C: verify drill REJECT — a registry organ whose rule is missing
# ============================================================================
# Build a rules file missing the scout rule, and a registry that only has scout.
{
    printf '{"organs":[{"name":"scout","kind":"canary","heartbeat_metric":"fleet_scout_last_run_seconds","absent_alert":"FleetScoutStale","files":["bin/scout-futility-check"]}]}'
} >"$scratch/scout-only.json"
build_rules_missing 'fleet_scout_last_run_seconds'
if "$bin" verify --registry "$scratch/scout-only.json" --rules "$scratch/rules-missing.yml" >/tmp/organ-c.out 2>&1; then
    cat /tmp/organ-c.out >&2
    fail "C: verify must REJECT when a registered organ's absent() rule is missing"
fi
grep -q 'REJECT' /tmp/organ-c.out || fail "C: verify must print REJECT on a missing rule"
ok "C: verify drill rejects a missing absent() rule"

# ============================================================================
# Phase D: gate SKIP — no organ touched
# ============================================================================
printf 'M\tREADME.md\n' >"$scratch/ns-d"
if gate "$scratch/ns-d" "$rules" "$empty_diff" "$empty_diff" >/tmp/organ-d.out 2>&1; then
    grep -q 'SKIP' /tmp/organ-d.out || fail "D: gate must print SKIP when no organ touched"
    ok "D: gate SKIP when no organ touched"
else
    cat /tmp/organ-d.out >&2
    fail "D: gate must SKIP (exit 0) when no organ touched"
fi

# ============================================================================
# Phase E: gate OK — touched registered organ, rule present, no deletion
# ============================================================================
printf 'M\tbin/scout-futility-check\n' >"$scratch/ns-e"
if gate "$scratch/ns-e" "$rules" "$empty_diff" "$empty_diff" >/tmp/organ-e.out 2>&1; then
    grep -q 'OK' /tmp/organ-e.out || fail "E: gate must print OK"
    ok "E: gate OK when touched organ keeps its absent() rule"
else
    cat /tmp/organ-e.out >&2
    fail "E: gate must OK (exit 0) when a touched organ keeps its rule"
fi

# ============================================================================
# Phase F: gate REJECT — touched organ, rule missing, diff does not add it
# ============================================================================
printf 'M\tbin/scout-futility-check\n' >"$scratch/ns-f"
build_rules_missing 'fleet_scout_last_run_seconds'
if gate "$scratch/ns-f" "$scratch/rules-missing.yml" "$empty_diff" "$empty_diff" >/tmp/organ-f.out 2>&1; then
    cat /tmp/organ-f.out >&2
    fail "F: gate must REJECT when a touched organ's rule is missing and the diff adds nothing"
fi
grep -q 'REJECT' /tmp/organ-f.out || fail "F: gate must print REJECT"
grep -q 'scout' /tmp/organ-f.out || fail "F: REJECT must name the organ"
ok "F: gate rejects a touched organ with a missing absent() rule"

# ============================================================================
# Phase G: gate REJECT — touched organ, diff DELETES its absent() line
# ============================================================================
printf 'M\tbin/scout-futility-check\n' >"$scratch/ns-g"
build_del_diff 'fleet_scout_last_run_seconds'
if gate "$scratch/ns-g" "$rules" "$scratch/del.diff" "$empty_diff" >/tmp/organ-g.out 2>&1; then
    cat /tmp/organ-g.out >&2
    fail "G: gate must REJECT when the diff deletes an organ's absent() line"
fi
grep -q 'REJECT' /tmp/organ-g.out || fail "G: gate must print REJECT"
grep -q 'deletes' /tmp/organ-g.out || fail "G: REJECT must name the deletion"
ok "G: gate rejects a diff that deletes an organ's absent() rule"

# ============================================================================
# Phase H: gate OK — touched organ, rule missing in current rules, diff ADDS it
# ============================================================================
printf 'M\tbin/scout-futility-check\n' >"$scratch/ns-h"
build_rules_missing 'fleet_scout_last_run_seconds'
build_add_diff 'fleet_scout_last_run_seconds' 'FleetScoutStale'
if gate "$scratch/ns-h" "$scratch/rules-missing.yml" "$scratch/add.diff" "$empty_diff" >/tmp/organ-h.out 2>&1; then
    grep -q 'OK' /tmp/organ-h.out || fail "H: gate must print OK"
    ok "H: gate OK when a touched organ's absent() rule is added in the diff"
else
    cat /tmp/organ-h.out >&2
    fail "H: gate must OK when the diff adds the missing absent() rule"
fi

# ============================================================================
# Phase I: gate REJECT — new candidate-organ file, not registered, no marker
# ============================================================================
printf 'A\tlibexec/fleet-newexport-export.py\n' >"$scratch/ns-i"
: >"$scratch/body-empty"
if gate "$scratch/ns-i" "$rules" "$empty_diff" "$scratch/body-empty" >/tmp/organ-i.out 2>&1; then
    cat /tmp/organ-i.out >&2
    fail "I: gate must REJECT a new candidate-organ file with no registry entry and no marker"
fi
grep -q 'REJECT' /tmp/organ-i.out || fail "I: gate must print REJECT"
grep -q 'not-an-organ' /tmp/organ-i.out || fail "I: REJECT must name the not-an-organ escape"
ok "I: gate rejects an unregistered new candidate-organ file"

# ============================================================================
# Phase J: gate OK — new candidate-organ file declared not-an-organ
# ============================================================================
printf 'A\tlibexec/fleet-newexport-export.py\n' >"$scratch/ns-j"
printf 'organ-heartbeat: libexec/fleet-newexport-export.py not-an-organ: helper script, no heartbeat metric\n' >"$scratch/body-j"
if gate "$scratch/ns-j" "$rules" "$empty_diff" "$scratch/body-j" >/tmp/organ-j.out 2>&1; then
    grep -q 'not-an-organ' /tmp/organ-j.out || fail "J: gate must echo the not-an-organ declaration"
    ok "J: gate OK when a new candidate-organ file is declared not-an-organ"
else
    cat /tmp/organ-j.out >&2
    fail "J: gate must OK a not-an-organ declaration"
fi

# ============================================================================
# Phase K: gate REJECT — registry touched, new organ, no absent() rule added
# ============================================================================
# Registry that adds a brand-new organ not in fleet_rules.yml.
python3 - "$registry" "$scratch/reg-new.json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
d["organs"].append({
    "name": "brand-new",
    "kind": "canary",
    "heartbeat_metric": "fleet_brand_new_heartbeat",
    "absent_alert": "FleetBrandNewAbsent",
    "files": ["libexec/fleet-brand-new.py"],
})
json.dump(d, open(dst, "w"))
PY
printf 'M\tconfig/fleet-organs.json\n' >"$scratch/ns-k"
if "$bin" gate --name-status "$scratch/ns-k" --registry "$scratch/reg-new.json" --rules "$rules" --rules-diff "$empty_diff" --body "$empty_diff" >/tmp/organ-k.out 2>&1; then
    cat /tmp/organ-k.out >&2
    fail "K: gate must REJECT a registry-added organ with no absent() rule"
fi
grep -q 'REJECT' /tmp/organ-k.out || fail "K: gate must print REJECT"
grep -q 'brand-new' /tmp/organ-k.out || fail "K: REJECT must name the new organ"
ok "K: gate rejects a registry-added organ with no absent() rule"

# ============================================================================
# Phase L: gate OK — registry touched, new organ, absent() rule added in diff
# ============================================================================
build_add_diff 'fleet_brand_new_heartbeat' 'FleetBrandNewAbsent'
if "$bin" gate --name-status "$scratch/ns-k" --registry "$scratch/reg-new.json" --rules "$rules" --rules-diff "$scratch/add.diff" --body "$empty_diff" >/tmp/organ-l.out 2>&1; then
    grep -q 'OK' /tmp/organ-l.out || fail "L: gate must print OK"
    ok "L: gate OK when a registry-added organ ships its absent() rule in the diff"
else
    cat /tmp/organ-l.out >&2
    fail "L: gate must OK when the diff adds the new organ's absent() rule"
fi

echo
echo "ALL PHASES PASSED: organ-heartbeat invariant (verify drill + PR gate)"
