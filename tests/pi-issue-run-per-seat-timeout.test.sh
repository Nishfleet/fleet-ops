#!/usr/bin/env bash
# tests/pi-issue-run-per-seat-timeout.test.sh
#
# fleet-ops#3873: ollama/deepseek-v4-flash:0731 rc=124 mid-session death +
# 8/8 empty runs in 2h. The seat answers 200 and does 14-149 tool calls,
# then the global 2520s (42 min) hang watchdog kills the run before final
# text — every run scored as worked-no-text / empty.
#
# Two fixes this test pins:
#
# 1. Per-seat hang_timeout_s override (acceptance point a):
#    seat-caps.json declares a provider-level hang_timeout_s; seatlib.sh
#    seat_hang_timeout_s reads it and falls back to the global default
#    (2520). pi-issue-run uses the per-seat value when PI_HANG_TIMEOUT_S
#    is NOT set in the env (tests that set it win).
#
# 2. Worked-no-text not scored as empty (acceptance points b/c):
#    The fleet metrics exporter counts a watch.log line as an empty
#    run when it contains "stdout=0B" or "no-op". The worked-no-text log
#    line previously contained BOTH ("stdout=0B" and "NOT a provider
#    no-op"), so every worked-no-text run inflated empty_runs_last_2h and
#    drove the empty-run-burst-canary. The line now says "out=0B" and
#    drops the "no-op" phrase so the gather lambda no longer matches.
#    A genuine provider no-op line (stdout < OUT_MIN, tools=0) still
#    contains "stdout=0B" and "no-op" — those MUST still match.
#
# Runs offline: no network, no systemd, stubbed pi.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/litellm-seat.sh"
bin="$repo_root/bin/pi-issue-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seatlib.sh not found: $lib"
[[ -x "$bin" ]] || fail "pi-issue-run not executable: $bin"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t pi-issue-per-seat-timeout.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"

# P14 / fleet-ops#568 class lock: pi-issue-run tests must carry the
# App-identity stub markers so the #568 lock in pi-issue-run-failure-
# reason.test.sh does not reject this file. This test sources seatlib.sh
# directly (unit-level, no pi invocation), but the suite-wide lock requires
# the markers regardless.
mkdir -p "$HOME/.config/fleet-worker"
: >"$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"
stub_token_bin="$scratch/stub-bin"
mkdir -p "$stub_token_bin"
cat >"$stub_token_bin/worker-token" <<'STUB'
#!/usr/bin/env bash
printf 'export GH_TOKEN=fake-test-token-cccccccccccccccc\n'
exit 0
STUB
chmod +x "$stub_token_bin/worker-token"
export WORKER_TOKEN_BIN="$stub_token_bin/worker-token"

# --- 1. seat_hang_timeout_s: per-seat override + fallback ----------------
# Source seatlib with a scratch seat-caps.json that gives ollama a 2640s
# override and leaves devin without one (must fall back to 2520).
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_PACKET_STATE="$scratch/state"
mkdir -p "$PI_PACKET_STATE"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_MODELS_JSON="$scratch/models.json"

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "ollama": { "models": [ { "id": "deepseek-v4-flash:0731", "cost": { "input": 0 } } ] },
    "devin":  { "models": [ { "id": "glm-5-2", "cost": { "input": 0 } } ] }
  }
}
JSON

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "providers": {
    "ollama": { "cap": 8, "class": "prepaid-quota", "hang_timeout_s": 2640, "models": { "deepseek-v4-flash:0731": 8 } },
    "devin":  { "cap": 4, "class": "subscription", "models": { "glm-5-2": 4 } }
  }
}
JSON

# shellcheck source=/dev/null
source "$lib"

# ollama has the override -> 2640
v=$(seat_hang_timeout_s "ollama" "deepseek-v4-flash:0731")
[[ "$v" == "2640" ]] || fail "seat_hang_timeout_s ollama: expected 2640, got $v"
ok "seat_hang_timeout_s: ollama override = 2640s"

# devin has no override -> default 2520
v=$(seat_hang_timeout_s "devin" "glm-5-2")
[[ "$v" == "2520" ]] || fail "seat_hang_timeout_s devin: expected 2520 (default), got $v"
ok "seat_hang_timeout_s: devin fallback = 2520s"

# An unknown provider -> default 2520
v=$(seat_hang_timeout_s "unknown" "unknown-model")
[[ "$v" == "2520" ]] || fail "seat_hang_timeout_s unknown: expected 2520, got $v"
ok "seat_hang_timeout_s: unknown provider fallback = 2520s"

# A sub-60 override is ignored (defensive) -> default
cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "providers": {
    "ollama": { "cap": 8, "class": "prepaid-quota", "hang_timeout_s": 30, "models": { "deepseek-v4-flash:0731": 8 } }
  }
}
JSON
_seat_caps_loaded=0  # force reload
v=$(seat_hang_timeout_s "ollama" "deepseek-v4-flash:0731")
[[ "$v" == "2520" ]] || fail "seat_hang_timeout_s sub-60 override: expected 2520 (ignored), got $v"
ok "seat_hang_timeout_s: sub-60 override ignored, fallback = 2520s"

# --- 2. worked-no-text log line does NOT match the gather empty_run lambda --
# The fleet metrics exporter empty_run lambda is:
#   ("stdout=0B" in l) or ("no-op" in l.lower())
# The worked-no-text line must NOT match. A genuine provider-no-op line MUST.
gather_empty_run_match() {
    local l="$1"
    [[ "$l" == *"stdout=0B"* ]] && return 0
    local low
    low=$(printf '%s' "$l" | tr '[:upper:]' '[:lower:]')
    [[ "$low" == *"no-op"* ]] && return 0
    return 1
}

# The worked-no-text line as pi-issue-run now writes it (out=0B, no "no-op").
wnt_line="pi-issue-run: fleet-ops-3873 session on ollama/deepseek-v4-flash:0731 made 82 tool calls but printed no final text (out=0B) — worked-no-text; seat not benched (fleet-ops#3714)"
if gather_empty_run_match "$wnt_line"; then
    fail "worked-no-text line matches gather empty_run lambda — must NOT (would inflate empty_runs_last_2h): $wnt_line"
fi
ok "worked-no-text line does NOT match gather empty_run lambda"

# A genuine provider-no-op line MUST still match (it IS an empty run).
noop_line="pi-issue-run: fleet-ops-378 pi exited 0 but stdout=0B (< 20B) — provider no-op, benching seat (empty_run, geometric cooldown) and re-seating in-process"
if ! gather_empty_run_match "$noop_line"; then
    fail "provider-no-op line no longer matches gather empty_run lambda — genuine empty runs must still be counted: $noop_line"
fi
ok "provider-no-op line still matches gather empty_run lambda (genuine empty run)"

# --- 3. the pi-issue-run source writes the worked-no-text line without the
# gather-matching strings. Static check so a future edit cannot regress.
if grep -n 'made.*tool calls but printed no final text' "$bin" | grep -q 'stdout='; then
    fail "pi-issue-run worked-no-text line still contains 'stdout=' — would match gather empty_run lambda"
fi
if grep -n 'made.*tool calls but printed no final text' "$bin" | grep -qi 'no-op'; then
    fail "pi-issue-run worked-no-text line still contains 'no-op' — would match gather empty_run lambda"
fi
ok "pi-issue-run source: worked-no-text line free of 'stdout=' and 'no-op'"

echo "ALL OK: per-seat timeout override + worked-no-text not scored as empty (fleet-ops#3873)"
