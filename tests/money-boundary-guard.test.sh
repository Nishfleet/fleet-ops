#!/usr/bin/env bash
# tests/money-boundary-guard.test.sh
#
# fleet-ops#4477 guard (fleet-ops#366 mechanical-fix prevention): a provider
# whose seats are benched source=money_boundary MUST have a matching
# MONEY-BOUNDARY line in NISH-ESCALATIONS.md. The 2026-09-07/08 defect this
# closes was the repair worker benching entrim's seat and writing the
# spend-boundary-prebench backup but dropping the ledger append (a prompt
# step, not code, so droppable) — so Nish's phone was never pinged about the
# money wall.
#
# This drill proves the enforcement loop end to end, hermetically:
#   1. bin/money-boundary-raise writes the MONEY-BOUNDARY ledger line BEFORE
#      it benches a seat, and FAIL-LOUDs (aborts the bench) if the ledger
#      line cannot be proven written.
#   2. Dedupe: a second raise for the SAME provider on the SAME UTC day is a
#      no-op on the ledger (one phone ping per wall per day).
#   3. Guard --check: a seat benched source=money_boundary with no matching
#      MONEY-BOUNDARY provider=<p> line exits 1 LOUD; when the line is
#      present it is clean. Both the live seat dir and the
#      spend-boundary-prebench-* backup copies are scanned.
#   4. config/fleet_rules.yml FleetProviderSpendBoundary instructs the repair
#      worker to run bin/money-boundary-raise (not hand-written discretionary
#      steps) — the deterministic dispatch path.
#
# Offline: uses a scratch agent-state dir via env overrides; touches nothing
# live. Hosted from tests/rule-enforcement.test.sh so P14 runs it.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/bin/money-boundary-raise"
rules="$repo_root/config/fleet_rules.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "missing: $script"
[[ -x "$script" ]] || fail "not executable: $script"
[[ -f "$rules" ]] || fail "missing: $rules"
command -v jq >/dev/null 2>&1 || fail "jq missing"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT INT TERM

AS="$scratch/as"
mkdir -p "$AS/lanes/seats" "$AS/alert-repair" "$scratch/caps"

# --- fixture: a small seat-caps roster for the raise -----------------------
cat > "$scratch/caps/seat-caps.json" <<'JSON'
{
  "providers": {
    "entrim": {
      "models": {
        "deepseek-ai/DeepSeek-V4-Flash": {"cap": 2},
        "disabled-model": {"cap": 0}
      }
    }
  }
}
JSON

run_raise() {
  MONEY_BOUNDARY_AS="$AS" \
  MONEY_BOUNDARY_CAPS="$scratch/caps/seat-caps.json" \
  "$script" "$@" 2>&1
}

# --- 3a. FAIL-LOUD: bench attempt without a provable ledger line -----------
# A seat bench MUST be preceded by a provable ledger write. Force the append
# to fail (read-only ledger dir) and assert the raise exits 1 LOUD without
# benching.
ro_dir="$scratch/ro-as"
mkdir -p "$ro_dir"
chmod 500 "$ro_dir"
if MONEY_BOUNDARY_AS="$ro_dir" \
   MONEY_BOUNDARY_CAPS="$scratch/caps/seat-caps.json" \
   "$script" entrim 8.1 N/A >/dev/null 2>&1; then
  fail "raise must FAIL-LOUD (non-zero) when the ledger ledger line cannot be written"
fi
# It must not have written any bench seat while failing.
find "$ro_dir" -type f -name '*.json' ! -path '*seat-caps.json' | grep -q . \
  && fail "raise that FAIL-LOUDs must NOT bench a seat" || true
[[ -f "$ro_dir/NISH-ESCALATIONS.md" ]] \
  && fail "raise that FAIL-LOUDs must NOT have written the ledger either (unwritable dir)" || true
ok "raise FAIL-LOUDs and aborts the bench when the ledger line cannot be proven written"
chmod 700 "$ro_dir"

# --- 1. raise writes ledger BEFORE bench, in one run -----------------------
out="$(run_raise entrim 8.12371 N/A)"
echo "$out" | grep -q "appended ledger line" \
  || fail "raise must report the ledger append: $out"
echo "$out" | grep -q "benched" \
  || fail "raise must report the bench: $out"
