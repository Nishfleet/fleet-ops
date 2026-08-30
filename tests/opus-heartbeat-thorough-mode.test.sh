#!/usr/bin/env bash
# tests/opus-heartbeat-thorough-mode.test.sh
#
# fleet-ops#1382: the opus-heartbeat-thorough.{service,timer} scaffold runs
# the SAME launcher as the light 2h opus-heartbeat, with OPUS_HB_THOROUGH=1.
# Before this fix the env var was IGNORED — the thorough run produced the
# same light snapshot and the same 30-line verdict as the hourly tick.
#
# This test proves the three mechanical pieces that make THOROUGH actually
# thorough, all offline (no live Opus, no live Prometheus):
#
#   1. opus-heartbeat-gather honors OPUS_HB_THOROUGH=1: the JSON snapshot
#      gains a "thorough" object (mode=THOROUGH, slots_present non-empty,
#      every rotation slot present) ONLY when the env is set. The light
#      run (env unset) has NO "thorough" key and window_s stays 7200.
#   2. opus-heartbeat (the launcher) appends a "MODE: THOROUGH" note to
#      the judge prompt ONLY when OPUS_HB_THOROUGH=1, via the
#      --print-prompt self-check flag (short-circuits before gather/Opus).
#      The light --print-prompt output has zero "MODE: THOROUGH" lines.
#   3. judge-prompt.md carries a static THOROUGH-mode section naming the
#      deep-battery slots and the 60-line cap, so the contract is in the
#      prompt file itself (defense in depth — the dynamic note is additive).
#   4. The thorough service unit sets OPUS_HB_THOROUGH=1 AND the same
#      HOME/PATH/XDG_RUNTIME_DIR env as the light unit AND a TimeoutStartSec
#      >= the light unit's, so the deep pass can actually run end-to-end.
#
# Sandbox: scratch OPUS_HB_STATE; PROM_URL points at a dead port so promql
# degrades gracefully (the gather is defensive — a missing Prometheus is
# data, not a crash). The live host snapshot/journal are never mutated.
#
# Scenarios (fleet-ops#366 mechanical-fix shape):
#   1. gather LIGHT (env unset) -> no "thorough" key, window_s=7200.
#   2. gather THOROUGH (env=1) -> "thorough" key, mode=THOROUGH,
#      slots_present has all 12 slots, no slot has an "error" that is a
#      crash marker (a slot may legitimately return present:false; that is
#      not a crash). window_s stays 7200 (the trend is a separate field).
#   3. launcher --print-prompt LIGHT -> 0 "MODE: THOROUGH" lines.
#   4. launcher --print-prompt THOROUGH -> >=1 "MODE: THOROUGH" line AND
#      the "60 output lines" cap phrase.
#   5. judge-prompt.md has the static "Fleet-ops#1382" THOROUGH section
#      header AND names "60" AND names every deep-battery slot.
#   6. opus-heartbeat-thorough.service sets OPUS_HB_THOROUGH=1, HOME,
#      PATH, XDG_RUNTIME_DIR, and TimeoutStartSec.
#   7. The launcher source contains the OPUS_HB_THOROUGH branch and the
#      --print-prompt self-check (guard against a future refactor deleting
#      the mode wiring).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

LAUNCHER="${OPUS_HB_LAUNCHER:-/home/nish/.local/libexec/opus-heartbeat}"
GATHER="${OPUS_HB_GATHER:-/home/nish/.local/libexec/opus-heartbeat-gather}"
PROMPT_FILE="${OPUS_HB_PROMPT_FILE:-/home/nish/.local/share/opus-heartbeat/judge-prompt.md}"
THOROUGH_SERVICE="${OPUS_HB_THOROUGH_SERVICE:-/home/nish/.config/systemd/user/opus-heartbeat-thorough.service}"
# A dead port: promql returns _error, host_stats scalars go None — gather
# must stay defensive. 127.0.0.1:9 is discard + closed on most boxes.
DEAD_PROM="${OPUS_HB_DEAD_PROM:-http://127.0.0.1:9}"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$LAUNCHER" ]] || fail "launcher not executable: $LAUNCHER"
[[ -x "$GATHER" ]]  || fail "gather not executable: $GATHER"
[[ -s "$PROMPT_FILE" ]] || fail "judge prompt missing: $PROMPT_FILE"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

