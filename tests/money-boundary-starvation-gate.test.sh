#!/usr/bin/env bash
# tests/money-boundary-starvation-gate.test.sh
#
# fleet-ops#4627: a dry METERED provider is a lane fault, not a money
# decision, while any prepaid/free seat can carry the work. The
# money-boundary path must fire a MONEY-BOUNDARY for provider credit
# exhaustion ONLY when the fleet is starved (zero healthy prepaid/free
# seats). Otherwise: bench the dry provider, log one line, no page.
#
# This drill replays the two 2026-09-09 MONEY-BOUNDARY pages that reached
# Nish while Ollama Cloud DeepSeek flash (prepaid) and ClinePass GLM 5.3
# flash (free) were healthy and idle. Both must be suppressed given the
# live seat state at the time.
#
# Covers three layers of the starvation gate:
#   1. bin/money-boundary-raise: the writer suppresses the ledger line
#      (no page) when the fleet is not starved, and still benches the dry
#      provider. The pages log records a "suppressed" line.
#   2. bin/nish-boundary-notify: the defense-in-depth gate revokes a
#      hand-written/stale MONEY-BOUNDARY line when the fleet is not
#      starved (REVOKED-BY-STARVATION-GATE).
#   3. config/fleet_rules.yml: the FleetProviderSpendBoundary alert
#      expression is gated on fleet starvation (fleet_seat_healthy{class=
#      ~"prepaid|free"} == 0 or absent) so it does not fire while a healthy
#      prepaid/free seat exists.
#
# Offline: uses a scratch agent-state dir via env overrides; touches nothing
# live. Hosted from tests/rule-enforcement.test.sh so P14 runs it.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
raise="$repo_root/bin/money-boundary-raise"
notify="$repo_root/bin/nish-boundary-notify"
rules="$repo_root/config/fleet_rules.yml"
metrics="$repo_root/libexec/fleet-metrics-export.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$raise" ]]  || fail "missing: $raise"
[[ -x "$raise" ]]  || fail "not executable: $raise"
[[ -f "$notify" ]] || fail "missing: $notify"
[[ -x "$notify" ]] || fail "not executable: $notify"
[[ -f "$rules" ]]  || fail "missing: $rules"
[[ -f "$metrics" ]] || fail "missing: $metrics"
command -v jq >/dev/null 2>&1 || fail "jq missing"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT INT TERM

AS="$scratch/as"
SEAT_DIR="$AS/lanes/seats"
mkdir -p "$SEAT_DIR" "$AS/alert-repair" "$scratch/caps"

# --- fixture: the live seat state at 2026-09-09 01:29Z --------------------
# openrouter is the dry METERED provider (credits_remaining_usd=-0.20).
# ollama-cloud (prepaid-quota) and cline-pass (free) were healthy and idle.
# The proxy simply did not list them — the detector paged for the wrong
# condition.
cat > "$scratch/caps/seat-caps.json" <<'JSON'
{
  "providers": {
    "openrouter": {
      "models": {
        "deepseek-ai/deepseek-v4-flash": {"cap": 2}
      },
      "class": "metered"
    },
    "ollama-cloud": {
      "cap": 2,
      "class": "prepaid-quota"
    },
    "cline-pass": {
      "cap": 2,
      "class": "free"
    }
  }
}
JSON

# Healthy seat ledgers for the prepaid and free providers.
obs="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$SEAT_DIR/ollama-cloud__deepseek-v4-flash.json" <<JSON
{
  "provider": "ollama-cloud",
  "model": "deepseek-v4-flash",
  "health_class": "healthy",
  "seat_dead": false,
  "observed_at": "$obs"
}
JSON
cat > "$SEAT_DIR/cline-pass__glm-5-3-flash.json" <<JSON
{
  "provider": "cline-pass",
  "model": "glm-5-3-flash",
  "health_class": "healthy",
  "seat_dead": false,
  "observed_at": "$obs"
}
JSON

# --- 1. writer gate: money-boundary-raise suppresses the page -------------
# Replay the 01:29Z line: openrouter spend_today_usd=0 credits_remaining_usd=-0.20.
# The fleet is NOT starved (ollama-cloud prepaid + cline-pass free are
# healthy), so the writer must suppress the ledger line (no page), bench
# the dry provider, and log a "suppressed" line to the pages log.
out="$(MONEY_BOUNDARY_AS="$AS" \
       MONEY_BOUNDARY_CAPS="$scratch/caps/seat-caps.json" \
       MONEY_BOUNDARY_SEAT_LEDGER="$SEAT_DIR" \
       MONEY_BOUNDARY_PAGES_LOG="$AS/lanes/money-boundary-pages.log" \
       "$raise" openrouter 0 -0.20 2>&1)"

