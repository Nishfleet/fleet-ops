#!/usr/bin/env bash
# tests/fleet-blind-audit-product.test.sh
#
# Proves the fleet-ops#5437 product-target mode:
#   - --target product:<slug> resolves the target from
#     config/blind-audit-product-targets.json
#   - TWO different seats run the outside-in packet in one run; the union
#     is filed and agreements are marked both_seats
#   - panel-PASS findings are filed on the product repo as
#     gap-audit + agent-ready through the #1212 dedupe gate
#   - sequential same-tick chain: a default (no --target) fleet run also
#     runs the registered product targets (bullet 2)
#   - bullet 4: a PASS finding that lands in NO durable place — no filed
#     issue, no carry-over ledger entry, no panel-FAIL line — fails the run
#   - the two-seat rule is loud when only one seat is usable
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-blind-audit"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

# Class guards.
grep -q 'AUDIT_PRODUCT_TARGETS' "$bin" \
    || fail "fleet-blind-audit must read the product target register"
grep -q 'prompts/blind-audit-product.md' "$bin" \
    || fail "fleet-blind-audit product mode must use the outside-in packet prompt"
grep -q 'config/blind-audit-product-targets.json' "$bin" \
    || fail "product targets must be registered in the existing config, not a new config surface"
grep -q 'both_seats' "$bin" \
    || fail "product mode must mark two-seat agreements (parallel-POV doctrine)"
[[ -f "$repo_root/prompts/blind-audit-product.md" ]] \
    || fail "prompts/blind-audit-product.md missing"
[[ -f "$repo_root/config/blind-audit-product-targets.json" ]] \
    || fail "config/blind-audit-product-targets.json missing"

scratch=$(mktemp -d -t fleet-blind-audit-product.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM
mkdir -p "$scratch/fakebin"

# Fake pi: the seat letter comes from the packet's "seat %s" line. Both
# seats report one shared finding (agreement) plus one seat-specific finding.
cat > "$scratch/fakebin/pi" <<'FAKE_PI'
#!/usr/bin/env bash
packet=$(cat)
findings_json=$(printf '%s' "$packet" | sed -n 's/^- Where to save findings JSON: `\(.*\)`$/\1/p' | tail -1)
report_md=$(printf '%s' "$packet" | sed -n 's/^- Where to save the full report: `\(.*\)`$/\1/p' | tail -1)
seat=$(printf '%s' "$packet" | sed -n 's/^- This run is seat \([AB]\) .*/\1/p' | tail -1)
mkdir -p "$(dirname "$findings_json")"
COMMON='{"id":"common-1","title":"no CSP header on live site","body":"The live site sends no Content-Security-Policy.","severity":"high","evidence":"curl -sI https://0509.io"}'
SEAT_B='{"id":"b-only","title":"robots.txt disallows core tool","body":"robots.txt blocks the core tool path.","severity":"medium","evidence":"curl -s https://0509.io/robots.txt"}'
SEAT_A='{"id":"a-only","title":"signup form single-error display","body":"The signup form collapses all validation errors into one.","severity":"low","evidence":"curl -s https://0509.io/signup"}'
if [ "$seat" = "B" ]; then
    printf '[%s, %s]\n' "$COMMON" "$SEAT_B" > "$findings_json"
else
    printf '[%s, %s]\n' "$COMMON" "$SEAT_A" > "$findings_json"
fi
cat > "$report_md" <<'MD'
# Outside-in audit report
Body.
MD
printf '%s\n' 'VERDICT: DONE'
FAKE_PI
chmod +x "$scratch/fakebin/pi"

# Fake gh: the product run's issue list/create endpoints.
cat > "$scratch/fakebin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
subcmd="${1:-}"
shift || true
case "$subcmd" in
  label)
    [ "${1:-}" = "view" ] && exit 1
    exit 0
    ;;
  issue)
    case "${1:-}" in
      list)
        printf '%s\n' '[{"number":7,"title":"an unrelated open issue","labels":[]}]'
        ;;
      create)
        printf 'CREATE %s\n' "$*" >> "${GH_CREATE_LOG:-/dev/null}"
        echo "https://github.com/Nishfleet/0509-stub/issues/9001"
        ;;
    esac
    exit 0
    ;;
  pr)
    printf '%s\n' '[]'
    ;;
  *)
    exit 0
    ;;
esac
FAKE_GH
chmod +x "$scratch/fakebin/gh"

# Fake fleet-issue-file: stub for the #1212 filing gate.
cat > "$scratch/fakebin/fleet-issue-file" <<'FAKE_ISSUE_FILE'
#!/usr/bin/env bash
echo "ISSUEFILE $*" >> "${ISSUEFILE_LOG:-/dev/null}"
if [ "${ISSUEFILE_MODE:-live}" = "broken" ]; then
  echo "stub failure" >&2
  exit 7
fi
echo '{"action":"filed","url":"https://github.com/Nishfleet/0509-stub/issues/9001"}'
FAKE_ISSUE_FILE
chmod +x "$scratch/fakebin/fleet-issue-file"

