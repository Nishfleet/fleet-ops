#!/usr/bin/env bash
# tests/fleet-seat-comeback-release-retired.test.sh
#
# fleet-ops#6264: tests/fleet-seat-comeback-release.test.sh failed on a
# pristine origin/main worktree on this VPS (SHA 9cf5a1959) with:
#
#   FAIL: dry-run: long non-money future wall must get the hourly PONG
#   (fleet-ops#4640): ... would probe commandcode/poolside/laguna-s-2.1-free
#   with 'echo $((6*7))' via bash tool (tool-using probe)
#
# CI was green. The case named live VPS state
# ($HOME/.local/state/pi-packet ledger / seat-caps) leaking into the
# harness. Isolating that test is gone with the organ:
#   - bin/fleet-seat-comeback-release deleted in 571bf2098
#     (LiteLLM router cooldown / allowed_fails / fallbacks)
#   - tests/fleet-seat-comeback-release.test.sh deleted in 9f0cba02c
#
# Restoring the 2k-line organ to add an env override would put the glue
# back. This file pins the retired state so the leak cannot return in
# its old form, and pins the leak class on remaining tests/*.test.sh:
# a non-comment line must not default to the live VPS ledger directory.
#
# Hosted by the P14 glob host (tests/p14-test-listing-gate.test.sh,
# fleet-ops#5889). Hermetic: tracked paths + scratch fixtures. No
# network, no systemd, no gh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
SELF="$(basename "${BASH_SOURCE[0]}")"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
skip() { echo "SKIP: $*"; }

# Non-comment lines in ROOT/tests/*.test.sh that default to the live VPS
# ledger dir. SELF is excluded so the fixtures below can quote the path.
LIVE_LEDGER_RE='(\$\{HOME\}|\$HOME|~)/\.local/state/pi-packe[t]'

live_ledger_hits() {
    local root="$1" f line glob
    glob="$(shopt -p nullglob)"
    shopt -s nullglob
    for f in "$root"/tests/*.test.sh; do
        [[ "$(basename "$f")" == "$SELF" ]] && continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[0-9]+:[[:space:]]*# ]] && continue
            printf '%s:%s\n' "$f" "$line"
        done < <(grep -nE "$LIVE_LEDGER_RE" "$f" 2>/dev/null || true)
    done
    eval "$glob"
}

# --- A. the leaking organ and its test stay gone --------------------------
for p in \
    bin/fleet-seat-comeback-release \
    systemd/fleet-seat-comeback-release.service \
    systemd/fleet-seat-comeback-release.timer \
    tests/fleet-seat-comeback-release.test.sh
do
    [[ ! -e "$repo_root/$p" ]] \
        || fail "A. $p is back. It was the #6264 host-state leak surface (deleted 571bf2098 / 9f0cba02c). LiteLLM router cooldown owns come-back now; do not restore the organ to 'fix' the test"
done
ok "A. comeback-release bin, units, and the leaking test file are absent"

# --- B. remaining tests do not default to the live VPS ledger -------------
hits="$(live_ledger_hits "$repo_root")"
if [[ -n "$hits" ]]; then
    {
        echo "FAIL: B. a tests/*.test.sh line defaults to the live VPS ledger (fleet-ops#6264):"
        printf '%s\n' "$hits"
        echo "Point the harness at a scratch dir via an env override. The live"
        echo "\$HOME/.local/state/pi-packet tree is host state, not a fixture."
    } >&2
    exit 1
fi
ok "B. no remaining tests/*.test.sh defaults to the live VPS ledger path"

# --- C. fixtures: the detector has teeth ---------------------------------
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# C1. RED: the exact leak class, a default that falls through to $HOME.
mkdir -p "$scratch/red/tests"
cat >"$scratch/red/tests/leaky.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
ledger="${PI_SEAT_HEALTH_LEDGER_DIR:-$HOME/.local/state/pi-packet}"
echo "$ledger"
FIXTURE
red_hits="$(live_ledger_hits "$scratch/red")"
[[ -n "$red_hits" ]] \
    || fail "C1. detector did NOT fire on a \$HOME/.local/state/pi-packet default. Part B is vacuous"
ok "C1. RED on a live-ledger default (the #6264 leak class)"

# C2. RED on the ~ form too, so the pin is not one-syntax-deep.
mkdir -p "$scratch/tilde/tests"
cat >"$scratch/tilde/tests/leaky.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
ledger=~/.local/state/pi-packet
FIXTURE
tilde_hits="$(live_ledger_hits "$scratch/tilde")"
[[ -n "$tilde_hits" ]] \
    || fail "C2. detector did NOT fire on a ~/.local/state/pi-packet default"
ok "C2. RED on a tilde live-ledger default"

# C3. GREEN: isolated override, no live path. Comment mentioning the live
# tree is also allowed (the remaining seat-caps tests do that).
mkdir -p "$scratch/clean/tests"
cat >"$scratch/clean/tests/isolated.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
# Mirrors the live ~/.local/state/pi-packet tree as a fixture; does not read it.
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/seats"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
FIXTURE
clean_hits="$(live_ledger_hits "$scratch/clean")"
[[ -z "$clean_hits" ]] \
    || fail "C3. detector false-positived on an isolated fixture / comment: $clean_hits"
ok "C3. GREEN on an isolated harness (comment-only live path is fine)"

# C4. history replay when the clone has it: the deleted test file existed.
# Named SKIP on a shallow clone (same shape as tests/keystone-escalation-retired.test.sh).
if git -C "$repo_root" cat-file -e '9f0cba02c:tests/fleet-seat-comeback-release.test.sh' 2>/dev/null; then
    fail "C4. tests/fleet-seat-comeback-release.test.sh is still in 9f0cba02c (the delete commit) — tree vs commit mismatch"
fi
pre="$(git -C "$repo_root" show '9f0cba02c^:tests/fleet-seat-comeback-release.test.sh' 2>/dev/null || true)"
if [[ -z "$pre" ]]; then
    skip "C4. 9f0cba02c^:tests/fleet-seat-comeback-release.test.sh is not in this clone's history (shallow checkout?)"
else
    grep -q 'long non-money future wall must get the hourly PONG' <<<"$pre" \
        || fail "C4. pre-deletion test is not the #6264 / #4640 PONG case"
    ok "C4. pre-deletion test is the #6264 file (hourly PONG case present)"
fi

echo
echo "ALL OK: the #6264 comeback-release host-state leak is retired and pinned"
exit 0
