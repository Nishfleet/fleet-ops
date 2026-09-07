#!/usr/bin/env bash
# tests/watch-log-rotation.test.sh
#
# Verify the user-level logrotate setup for pi-packet watch.log and the
# seat_log journal fallback when the logrotate config is absent.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t watch-log-rotation.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- 1. repo logrotate config shape ----------------------------------------

conf="$repo_root/config/logrotate.conf"
[[ -f "$conf" ]] || fail "config/logrotate.conf not found"
grep -q '/home/nish/.local/state/pi-packet/watch.log' "$conf" \
  || fail "watch.log path missing from logrotate conf"
grep -qE '^\s*size\s+10M\b' "$conf" || fail "size 10M missing"
grep -qE '^\s*rotate\s+5\b' "$conf" || fail "rotate 5 missing"
grep -qE '^\s*copytruncate\b' "$conf" || fail "copytruncate missing"
grep -qE '^\s*compress\b' "$conf" || fail "compress missing"
grep -qE '^\s*delaycompress\b' "$conf" || fail "delaycompress missing"

# --- 2. logrotate dry-run of repo config -----------------------------------

state="$scratch/state"
/usr/sbin/logrotate -d --state "$state" "$conf" >"$scratch/dry.log" 2>&1
grep -qE 'rotating pattern: /home/nish/.local/state/pi-packet/watch\.log\s+10485760 bytes \(5 rotations\)' "$scratch/dry.log" || \
  fail "dry-run did not show expected rotation pattern: $(cat "$scratch/dry.log")"
ok "logrotate config parses and targets watch.log with 10M/5"

# --- 3. real rotation on a temporary file ----------------------------------

tmpconf="$scratch/logrotate.conf"
watch="$scratch/watch.log"
sed "s|/home/nish/.local/state/pi-packet/watch.log|$watch|" "$conf" > "$tmpconf"
# 10.5 MiB, above the 10M threshold.
head -c 11010048 /dev/urandom > "$watch"

/usr/sbin/logrotate --state "$state" "$tmpconf"

[[ -f "$watch.1" ]] || fail "rotated file $watch.1 not created"
# copytruncate: the active log is truncated to 0 after the copy.
[[ ! -s "$watch" ]] || fail "active watch.log was not truncated after rotation"
ok "logrotate rotates and truncates a >10MB temp watch.log"

# --- 4. seat_log writes to file when a logrotate conf is present -----------

mkdir -p "$scratch/state-with-rotate"
: > "$scratch/logrotate.conf-present"
export SEAT_LOGROTATE_CONF="$scratch/logrotate.conf-present"
export PI_PACKET_STATE="$scratch/state-with-rotate"
# shellcheck source=../lib/seat-lib.sh
source "$lib"
seat_log "file-with-rotate test"
grep -q "file-with-rotate test" "$scratch/state-with-rotate/watch.log" \
  || fail "seat_log did not write to file when logrotate conf present"
ok "seat_log writes to watch.log when logrotate conf is present"

# --- 5. seat_log falls back to journal when logrotate conf is absent -------
# and the LOG_FILE is the production path. We stub systemd-cat so the test
# does not actually write to the journal and is deterministic.

stubdir="$scratch/stub-bin"
mkdir -p "$stubdir"
cat > "$stubdir/systemd-cat" <<'STUB'
#!/usr/bin/env bash
# Test stub for systemd-cat.
cat >> "$SEAT_JOURNAL_STUB_OUT"
STUB
chmod +x "$stubdir/systemd-cat"

export SEAT_JOURNAL_STUB_OUT="$scratch/journal-out"
export PATH="$stubdir:$PATH"
unset PI_PACKET_STATE
# Force a missing logrotate conf so this run exercises the journal fallback.
export SEAT_LOGROTATE_CONF="$scratch/no-such-logrotate.conf"

# shellcheck source=../lib/seat-lib.sh
source "$lib"
seat_log "journal-fallback test"
grep -q "journal-fallback test" "$scratch/journal-out" \
  || fail "seat_log did not fall back to systemd-cat"
# Since we unset PI_PACKET_STATE, LOG_FILE points to the production state dir.
# The fallback must NOT have appended to the real watch.log.
if [[ -e "$HOME/.local/state/pi-packet/watch.log" ]]; then
  if grep -q "journal-fallback test" "$HOME/.local/state/pi-packet/watch.log"; then
    fail "seat_log leaked a journal-fallback line into the real watch.log"
  fi
fi
ok "seat_log writes to journal when no logrotate conf and prod path"

# --- 6. seat_log writes to file in a scratch dir without logrotate conf ----

mkdir -p "$scratch/state-scratch"
export PI_PACKET_STATE="$scratch/state-scratch"
unset SEAT_LOGROTATE_CONF
# shellcheck source=../lib/seat-lib.sh
source "$lib"
seat_log "scratch-no-rotate test"
grep -q "scratch-no-rotate test" "$scratch/state-scratch/watch.log" \
  || fail "seat_log did not write to scratch watch.log"
ok "seat_log writes to file in scratch (test harness) without logrotate"

exit 0