TMPD="$(mktemp -d -t opus-1382.XXXXXX)"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT INT TERM

# --- 1. gather LIGHT (env unset) -------------------------------------------
python3 "$GATHER" >"$TMPD/light.json" 2>"$TMPD/light.err" \
  OPUS_HB_STATE="$TMPD" PROM_URL="$DEAD_PROM" \
  || fail "gather LIGHT failed rc=$? (gather must be defensive vs dead Prometheus)"
python3 - "$TMPD/light.json" <<'PY' || fail "test 1 assertion failed"
import json, sys
d = json.load(open(sys.argv[1]))
assert "thorough" not in d, "light snapshot must NOT carry a thorough key"
assert d.get("window_s") == 7200, f"light window_s must stay 7200, got {d.get('window_s')}"
print("OK: test 1: gather LIGHT has no thorough key, window_s=7200")
PY

# --- 2. gather THOROUGH (env=1) --------------------------------------------
OPUS_HB_THOROUGH=1 OPUS_HB_STATE="$TMPD" PROM_URL="$DEAD_PROM" \
  python3 "$GATHER" >"$TMPD/thorough.json" 2>"$TMPD/thorough.err" \
  || fail "gather THOROUGH failed rc=$? (a slot fault is data, not a crash)"
python3 - "$TMPD/thorough.json" <<'PY' || fail "test 2 assertion failed"
import json, sys
d = json.load(open(sys.argv[1]))
assert "thorough" in d, "thorough snapshot MUST carry a thorough key"
t = d["thorough"]
assert t.get("mode") == "THOROUGH", f"thorough.mode must be THOROUGH, got {t.get('mode')}"
slots = t.get("slots_present") or []
expected = {
    "user_journey_probe", "random_merged_pr_verify", "one_drill",
    "seat_probes_walled_comebacks", "doc_claims_sample", "backup_freshness",
    "hygiene_counts", "escalation_drain", "quality_shares", "gh_budget",
    "tailscale_reboot_spot", "trend_24h",
}
got = set(slots)
missing = expected - got
assert not missing, f"thorough slots missing: {sorted(missing)}"
# A slot may return present:false or an error object (dead Prometheus, no
# seat ledger in scratch) — that is data, NOT a crash. We only assert the
# slot key exists and is a dict. The judge flags present:false as it sees fit.
slot_map = t.get("slots") or {}
for k in expected:
    assert k in slot_map, f"slot {k} missing from thorough.slots"
    assert isinstance(slot_map[k], dict), f"slot {k} is not a dict"
# window_s stays 7200 (the 24h trend is thorough.window_s, a separate field)
assert d.get("window_s") == 7200, f"top-level window_s must stay 7200, got {d.get('window_s')}"
assert t.get("window_s") == 86400, f"thorough.window_s must be 86400, got {t.get('window_s')}"
print(f"OK: test 2: gather THOROUGH has all {len(expected)} slots, mode=THOROUGH, trend window=86400")
PY

# --- 3. launcher --print-prompt LIGHT --------------------------------------
# The dynamic note has a distinctive phrase ("MODE: THOROUGH — this is the
# 6-hourly deep pass") that the static prompt section's backtick reference
# does not match. Light mode must append ZERO dynamic notes.
LIGHT_PROMPT="$(OPUS_HB_STATE="$TMPD" "$LAUNCHER" --print-prompt 2>"$TMPD/pp-light.err")" \
  || fail "launcher --print-prompt LIGHT failed rc=$?"
light_mode_n="$(printf '%s\n' "$LIGHT_PROMPT" | grep -c 'MODE: THOROUGH — this is the 6-hourly deep pass' || true)"
[[ "$light_mode_n" -eq 0 ]] \
  || fail "test 3: light --print-prompt must have 0 dynamic MODE: THOROUGH notes, got $light_mode_n"