# Fake seat-lib. TWO_SEAT_MODE=single makes the second pick return the same
# seat, exercising the two-seat-rule-violation path.
cat > "$scratch/seat-lib-fake.sh" <<'FAKE_SEAT_LIB'
# shellcheck shell=bash
find_senior_seat() { printf 'fakeA\tmodelA'; }
pick_seat() {
    local fail_p="$1" fail_m="$2"
    if [ "${TWO_SEAT_MODE:-good}" = "single" ]; then
        printf 'fakeA\tmodelA'
    elif [ -n "$fail_p" ]; then
        printf 'fakeB\tmodelB'
    else
        printf 'fakeA\tmodelA'
    fi
}
FAKE_SEAT_LIB

# Fake panel: PASS everything but an explicitly rejected title.
cat > "$scratch/fake-panel" <<'FAKE_PANEL'
#!/usr/bin/env python3
import json, sys
obj = json.load(sys.stdin)
f = obj.get("finding") or {}
if "panel-reject-me" in (f.get("title") or ""):
    print(json.dumps({"verdict": "FAIL", "reason": "dup-ish"}))
else:
    print(json.dumps({"verdict": "PASS", "reason": "ok"}))
FAKE_PANEL
chmod +x "$scratch/fake-panel"

# Target register (stub repo/site so nothing live is touched).
cat > "$scratch/product-targets.json" <<'EOF'
{ "targets": { "0509": { "repo": "Nishfleet/0509-stub", "site": "https://0509.example.invalid", "slug": "0509" } } }
EOF

run_product() { # output in $scratch/run.log
    local rc=0
    env "$@" \
      GH_TOKEN="test-no-real-gh" \
      AUDIT_STATE_DIR="$scratch/state" \
      AUDIT_PRODUCT_TARGETS="$scratch/product-targets.json" \
      AUDIT_PRODUCT_PROMPT="$repo_root/prompts/blind-audit-product.md" \
      AUDIT_PANEL_BIN="$scratch/fake-panel" \
      AUDIT_SEAT_LIB="$scratch/seat-lib-fake.sh" \
      AUDIT_PI_BIN="$scratch/fakebin/pi" \
      AUDIT_FAKE_NOW="2026-09-12T04:00:00Z" \
      AUDIT_MAX_FINDINGS="5" \
      PATH="$scratch/fakebin:$PATH" \
      ISSUEFILE_LOG="$scratch/issuefile.log" \
      GH_CREATE_LOG="$scratch/gh-create.log" \
      "$bin" --target product:0509 >"$scratch/run.log" 2>&1 || rc=$?
    return "$rc"
}

# --- case 1: two-seat union, agreement marked -------------------------------
a1=0
run_product FLEET_ISSUE_FILE="$scratch/fakebin/fleet-issue-file" || a1=$?
[ "$a1" = "0" ] || { cat "$scratch/run.log"; fail "product run exited $a1"; }

grep -q 'seats A=fakeA' "$scratch/run.log" || fail "seat A line missing"
grep -q 'seat B fakeB/modelB' "$scratch/run.log" || fail "seat B line missing"

prod_dir=$(find "$scratch/state/reports" -maxdepth 2 -type d -name 'product-0509' | head -1)
[ -n "$prod_dir" ] || fail "no product report dir"
merged="$prod_dir/merged-findings.json"
[ -s "$merged" ] || fail "merged findings missing"
jq -e '.findings | length == 3' "$merged" >/dev/null || fail "expected union of 3 findings"
jq -e '.findings | map(select(.title | contains("no CSP header"))) | .[] | .both_seats == true' "$merged" >/dev/null \
    || fail "agreed finding not marked both_seats"

# All three panel-PASS findings were filed on the product repo.
n_files=$(grep -c 'gap-audit' "$scratch/issuefile.log" || true)
[ "$n_files" = "3" ] || fail "expected 3 filings on the product repo, got $n_files"
grep -q 'product/0509: audit complete: filed=3' "$scratch/run.log" || fail "filed count wrong"

# --- case 2: bullet-4 — a PASS finding landing NOWHERE is a FAIL ------------
# The file gate is broken AND the carry-over ledger path is unwritable (a
# directory), so the finding can reach neither an issue nor the ledger.
rm -rf "$scratch/state"
mkdir -p "$scratch/state" "$scratch/state/ledger-blocked.jsonl"
a2=0
run_product \
      FLEET_ISSUE_FILE="$scratch/fakebin/fleet-issue-file" \
      ISSUEFILE_MODE=broken \
      AUDIT_PRODUCT_CARRYOVER_FILE="$scratch/state/ledger-blocked.jsonl" || a2=$?
[ "$a2" = "1" ] || { tail -30 "$scratch/run.log"; fail "expected exit 1 when a PASS finding lands NOWHERE, got $a2"; }
grep -q 'landed NOWHERE' "$scratch/run.log" || fail "nowhere-landing not flagged"