[[ -f "$AS/NISH-ESCALATIONS.md" ]] || fail "ledger file not created"
[[ -f "$AS/lanes/seats/entrim__deepseek-ai_DeepSeek-V4-Flash.json" ]] \
  || fail "bench seat not written"
[[ -f "$AS/lanes/seats/entrim__deepseek-ai_DeepSeek-V4-Flash.spawn-bench.json" ]] \
  || fail "spawn-bench marker not written (fleet-ops#5204 clobber-proof hold)"
sb_src="$(jq -r '.source // empty' "$AS/lanes/seats/entrim__deepseek-ai_DeepSeek-V4-Flash.spawn-bench.json")"
[[ "$sb_src" == "money_boundary" ]] \
  || fail "spawn-bench must carry source=money_boundary, got: $sb_src"
grep -q "Nish-only clear" "$AS/lanes/seats/entrim__deepseek-ai_DeepSeek-V4-Flash.spawn-bench.json" \
  && fail "spawn-bench must not cite Nish-only clear without a ledger ask"
grep -q "MONEY-BOUNDARY provider=entrim" "$AS/NISH-ESCALATIONS.md" \
  || fail "ledger line missing"
[[ -f "$AS/NISH-ESCALATIONS.md" ]] || exit 0
ok "raise appends the MONEY-BOUNDARY ledger line and benches (one run, ledger first)"

# The cap>0 filter must skip the disabled cap:0 model.
[[ -f "$AS/lanes/seats/entrim__disabled-model.json" ]] \
  && fail "raise must NOT bench a cap:0 model"
ok "raise benches only cap>0 models"

# --- 2. dedupe: same provider same UTC day -> no second append -------------
before_count="$(grep -c 'MONEY-BOUNDARY provider=entrim' "$AS/NISH-ESCALATIONS.md")"
out2="$(run_raise entrim 9.9 1.0)"
echo "$out2" | grep -qi "dedupe" || fail "second raise same day must dedupe: $out2"
after_count="$(grep -c 'MONEY-BOUNDARY provider=entrim' "$AS/NISH-ESCALATIONS.md")"
[[ "$before_count" -eq 1 ]] || fail "expected exactly 1 ledger line before dedupe, got $before_count"
[[ "$after_count" -eq 1 ]] || fail "dedupe must NOT append a second line (after=$after_count)"
ok "provider/day dedupe: one phone ping per wall per UTC day"

# --- 3b. guard --check clean after a raise ---------------------------------
MONEY_BOUNDARY_AS="$AS" "$script" --check >/dev/null 2>&1 \
  || fail "guard --check must be clean right after a raise"
ok "guard --check clean when the ledger line exists for every money_boundary seat"

# --- 3c. guard --check FAIL-LOUD on a missing ledger line ------------------
# Add a second money_boundary seat whose provider has NO ledger line.
# observed_at must be inside SINCE_HOURS (default 24h) or --check skips it.
mkdir -p "$AS/lanes/seats"
obs="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
until="$(date -u -d '365 days' +%Y-%m-%dT%H:%M:%SZ)"
cat > "$AS/lanes/seats/orphan__model.json" <<JSON
{
  "provider": "orphan",
  "model": "model",
  "health_class": "quota_bench",
  "retryable": true,
  "seat_dead": false,
  "source": "money_boundary",
  "observed_at": "$obs",
  "bench_until": "$until",
  "usable_at": "$until"
}
JSON
if MONEY_BOUNDARY_AS="$AS" "$script" --check >"$scratch/orphan.log" 2>&1; then
  fail "guard --check must FAIL-LOUD when a money_boundary seat has no ledger line"
fi
grep -q "FAIL-LOUD" "$scratch/orphan.log" || fail "guard failure must be loud (FAIL-LOUD)"
ok "guard --check FAIL-LOUDs on a missing MONEY-BOUNDARY line for a benched provider"