echo "$out" | grep -q "SUPPRESSED" \
  || fail "raise must report SUPPRESSED when the fleet is not starved: $out"
ok "writer suppresses the page when the fleet is not starved (fleet-ops#4627)"

# No MONEY-BOUNDARY ledger line must have been written.
[[ -f "$AS/NISH-ESCALATIONS.md" ]] \
  && fail "raise must NOT write a ledger line when the page is suppressed" || true
ok "writer writes no MONEY-BOUNDARY ledger line when suppressed"

# The dry provider must still be benched.
[[ -f "$SEAT_DIR/openrouter__deepseek-ai_deepseek-v4-flash.json" ]] \
  || fail "raise must still bench the dry provider's cap>0 seat when suppressed"
bench_src="$(jq -r '.source // ""' "$SEAT_DIR/openrouter__deepseek-ai_deepseek-v4-flash.json" 2>/dev/null || true)"
[[ "$bench_src" == "money_boundary" ]] \
  || fail "benched seat must have source=money_boundary, got: $bench_src"
ok "writer still benches the dry provider (source=money_boundary)"

# The pages log must record a suppressed line.
[[ -f "$AS/lanes/money-boundary-pages.log" ]] \
  || fail "pages log must be created"
grep -q "suppressed reason=provider_credits_dry provider=openrouter" "$AS/lanes/money-boundary-pages.log" \
  || fail "pages log must record the suppressed page: $(cat "$AS/lanes/money-boundary-pages.log")"
ok "pages log records the suppressed page (reason=provider_credits_dry)"

# --- 1b. writer gate: page DOES fire when the fleet IS starved ------------
# Remove the healthy prepaid/free ledgers so the fleet is starved. The
# writer must now write the ledger line (the page fires).
rm -f "$SEAT_DIR/ollama-cloud__deepseek-v4-flash.json" \
      "$SEAT_DIR/cline-pass__glm-5-3-flash.json"
# Remove the benched openrouter seat so the raise re-runs cleanly.
rm -f "$SEAT_DIR/openrouter__deepseek-ai_deepseek-v4-flash.json"

out2="$(MONEY_BOUNDARY_AS="$AS" \
        MONEY_BOUNDARY_CAPS="$scratch/caps/seat-caps.json" \
        MONEY_BOUNDARY_SEAT_LEDGER="$SEAT_DIR" \
        MONEY_BOUNDARY_PAGES_LOG="$AS/lanes/money-boundary-pages.log" \
        "$raise" openrouter 0 -0.20 2>&1)"

echo "$out2" | grep -q "raised money wall" \
  || fail "raise must fire the page when the fleet IS starved: $out2"
[[ -f "$AS/NISH-ESCALATIONS.md" ]] \
  || fail "ledger file must be created when the fleet is starved"
grep -q "MONEY-BOUNDARY provider=openrouter" "$AS/NISH-ESCALATIONS.md" \
  || fail "ledger line must be written when the fleet is starved"
ok "writer fires the page when the fleet IS starved (no healthy prepaid/free seat)"

# --- 2. notifier gate: defense-in-depth revokes stale MONEY-BOUNDARY lines --
# Re-create the healthy prepaid/free ledgers (the fleet is NOT starved again).
cat > "$SEAT_DIR/ollama-cloud__deepseek-v4-flash.json" <<JSON
{
  "provider": "ollama-cloud",
  "model": "deepseek-v4-flash",
  "health_class": "healthy",
  "seat_dead": false,
  "observed_at": "$obs"
}
JSON
cat > "$SEAT_DIR/cline-pass__glm-5-3-flash.json" <<JSON
{
  "provider": "cline-pass",
  "model": "glm-5-3-flash",
  "health_class": "healthy",
  "seat_dead": false,
  "observed_at": "$obs"
}
JSON

# Write the two 2026-09-09 MONEY-BOUNDARY lines to NISH-ESCALATIONS.md as
# they would have appeared (hand-written or stale, pre-fix). Both must be
# suppressed by the notifier's defense-in-depth starvation gate.
NISH="$AS/NISH-ESCALATIONS.md"
cat > "$NISH" <<'MD'
2026-09-09T01:29:00Z MONEY-BOUNDARY provider=openrouter spend_today_usd=0 credits_remaining_usd=-0.20 — provider over the USD 5 boundary
  SUMMARY: openrouter credits dry while prepaid/free seats were healthy
2026-09-09T01:56:00Z MONEY-BOUNDARY provider=openrouter issue-fleet-ops-4589 — Top up fleet proxy credits
  SUMMARY: fleet proxy credits top-up request
MD