# --- case 3: two-seat rule unmet is a loud skip (exit 1) --------------------
rm -rf "$scratch/state"
a3=0
run_product \
      FLEET_ISSUE_FILE="$scratch/fakebin/fleet-issue-file" \
      TWO_SEAT_MODE=single || a3=$?
[ "$a3" = "1" ] || fail "expected exit 1 when the two-seat rule is unmet, got $a3"
grep -q 'two-seat rule unmet' "$scratch/run.log" || fail "two-seat violation not loud"

# --- case 4: sequential same-tick chain (default run -> product run) --------
rm -rf "$scratch/state"
cat > "$scratch/plan.md" <<'EOF'
last-heartbeat: 2026-08-26T05:43:00Z (durable-timer)
EOF
printf '%s\n' '{"candidates":[]}' > "$scratch/empty-seams.json"
printf '# no deliberate states\n' > "$scratch/empty-deliberate.md"
cat > "$scratch/noop-gate.py" <<'NOOP'
#!/usr/bin/env python3
import sys
sys.stdin.read()
print('{"findings":[]}')
NOOP
chmod +x "$scratch/noop-gate.py"
mkdir -p "$scratch/fleetroot"

# One pi binary routing both packet shapes: fleet packets get a one-finding
# payload; product packets (seat letter marker) delegate to the product fake.
cat > "$scratch/fakebin/pi-both" <<'FAKE_PI_BOTH'
#!/usr/bin/env bash
packet=$(cat)
if printf '%s' "$packet" | grep -q 'This run is seat'; then
    exec "$scratch/fakebin/pi"
fi
findings_json=$(printf '%s' "$packet" | sed -n 's/^- Where to save findings JSON: `\(.*\)`$/\1/p' | tail -1)
report_md=$(printf '%s' "$packet" | sed -n 's/^- Where to save the full report: `\(.*\)`$/\1/p' | tail -1)
mkdir -p "$(dirname "$findings_json")"
cat > "$findings_json" <<'JSON'
{"findings":[{"rank":1,"title":"orphan systemd unit pi-issue@fleet-ops-99 is failed","body":"A worker unit is failed with no live process.","severity":"high","evidence":"systemctl --user list-units --state=failed"}]}
JSON
printf '# fleet report\n' > "$report_md"
printf '%s\n' 'pi fake done'
FAKE_PI_BOTH
chmod +x "$scratch/fakebin/pi-both"

cat > "$scratch/fakebin/fleet-issue-file-both" <<'FAKE_IIF'
#!/usr/bin/env bash
echo "ISSUEFILE $*" >> "${ISSUEFILE_LOG:-/dev/null}"
echo '{"action":"filed","url":"https://github.com/Nishfleet/fleet-ops/issues/9998"}'
FAKE_IIF
chmod +x "$scratch/fakebin/fleet-issue-file-both"

rc4=0
env GH_TOKEN="test-no-real-gh" \
    AUDIT_REPO="Nishfleet/fleet-ops" \
    AUDIT_REPO_ROOT="$scratch/fleetroot" \
    AUDIT_STATE_DIR="$scratch/state" \
    AUDIT_PROMPT="$repo_root/prompts/blind-audit.md" \
    AUDIT_PRODUCT_PROMPT="$repo_root/prompts/blind-audit-product.md" \
    AUDIT_PANEL_BIN="$scratch/fake-panel" \
    AUDIT_SEAT_LIB="$scratch/seat-lib-fake.sh" \
    AUDIT_PI_BIN="$scratch/fakebin/pi-both" \
    AUDIT_FAKE_NOW="2026-09-12T05:00:00Z" \
    AUDIT_MAX_FINDINGS="5" \
    AUDIT_PRODUCT_TARGETS="$scratch/product-targets.json" \
    AUDIT_SEAM_EVIDENCE="$scratch/empty-seams.json" \
    AUDIT_MECHANISM_GATE="$scratch/noop-gate.py" \
    AUDIT_MACHINERY_GATE="$scratch/noop-gate.py" \
    AUDIT_DELIBERATE_STATES="$scratch/empty-deliberate.md" \
    AUDIT_RUN_CHAIN_E2E_DRILL=0 \
    AUDIT_ALLOW_NONCANONICAL=1 \
    PATH="$scratch/fakebin:$PATH" \
    ISSUEFILE_LOG="$scratch/issuefile.log" \
    FLEET_ISSUE_FILE="$scratch/fakebin/fleet-issue-file-both" \
    "$bin" >"$scratch/run4.log" 2>&1 || rc4=$?
[ "$rc4" = "0" ] || { tail -20 "$scratch/run4.log"; fail "chained run exited $rc4"; }

grep -q 'product: chained run for target 0509' "$scratch/run4.log" \
    || fail "product chain did not fire on the default run"
grep -q 'product/0509: dispatching seat A' "$scratch/run4.log" \
    || fail "product leg did not dispatch seat A"
grep -q '^last-blind-audit-run:' "$scratch/plan.md" || fail "fleet stamp missing"
grep -q '^last-blind-audit-product-0509:' "$scratch/plan.md" \
    || fail "product stamp missing after chained run"

echo "OK: all product-mode cases"