ok "test 3: launcher --print-prompt LIGHT has no dynamic MODE: THOROUGH note"

# --- 4. launcher --print-prompt THOROUGH -----------------------------------
THOROUGH_PROMPT="$(OPUS_HB_THOROUGH=1 OPUS_HB_STATE="$TMPD" "$LAUNCHER" --print-prompt 2>"$TMPD/pp-thorough.err")" \
  || fail "launcher --print-prompt THOROUGH failed rc=$?"
thorough_mode_n="$(printf '%s\n' "$THOROUGH_PROMPT" | grep -c 'MODE: THOROUGH — this is the 6-hourly deep pass' || true)"
[[ "$thorough_mode_n" -ge 1 ]] \
  || fail "test 4: thorough --print-prompt must have >=1 dynamic MODE: THOROUGH note, got $thorough_mode_n"
printf '%s\n' "$THOROUGH_PROMPT" | grep -q '60 output lines' \
  || fail "test 4: thorough --print-prompt must mention the 60-line cap"
ok "test 4: launcher --print-prompt THOROUGH has dynamic MODE: THOROUGH + 60-line cap"

# --- 5. judge-prompt.md static THOROUGH section ----------------------------
grep -qF 'Fleet-ops#1382' "$PROMPT_FILE" \
  || fail "test 5: judge prompt missing the Fleet-ops#1382 THOROUGH section header"
grep -qE 'up to 60 output lines' "$PROMPT_FILE" \
  || fail "test 5: judge prompt missing the 60-line cap in the THOROUGH section"
# every deep-battery slot named in the static section
for slot in user-journey random merged-PR VERIFY resilience drill walled comeback doc-claims backup freshness hygiene escalation drain quality shares gh budget tailscale reboot 24h trend; do
  grep -qi -- "$slot" "$PROMPT_FILE" \
    || fail "test 5: judge prompt THOROUGH section does not name slot hint: $slot"
done
ok "test 5: judge-prompt.md has static THOROUGH section + 60-line cap + all slot names"

# --- 6. thorough service unit ----------------------------------------------
[[ -f "$THOROUGH_SERVICE" ]] || fail "test 6: thorough service unit missing at $THOROUGH_SERVICE"
grep -q 'OPUS_HB_THOROUGH=1' "$THOROUGH_SERVICE" \
  || fail "test 6: thorough service does not set OPUS_HB_THOROUGH=1"
grep -q 'Environment=HOME=' "$THOROUGH_SERVICE" \
  || fail "test 6: thorough service missing HOME env (light unit has it)"
grep -q 'Environment=PATH=' "$THOROUGH_SERVICE" \
  || fail "test 6: thorough service missing PATH env (light unit has it)"
grep -q 'Environment=XDG_RUNTIME_DIR=' "$THOROUGH_SERVICE" \
  || fail "test 6: thorough service missing XDG_RUNTIME_DIR env (light unit has it)"
grep -q 'TimeoutStartSec=' "$THOROUGH_SERVICE" \
  || fail "test 6: thorough service missing TimeoutStartSec (deep pass needs room)"
ok "test 6: opus-heartbeat-thorough.service sets THOROUGH=1 + HOME/PATH/XDG + TimeoutStartSec"

# --- 7. launcher source guards ---------------------------------------------
grep -q 'OPUS_HB_THOROUGH' "$LAUNCHER" \
  || fail "test 7: launcher source has no OPUS_HB_THOROUGH branch"
grep -q -- '--print-prompt' "$LAUNCHER" \
  || fail "test 7: launcher source has no --print-prompt self-check"
grep -q 'MODE: THOROUGH' "$LAUNCHER" \
  || fail "test 7: launcher source does not emit MODE: THOROUGH"
ok "test 7: launcher source has OPUS_HB_THOROUGH branch + --print-prompt + MODE note"

echo "ALL OK: opus-heartbeat THOROUGH mode wired end-to-end (fleet-ops#1382)"
