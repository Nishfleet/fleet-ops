#!/usr/bin/env bash
# tests/hermes-outbound-class-gate.test.sh
#
# fleet-ops#1534: the hermes outbound wrapper (bin/hermes) is the single
# chokepoint for messages to Nish's phone. --urgent bypasses the 3/24h
# ceiling ONLY when the caller declares a sanctioned --class (a Nish-reserved
# boundary class or one of the two digests). Without a sanctioned class the
# send is REFUSED (exit 7) — a rogue worker cannot text Nish by appending
# --urgent. This test proves the gate end-to-end with a stubbed REAL binary
# and a temp ledger, no real Telegram send.
#
# The gate is the chokepoint: alertmanager severity=page routing is the OTHER
# phone path. Together those two gates are the one mechanical policy. This
# test locks the hermes side so a later overwrite cannot silently drop the
# class requirement.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
hermes="$repo_root/bin/hermes"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$hermes" ]] || fail "missing: $hermes"
[[ -x "$hermes" ]] || fail "not executable: $hermes"

scratch="$(mktemp -d -t hermes-class-gate.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Stub REAL so no real Telegram send happens. The stub logs args + exits 0.
fake_real="$scratch/fake-real"
cat > "$fake_real" <<'EOF'
#!/usr/bin/env bash
printf 'REAL-EXEC: %s\n' "$*" >> "$HERMES_REAL_LOG"
exit 0
EOF
chmod +x "$fake_real"

export HERMES_REAL="$fake_real"
export HERMES_OUTBOUND_LEDGER="$scratch/ledger.json"
export HERMES_OUTBOUND_LOG="$scratch/actions.log"
export HERMES_REAL_LOG="$scratch/real.log"

# Helper: run hermes send with given args, capture rc + whether REAL was exec'd.
run() {
  : > "$HERMES_REAL_LOG" 2>/dev/null || true
  set +e
  bash "$hermes" send "$@" >/dev/null 2>&1
  local rc=$?
  set -e
  local real_exec=0
  [[ -s "$HERMES_REAL_LOG" ]] && real_exec=1
  printf '%s|%s' "$rc" "$real_exec"
}

