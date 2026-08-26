#!/usr/bin/env bash
# tests/pi-packet-run.test.sh
#
# Proves the pi-packet-run seat-rotation wrapper:
#   1. picks a DIFFERENT seat on the second attempt,
#   2. records every tried seat in the tried-seats file,
#   3. resets (removes) the tried-seats file on success,
#   4. calls pi with the selected provider and model.
#
# Runs offline: pick_seat, systemctl and pi are all stubbed. No Claude, no
# systemd user session, no network.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-packet-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t pi-packet-run.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/bin" "$scratch/state/attempts"

# --- stub seat-lib.sh --------------------------------------------------------
# The real lib calls systemctl and reads models.json/cap-maps. We override the
# three functions pi-packet-run actually uses and set the state paths it needs.
fake_seat_lib="$scratch/seat-lib.sh"
cat >"$fake_seat_lib" <<'LIB'
# shellcheck shell=bash
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export HOME="${HOME:-/home/nish}"

ATTEMPTS_DIR="${PI_PACKET_STATE:-$HOME/.local/state/pi-packet}/attempts"
mkdir -p "$ATTEMPTS_DIR"

packet_id_from_path() {
  echo "testpkt"
}

task_weight() {
  echo "light"
}

# fleet-ops#520: stub the privacy helpers the wrapper now calls.
repo_privacy() { echo "public"; }
packet_repo() { echo ""; }

# First call (empty tried file) returns devin/glm-5-2. Once devin is in the
# tried-seats file, return a different seat (cursor/composer-2.5).
pick_seat() {
  local tried_file="${4:-}"
  if [[ -n "$tried_file" && -f "$tried_file" ]] \
      && grep -qx 'devin/glm-5-2' "$tried_file"; then
    printf 'cursor\tcomposer-2.5\n'
  else
    printf 'devin\tglm-5-2\n'
  fi
}

seat_log() {
  true
}
LIB

# --- stub pi -----------------------------------------------------------------
fake_pi="$scratch/bin/pi"
cat >"$fake_pi" <<'PI'
#!/usr/bin/env bash
prov="" mod=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) prov="$2"; shift 2 ;;
    --model)    mod="$2"; shift 2 ;;
    --print)    shift ;;
    *)          shift ;;
  esac
done
printf '%s/%s\n' "$prov" "$mod" >>"${PI_CALLS:-/dev/null}"
if [[ "$prov" == "devin" ]]; then
  echo "devin failed"
  exit 1
fi
# Enough bytes to clear PI_PACKET_RUN_OUT_MIN for the success test.
echo "OK: $prov/$mod completed"
PI
chmod +x "$fake_pi"

# --- stub systemctl ----------------------------------------------------------
# Not used while pick_seat is stubbed, but present so the test environment does
# not accidentally call a live systemctl if the stub lib is ever removed.
fake_systemctl="$scratch/bin/systemctl"
cat >"$fake_systemctl" <<'SCTL'
#!/usr/bin/env bash
echo "systemctl stub: $*" >&2
exit 0
SCTL
chmod +x "$fake_systemctl"

pkt="$scratch/packet.in"
printf 'packet body\n' >"$pkt"

export PI_PACKET_SEAT_LIB="$fake_seat_lib"
export PI_BIN="$fake_pi"
export PI_CALLS="$scratch/pi-calls"
export PI_PACKET_STATE="$scratch/state"
export PI_PACKET_RUN_OUT_MIN=8
export PATH="$scratch/bin:$PATH"

# --- 1. first attempt: empty tried file, picks devin, pi fails ---------------
set +e
out=$("$bin" "$pkt" "$scratch" "" "" 2>&1)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "first run must exit 1, got $rc ($out)"
grep -qx 'devin/glm-5-2' "$scratch/state/attempts/testpkt.tried-seats" \
  || fail "first seat not recorded in tried-seats: $(cat "$scratch/state/attempts/testpkt.tried-seats" 2>/dev/null)"
ok "first run picks devin, records it, and exits 1 when pi fails"

# --- 2. second attempt: devin is excluded, picks cursor, pi succeeds ---------
set +e
out=$("$bin" "$pkt" "$scratch" "" "" 2>&1)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "second run must exit 0, got $rc ($out)"
[[ ! -f "$scratch/state/attempts/testpkt.tried-seats" ]] \
  || fail "tried-seats must be removed on success"

calls="$(cat "$PI_CALLS")"
[[ "$calls" == $'devin/glm-5-2\ncursor/composer-2.5' ]] \
  || fail "pi calls were not the two different seats: $calls"
ok "second run picks cursor, succeeds, and resets tried-seats"

ok "pi-packet-run rotates seats, records tries, and resets on success"