# --- 3d. guard --check scans the spend-boundary-prebench-* backups --------
# Put the orphan seat ONLY in a backup dir (backup-copy scan), and remove it
# from the live seat dir so the second scan path is what catches it.
rm -f "$AS/lanes/seats/orphan__model.json"
bdir="$AS/alert-repair/spend-boundary-prebench-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$bdir"
cat > "$bdir/orphan__model.json" <<JSON
{
  "provider": "orphan",
  "model": "model",
  "health_class": "quota_bench",
  "retryable": true,
  "seat_dead": false,
  "source": "money_boundary",
  "observed_at": "$obs",
  "bench_until": "$until",
  "usable_at": "$until"
}
JSON
if MONEY_BOUNDARY_AS="$AS" "$script" --check >"$scratch/bdir.log" 2>&1; then
  fail "guard --check must FAIL-LOUD when only a backup-copy money_boundary seat has no ledger line"
fi
grep -q "FAIL-LOUD" "$scratch/bdir.log" || fail "backup-scan failure must be loud"
ok "guard --check scans the spend-boundary-prebench-* backup copies for gaps"

# --- 4. the alert rule routes the worker to the deterministic script -------
python3 - "$rules" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    groups = yaml.safe_load(f)["groups"]
rules = [r for g in groups for r in g["rules"]]
mb = [r for r in rules if r.get("alert") == "FleetProviderSpendBoundary"]
assert len(mb) == 1, f"expected one FleetProviderSpendBoundary, got {len(mb)}"
desc = mb[0]["annotations"]["description"]
assert "bin/money-boundary-raise" in desc, \
    "FleetProviderSpendBoundary must route the repair worker to bin/money-boundary-raise (deterministic path)"
assert "MONEY-BOUNDARY" in desc and "ledger" in desc, \
    "description must still mention the MONEY-BOUNDARY ledger write"
print("OK: FleetProviderSpendBoundary routes the repair worker to bin/money-boundary-raise")
PY

# --- 5. bare-int model cap gets benched (fleet-ops#4658) -------------------
# A provider whose only model cap is the bare integer 2 (the live straitly
# shape) must be benched. The old roster select `select(.value.cap > 0)` made
# `.value.cap` null on a number, dropping the row and benching 0 seats.
# Also assert a bare-int cap:0 is still skipped (not benched).
bare_as="$scratch/bare-as"
mkdir -p "$bare_as/lanes/seats" "$bare_as/alert-repair"
cat > "$scratch/caps/seat-caps-bare-int.json" <<'JSON'
{
  "providers": {
    "straitly": {
      "models": {
        "deepseek/deepseek-v4-pro": 2,
        "zero-bare-int": 0
      }
    }
  }
}
JSON
bare_out="$(MONEY_BOUNDARY_AS="$bare_as" \
  MONEY_BOUNDARY_CAPS="$scratch/caps/seat-caps-bare-int.json" \
  "$script" straitly 5.0 N/A 2>&1)"
echo "$bare_out" | grep -q "1 seat(s) benched" \
  || fail "bare-int cap must bench exactly 1 seat (got: $bare_out)"
[[ -f "$bare_as/lanes/seats/straitly__deepseek_deepseek-v4-pro.json" ]] \
  || fail "bare-int cap:2 model was not benched (seat file missing)"
[[ -f "$bare_as/lanes/seats/straitly__zero-bare-int.json" ]] \
  && fail "bare-int cap:0 must NOT be benched"
ok "bare-int model cap is benched (cap:2 yes, cap:0 no) — fleet-ops#4658"

# --- 6. fleet-ops#5204: --check sees legacy spawn-bench year-walls ----------
# The five 2027 markers carried no source/health_class. Unpaged -> rc!=0;
# a matching ledger line reconciles -> rc=0. A 6h money_boundary row is
# not a Nish-year wall and must not fail the guard.
legacy_as="$scratch/legacy-as"
mkdir -p "$legacy_as/lanes/seats" "$legacy_as/alert-repair"
until="$(date -u -d '365 days' +%Y-%m-%dT%H:%M:%SZ)"
cat > "$legacy_as/lanes/seats/minimax__MiniMax-M3.spawn-bench.json" <<JSON
{
  "provider": "minimax",
  "model": "MiniMax-M3",
  "usable_at": "$until",
  "reason": "money boundary fleet-ops#3284 — Nish-only clear",
  "written_at": "2026-09-08T09:36:52Z",
  "backoff_s": 31536000,
  "failure_mode": "quota_cap",
  "writer": "alert-repair-FleetProviderSpendBoundary-20260908T092614Z"
}
JSON
: > "$legacy_as/NISH-ESCALATIONS.md"
if MONEY_BOUNDARY_AS="$legacy_as" "$script" --check >"$scratch/legacy.log" 2>&1; then
  fail "unpaged live spawn-bench year-wall must FAIL-LOUD: $(cat "$scratch/legacy.log")"