# Run the notifier with the fixture env. The question-delivery path is
# neutralised (no intake json); the starvation gate runs before the
# probe/delivery path, so no hermes call is expected for the suppression
# case. The false-hermes records a marker if it IS called (a regression).
cat > "$scratch/false-hermes" <<'SH'
#!/usr/bin/env bash
echo "CALLED" > "$1_CALL_MARKER" 2>/dev/null || true
echo "CALLED" >> "$scratch/hermes-called.marker" 2>/dev/null || true
exit 1
SH
chmod +x "$scratch/false-hermes"

notify_out="$(UNIT_ESCALATION_AGENT_STATE="$AS" \
              BOUNDARY_NOTIFY_CAPS="$scratch/caps/seat-caps.json" \
              BOUNDARY_NOTIFY_SEAT_LEDGER="$SEAT_DIR" \
              FLEET_INTAKE_REPOS_JSON="$scratch/no-intake.json" \
              BOUNDARY_NOTIFY_HERMES="$scratch/false-hermes" \
              "$notify" 2>&1 || true)"

echo "$notify_out" | grep -q "suppressed (fleet not starved, fleet-ops#4627)" \
  || fail "notifier must suppress MONEY-BOUNDARY lines when the fleet is not starved: $notify_out"
ok "notifier suppresses MONEY-BOUNDARY lines when the fleet is not starved (defense-in-depth)"

# Both lines must be revoked in the file.
revoked_count="$(grep -c "REVOKED-BY-STARVATION-GATE" "$NISH" || true)"
[[ "$revoked_count" -ge 2 ]] \
  || fail "both 2026-09-09 lines must be revoked, got $revoked_count"
ok "both 2026-09-09 MONEY-BOUNDARY lines revoked by the starvation gate"

# Neither line must have been delivered (no hermes call for suppressed lines).
[[ -f "$scratch/hermes-called.marker" ]] \
  && fail "hermes must NOT be called for suppressed lines" || true
ok "no hermes delivery for suppressed MONEY-BOUNDARY lines"

# --- 3. alert expression: gated on fleet starvation ------------------------
python3 - "$rules" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    groups = yaml.safe_load(f)["groups"]
rules = [r for g in groups for r in g["rules"]]
mb = [r for r in rules if r.get("alert") == "FleetProviderSpendBoundary"]
assert len(mb) == 1, f"expected one FleetProviderSpendBoundary, got {len(mb)}"
expr = mb[0]["expr"]
# The starvation gate: the alert fires only when the fleet is starved
# (fleet_seat_healthy{class=~"prepaid|free"} == 0 or absent).
assert "fleet_seat_healthy" in expr, \
    "FleetProviderSpendBoundary expr must key on fleet_seat_healthy (starvation gate)"
assert 'class=~"prepaid|free"' in expr, \
    "FleetProviderSpendBoundary expr must match class=~\"prepaid|free\""
assert "absent(" in expr, \
    "FleetProviderSpendBoundary expr must handle the absent-series case (starved)"
assert "and on()" in expr, \
    "FleetProviderSpendBoundary expr must AND the boundary with the starvation gate"
desc = mb[0]["annotations"]["description"]
assert "starved" in desc.lower(), \
    "FleetProviderSpendBoundary description must mention fleet starvation"
print("OK: FleetProviderSpendBoundary expr is gated on fleet starvation")
PY

# --- 4. metric: fleet_seat_healthy{class=~"prepaid|free"} ------------------
# The exporter must emit fleet_seat_healthy with class labels "prepaid" and
# "free" (not "prepaid-quota") so the issue's class=~"prepaid|free" regex
# matches in PromQL (=~ is fully anchored).
python3 - "$metrics" <<'PY'
import sys
src = open(sys.argv[1]).read()
# The counts dict must use "prepaid" not "prepaid-quota" as the label.
assert '"prepaid": 0' in src, \
    "exporter counts dict must use 'prepaid' label, not 'prepaid-quota'"
assert '"free": 0' in src, \
    "exporter counts dict must use 'free' label"
# The prepaid-quota -> prepaid mapping must be present.
assert 'cls == "prepaid-quota"' in src, \
    "exporter must map prepaid-quota -> prepaid for the metric label"
assert 'nish_boundary_money_pages_total' in src, \
    "exporter must emit nish_boundary_money_pages_total counter"
assert 'fleet_seat_healthy' in src, \
    "exporter must emit fleet_seat_healthy gauge"
print("OK: exporter emits fleet_seat_healthy{class=prepaid|free} + nish_boundary_money_pages_total")
PY

ok "money-boundary starvation-gate drill: writer suppresses, notifier revokes, alert gated, metric labeled (fleet-ops#4627)"
