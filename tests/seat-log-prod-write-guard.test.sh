#!/usr/bin/env bash
# tests/seat-log-prod-write-guard.test.sh
#
# fleet-ops#3928: a test suite run must never append seat_log lines to the
# live watch.log. On 2026-09-06 a fleet-seat-comeback-release.test.sh run in
# a pi-issue worker's worktree parked five phantom 'parked-ledger:
# ... corpse-retired' lines for LIVE seat names (devin/glm-5-2,
# straitly/gpt-5.6-sol, opencode/mimo-v2.5-free) into
# ~/.local/state/pi-packet/watch.log: the suite redirected the ledger dir but
# not PI_PACKET_STATE, and _seat_log_uses_file takes the file branch whenever
# ~/.config/logrotate.conf exists — which it does on this host. No live
# retirement had happened; the orchestrator spent three checks proving it.
#
# The guard has two halves:
#   (a) _seat_log_uses_file takes the JOURNAL branch for the production
#       watch.log path whenever the process tree is rooted in a
#       tests/*.test.sh run — the same observable contract as the
#       no-logrotate fallback, so a forgotten redirect can never reach the
#       file (journald rotates on its own);
#   (b) SEAT_LOG_FILE is a direct scratch-file seam for suites that want the
#       audit line captured rather than journaled.
#
# What we prove:
#   1. the incident shape — logrotate conf present + LOG_FILE resolves to the
#      production path + test ancestry -> zero bytes appended to the file,
#      the line takes the (stubbed) systemd-cat journal branch, and stderr
#      still carries it.
#   2. _seat_log_under_test detects the harness from a grandchild shell
#      (test -> command-substitution subshell -> bash -c).
#   3. SEAT_LOG_FILE pins the audit line to the harness scratch file.
#   4. The PI_PACKET_STATE redirect still captures the line in scratch.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"

scratch="$(mktemp -d -t seat-log-prod-guard.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# A stub systemd-cat so the journal branch is observable and nothing reaches
# the real journal. _SEAT_SYSTEMD_CAT resolves via `command -v` at source
# time, so the stub dir must lead PATH for the sourced children.
stubdir="$scratch/stub-bin"
mkdir -p "$stubdir"
cat > "$stubdir/systemd-cat" <<'STUB'
#!/usr/bin/env bash
cat >> "$SEAT_JOURNAL_STUB_OUT"
STUB
chmod +x "$stubdir/systemd-cat"
export SEAT_JOURNAL_STUB_OUT="$scratch/journal-out"
export PATH="$stubdir:$PATH"

# Fake HOME carrying the host condition from the incident: a user-level
# logrotate.conf exists, which is exactly what flipped _seat_log_uses_file to
# the file branch while LOG_FILE still pointed at the production path.
home="$scratch/home"
mkdir -p "$home/.config" "$home/.local/state/pi-packet"
: > "$home/.config/logrotate.conf"
prodlog="$home/.local/state/pi-packet/watch.log"

# --- 1. incident shape: prod path under a test -> journal, never the file --
set +e
out=$(HOME="$home" SEAT_LOG_FILE= SEAT_LOG_FORCE_FILE= SEAT_LOGROTATE_CONF= \
    PI_PACKET_STATE= bash -c 'source "$0"; seat_log "prod-guard probe line"' \
    "$lib" 2>&1)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "prod-path: seat_log under test must still succeed, got rc=$rc: $out"
grep -q "prod-guard probe line" <<<"$out" \
  || fail "prod-path: seat_log must still emit to stderr, got: $out"
[[ ! -s "$prodlog" ]] \
  || fail "prod-path: seat_log appended to the production watch.log path under a test harness"
grep -q "prod-guard probe line" "$SEAT_JOURNAL_STUB_OUT" \
  || fail "prod-path: line must take the journal branch under a test harness"
ok "1: production watch.log path under a test harness takes the journal branch (zero file append)"

# --- 2. _seat_log_under_test detects the harness from a grandchild ---------
HOME="$home" bash -c 'source "$0"; _seat_log_under_test' "$lib" \
  || fail "under-test: _seat_log_under_test must detect a tests/*.test.sh ancestor"
ok "2: _seat_log_under_test detects the test ancestry"

# --- 3. SEAT_LOG_FILE pins the audit line to the harness scratch file ------
HOME="$home" SEAT_LOG_FILE="$scratch/harness-watch.log" bash -c \
  'source "$0"; seat_log "seat-log-file seam line"' "$lib" >/dev/null 2>&1
grep -q "seat-log-file seam line" "$scratch/harness-watch.log" \
  || fail "SEAT_LOG_FILE: line must land in the harness scratch file"
[[ ! -s "$prodlog" ]] || fail "SEAT_LOG_FILE: prod watch.log path must stay empty"
ok "3: SEAT_LOG_FILE redirect captures seat_log in the harness scratch file"

# --- 4. PI_PACKET_STATE redirect still captures the line -------------------
mkdir -p "$scratch/state-redir"
HOME="$home" PI_PACKET_STATE="$scratch/state-redir" bash -c \
  'source "$0"; seat_log "pi-packet-state redir line"' "$lib" >/dev/null 2>&1
grep -q "pi-packet-state redir line" "$scratch/state-redir/watch.log" \
  || fail "PI_PACKET_STATE: line must land in the scratch watch.log"
[[ ! -s "$prodlog" ]] || fail "PI_PACKET_STATE: prod watch.log path must stay empty"
ok "4: PI_PACKET_STATE redirect still captures seat_log in scratch"

echo "OK: seat-log-prod-write-guard: prod watch.log unreachable from tests; both redirect seams work"