# --- TEST 1: --urgent without --class => REFUSE exit 7, REAL not exec'd ---
res=$(run -t telegram --urgent "hello")
rc=${res%%|*}; real=${res##*|}
[[ "$rc" == "7" ]] || fail "urgent without class: expected exit 7, got $rc"
[[ "$real" == "0" ]] || fail "urgent without class: REAL must NOT be exec'd (refused before send)"
ok "urgent without --class -> REFUSE exit 7, REAL not exec'd"

# --- TEST 2: --urgent with unsanctioned --class => REFUSE exit 7 ---
res=$(run -t telegram --urgent --class random-worker "hello")
rc=${res%%|*}; real=${res##*|}
[[ "$rc" == "7" ]] || fail "urgent unsanctioned: expected exit 7, got $rc"
[[ "$real" == "0" ]] || fail "urgent unsanctioned: REAL must NOT be exec'd"
ok "urgent with unsanctioned --class -> REFUSE exit 7"

# --- TEST 3: --urgent with sanctioned boundary class => ACCEPT, REAL exec'd ---
for cls in MONEY-BOUNDARY LEGAL-BOUNDARY PRODUCT-DIRECTION CUSTOMER-DATA CREDENTIAL-BOUNDARY ONE-SHOT-PUBLIC-ACTION; do
  res=$(run -t telegram --urgent --class "$cls" "hello")
  rc=${res%%|*}; real=${res##*|}
  [[ "$rc" == "0" ]] || fail "urgent $cls: expected exit 0, got $rc"
  [[ "$real" == "1" ]] || fail "urgent $cls: REAL must be exec'd (sanctioned class)"
done
ok "urgent with each sanctioned boundary class -> ACCEPT, REAL exec'd"

# --- TEST 4: --urgent with sanctioned digest class => ACCEPT ---
for cls in daily-digest weekly-digest; do
  res=$(run -t telegram --urgent --class "$cls" "hello")
  rc=${res%%|*}; real=${res##*|}
  [[ "$rc" == "0" ]] || fail "urgent $cls: expected exit 0, got $rc"
  [[ "$real" == "1" ]] || fail "urgent $cls: REAL must be exec'd"
done
ok "urgent with each sanctioned digest class -> ACCEPT, REAL exec'd"

# --- TEST 5: --class=VALUE (equals form) => ACCEPT for sanctioned ---
res=$(run -t telegram --urgent --class=MONEY-BOUNDARY "hello")
rc=${res%%|*}; real=${res##*|}
[[ "$rc" == "0" ]] || fail "--class=MONEY-BOUNDARY: expected exit 0, got $rc"
[[ "$real" == "1" ]] || fail "--class=MONEY-BOUNDARY: REAL must be exec'd"
ok "--class=VALUE (equals form) -> ACCEPT for sanctioned class"

# --- TEST 6: HERMES_CLASS env declares class => ACCEPT ---
res=$(HERMES_CLASS=LEGAL-BOUNDARY run -t telegram --urgent "hello")
rc=${res%%|*}; real=${res##*|}
[[ "$rc" == "0" ]] || fail "HERMES_CLASS=LEGAL-BOUNDARY: expected exit 0, got $rc"
[[ "$real" == "1" ]] || fail "HERMES_CLASS=LEGAL-BOUNDARY: REAL must be exec'd"
ok "HERMES_CLASS env declares sanctioned class -> ACCEPT"

# --- TEST 7: HERMES_CLASS env unsanctioned => REFUSE ---
res=$(HERMES_CLASS=bogus run -t telegram --urgent "hello")
rc=${res%%|*}; real=${res##*|}
[[ "$rc" == "7" ]] || fail "HERMES_CLASS=bogus: expected exit 7, got $rc"
[[ "$real" == "0" ]] || fail "HERMES_CLASS=bogus: REAL must NOT be exec'd"
ok "HERMES_CLASS env unsanctioned -> REFUSE exit 7"

# --- TEST 8: --class without value => exit 6 ---
set +e
bash "$hermes" send -t telegram --urgent --class >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "6" ]] || fail "--class without value: expected exit 6, got $rc"
ok "--class without value -> exit 6"

# --- TEST 9: non-urgent send (no --class) => ACCEPT (ceiling path, no class needed) ---
res=$(run -t telegram "hello")
rc=${res%%|*}; real=${res##*|}
[[ "$rc" == "0" ]] || fail "non-urgent: expected exit 0, got $rc"
[[ "$real" == "1" ]] || fail "non-urgent: REAL must be exec'd"
ok "non-urgent send (no --class) -> ACCEPT (ceiling path)"

# --- TEST 10: --list => passthrough (not a send, no class-gate) ---
res=$(run --list)
rc=${res%%|*}; real=${res##*|}
[[ "$rc" != "7" ]] || fail "--list: must not be a class-gate refusal (exit 7)"
ok "--list -> passthrough (not class-gated)"

# --- TEST 11: non-send command (e.g. hermes version) => passthrough ---
# Non-send commands skip the gate entirely. REAL is exec'd with the original args.
: > "$HERMES_REAL_LOG" 2>/dev/null || true
set +e
bash "$hermes" version >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" != "7" ]] || fail "non-send command: must not be class-gated (exit 7)"
ok "non-send command -> passthrough (not class-gated)"

# --- TEST 12: refusal is ledgered in the actions log ---
: > "$HERMES_OUTBOUND_LOG"
bash "$hermes" send -t telegram --urgent "no-class" >/dev/null 2>&1 || true
grep -q 'REFUSE-CLASS' "$HERMES_OUTBOUND_LOG" \
  || fail "refusal must be ledgered in actions log (REFUSE-CLASS)"
ok "refusal ledgered in actions log (REFUSE-CLASS)"

# --- TEST 13: acceptance is ledgered with the class ---
: > "$HERMES_OUTBOUND_LOG"
bash "$hermes" send -t telegram --urgent --class MONEY-BOUNDARY "hello" >/dev/null 2>&1 || true
grep -q 'ACCEPT' "$HERMES_OUTBOUND_LOG" \
  || fail "acceptance must be ledgered in actions log (ACCEPT)"
grep -q 'class=MONEY-BOUNDARY' "$HERMES_OUTBOUND_LOG" \
  || fail "acceptance ledger line must name the class"
ok "acceptance ledgered with class in actions log"

echo
echo "hermes-outbound-class-gate: 13/13 invariants pass (fleet-ops#1534)"
