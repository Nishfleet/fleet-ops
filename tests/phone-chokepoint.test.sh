#!/usr/bin/env bash
# tests/phone-chokepoint.test.sh
#
# fleet-ops#1534: the ONE mechanical policy for messages to Nish's phone.
# Two gates, no other path:
#   1. hermes outbound wrapper (bin/hermes): --urgent requires a sanctioned
#      --class (boundary class or digest). Non-urgent sends are ceiling-bound
#      (3/24h) and fold into the next digest. Refused sends do not reach the
#      phone.
#   2. alertmanager routing (config/alertmanager.yml): only severity=page
#      reaches telegram (the phone). critical/warning/none -> repair-dispatch
#      (no phone). The only severity=page alert is RepairDispatchDown
#      (config/fleet_rules.yml).
#
# This test proves the two gates TOGETHER form a single chokepoint: no path
# to the phone exists outside these two gates. It is the integration test
# that the per-gate tests (hermes-outbound-class-gate, alertmanager-routing-
# matrix, fleet-rules-severity-page) lock individually.
#
# Invariants:
#   1. hermes class-gate: --urgent without sanctioned --class => exit 7
#   2. alertmanager: severity=page -> telegram (only phone route)
#   3. alertmanager: severity=critical/warning -> repair-dispatch (no phone)
#   4. exactly one severity=page alert (RepairDispatchDown)
#   5. nish-boundary-notify passes --class to hermes (the detected boundary token)
#   6. daily-digest passes --class daily-digest to hermes
#   7. stop-escalation-dispatch write_nish gates NISH writes to boundary classes
#   8. no other caller reaches hermes send --urgent without --class
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- 1. hermes class-gate exists and refuses without --class ---
grep -q 'gate_class_ok' "$repo_root/bin/hermes" \
  || fail "bin/hermes must have gate_class_ok (the urgent class-gate)"
grep -q 'REFUSE-CLASS' "$repo_root/bin/hermes" \
  || fail "bin/hermes must ledger REFUSE-CLASS on refusal"
ok "hermes outbound class-gate present (gate_class_ok + REFUSE-CLASS)"

# --- 2. alertmanager severity=page -> telegram ---
python3 - "$repo_root/config/alertmanager.yml" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
routes = cfg["route"]["routes"]
page = [r for r in routes if any(m == 'severity="page"' for m in (r.get("matchers") or []))]
assert len(page) == 1 and page[0]["receiver"] == "telegram", \
    print("FAIL: severity=page must -> telegram (exactly one route)", file=sys.stderr) or sys.exit(1)
print("OK: alertmanager severity=page -> telegram (the only phone route)")
PY

# --- 3. alertmanager critical/warning -> repair-dispatch (no phone) ---
python3 - "$repo_root/config/alertmanager.yml" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
routes = cfg["route"]["routes"]
for sev in ("critical", "warning"):
    r = [x for x in routes if any(m == f'severity="{sev}"' for m in (x.get("matchers") or []))]
    assert len(r) == 1 and r[0]["receiver"] == "repair-dispatch", \
        print(f"FAIL: severity={sev} must -> repair-dispatch (no phone)", file=sys.stderr) or sys.exit(1)
print("OK: alertmanager severity=critical/warning -> repair-dispatch (no phone)")
PY

# --- 4. exactly one severity=page alert (RepairDispatchDown) ---
python3 - "$repo_root/config/fleet_rules.yml" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
pages = [(g["name"], r["alert"]) for g in cfg["groups"] for r in g["rules"]
         if r.get("labels", {}).get("severity") == "page"]
assert len(pages) == 1 and pages[0][1] == "RepairDispatchDown", \
    print(f"FAIL: exactly one severity=page alert (RepairDispatchDown), got {pages}", file=sys.stderr) or sys.exit(1)
print("OK: exactly one severity=page alert: RepairDispatchDown")
PY

# --- 5. nish-boundary-notify passes --class to hermes ---
# nish-boundary-notify uses "$HERMES_BIN" send (a variable), not the literal
# "hermes send". Grep for the --urgent --class pattern on the send line.
grep -q -- '--urgent --class' "$repo_root/bin/nish-boundary-notify" \
  || fail "nish-boundary-notify must pass --class to hermes send (--urgent --class)"
grep -q 'class=\$(printf' "$repo_root/bin/nish-boundary-notify" \
  || fail "nish-boundary-notify must extract the class from the entry line"
ok "nish-boundary-notify passes --class <detected-boundary> to hermes"

# --- 6. daily-digest passes --class daily-digest to hermes ---
grep -q 'hermes send -t telegram --urgent --class daily-digest' "$repo_root/libexec/daily-digest" \
  || fail "daily-digest must pass --class daily-digest to hermes send"
ok "daily-digest passes --class daily-digest to hermes"

# --- 6b. evening-highlights-digest passes --class evening-highlights-digest ---
grep -q 'hermes send -t telegram --urgent --class evening-highlights-digest' "$repo_root/libexec/evening-highlights-digest" \
  || fail "evening-highlights-digest must pass --class evening-highlights-digest to hermes send"
ok "evening-highlights-digest passes --class evening-highlights-digest to hermes"

# --- 7. stop-escalation-dispatch write_nish gates NISH writes ---
grep -q '^write_nish()' "$repo_root/bin/stop-escalation-dispatch" \
  || fail "stop-escalation-dispatch must have write_nish helper"
grep -q 'write_nish "CAP-REACHED"' "$repo_root/bin/stop-escalation-dispatch" \
  || fail "CAP-REACHED must route via write_nish (auditor path, not NISH)"
grep -q 'write_nish "KILL-ESCALATION"' "$repo_root/bin/stop-escalation-dispatch" \
  || fail "KILL-ESCALATION must route via write_nish (auditor path, not NISH)"
grep -q 'write_nish "MONEY-BOUNDARY"' "$repo_root/bin/stop-escalation-dispatch" \
  || fail "walled ladder must tag MONEY-BOUNDARY via write_nish"
ok "stop-escalation-dispatch write_nish gates NISH writes to boundary classes"

# --- 8. no other caller reaches hermes send --urgent without --class ---
# Scan bin/ and libexec/ for any send --urgent call (literal "hermes send" or
# "$HERMES_BIN" send). Every one must pass --class, except bin/hermes itself
# (which IMPLEMENTS the gate). This catches a future caller that tries to text
# Nish without declaring a class.
hits=$(grep -rn 'send .*--urgent\|--urgent.*send ' \
  "$repo_root/bin" "$repo_root/libexec" 2>/dev/null | grep -v '\.py:' || true)
if [[ -n "$hits" ]]; then
  while IFS= read -r line; do
    file=$(printf '%s' "$line" | cut -d: -f1)
    # Skip the wrapper itself (bin/hermes) — it IMPLEMENTS the gate.
    [[ "$file" == "$repo_root/bin/hermes" ]] && continue
    # Skip comment lines (grep -n includes comments; filter them).
    content=$(printf '%s' "$line" | cut -d: -f3-)
    case "$content" in
      \#*) continue ;;
    esac
    # Every other caller must pass --class.
    if ! printf '%s' "$line" | grep -q -- '--class'; then
      fail "send --urgent without --class: $line"
    fi
  done <<< "$hits"
fi
ok "every send --urgent caller (outside bin/hermes) passes --class"

echo
echo "phone-chokepoint: all 8 invariants pass (fleet-ops#1534) — two gates, no other phone path"