fi
grep -q "FAIL-LOUD" "$scratch/legacy.log" || fail "legacy spawn-bench failure must be loud"
ok "unpaged live spawn-bench year-wall -> rc!=0 (fleet-ops#5204)"

printf '%s MONEY-BOUNDARY provider=minimax spend_today_usd=N/A credits_remaining_usd=N/A — reconciled year-wall\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$legacy_as/NISH-ESCALATIONS.md"
MONEY_BOUNDARY_AS="$legacy_as" "$script" --check >/dev/null 2>&1 \
  || fail "reconciled spawn-bench year-wall must be clean"
ok "reconciled live spawn-bench year-wall -> rc=0"

sixh="$(date -u -d '6 hours' +%Y-%m-%dT%H:%M:%SZ)"
obs="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
cat > "$legacy_as/lanes/seats/xai-oauth__grok-4.6.json" <<JSON
{
  "provider": "xai-oauth",
  "model": "grok-4.6",
  "source": "money_boundary",
  "health_class": "quota_bench",
  "usable_at": "$sixh",
  "bench_until": "$sixh",
  "observed_at": "$obs",
  "writer": "mark_seat_quota_bench"
}
JSON
MONEY_BOUNDARY_AS="$legacy_as" "$script" --check >/dev/null 2>&1 \
  || fail "6h money_boundary quota bench must not fail the 30-day money-wall guard"
ok "6h money_boundary quota bench is outside the 30-day horizon"

# Historical prebench snapshot (age window): a 2026-09-08 dir must not fail
# forever when the live wall is already reconciled.
old_bdir="$legacy_as/alert-repair/spend-boundary-prebench-20260908T070501Z"
mkdir -p "$old_bdir"
cat > "$old_bdir/openrouter__minimax_minimax-m3_free.json" <<JSON
{
  "provider": "openrouter",
  "model": "minimax/minimax-m3:free",
  "source": "money_boundary",
  "health_class": "quota_bench",
  "usable_at": "$until",
  "bench_until": "$until"
}
JSON
MONEY_BOUNDARY_AS="$legacy_as" "$script" --check >/dev/null 2>&1 \
  || fail "historical spend-boundary-prebench snapshot must not fail --check forever"
ok "historical prebench snapshot is aged out of --check"

# Minute-only stamp (live 20260907T2211Z dirs) must also age out.
old_bdir2="$legacy_as/alert-repair/spend-boundary-prebench-20260907T2211Z"
mkdir -p "$old_bdir2"
cat > "$old_bdir2/openrouter__z-ai_glm-5.2_free.json" <<JSON
{
  "provider": "openrouter",
  "model": "z-ai/glm-5.2:free",
  "source": "money_boundary",
  "health_class": "quota_bench",
  "usable_at": "$until",
  "bench_until": "$until"
}
JSON
MONEY_BOUNDARY_AS="$legacy_as" "$script" --check >/dev/null 2>&1 \
  || fail "minute-only historical prebench stamp must age out"
ok "historical prebench minute-only stamp is aged out of --check"

# --- 7. heartbeat-tier1 wires --check and propagates rc>=2 only ------------
tier1="$repo_root/bin/fleet-heartbeat-tier1"
grep -q 'money-boundary-raise --check' "$tier1" \
  || fail "heartbeat-tier1 must call money-boundary-raise --check (fleet-ops#5204)"
grep -q 'money_boundary_check_rc' "$tier1" \
  || fail "heartbeat-tier1 must track money_boundary_check_rc"
grep -q 'money_boundary_check_rc.*-ge 2' "$tier1" \
  || fail "heartbeat-tier1 must propagate money_boundary_check_rc only on rc>=2"
grep -q 'bin/money-boundary-raise' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/money-boundary-raise"
ok "heartbeat-tier1 wires the guard (rc>=2 only) + MANIFEST dest"

ok "money-boundary guard drill: deterministic raise, dedupe, FAIL-LOUD, --check, backup scan, rule routing, and #5204 legacy-wall/age-window/heartbeat wiring"
