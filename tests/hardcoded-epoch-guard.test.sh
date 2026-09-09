#!/usr/bin/env bash
# tests/hardcoded-epoch-guard.test.sh
#
# fleet-ops#4508: prevent the class of bug that red'd every PR on 2026-09-08.
# A test fixture hardcoded `dailyQuotaResetAtUnix: 1788854400` (a calendar
# instant). Once wall-clock time passed that instant, the metrics exporter
# computed `reset_s = 0.0` and the P14 `fleet-metrics-export` test failed on
# every PR for a day. PR #4500 fixed that one fixture by making the reset
# epochs relative to runtime (`int(time.time()) + 3600`). This guard is the
# mechanical prevention for the whole class: it refuses to let an absolute
# Unix-epoch literal re-enter tests/ or bin/ as a stable stub/fixture/payload.
#
# What "absolute Unix-epoch literal" means here:
#   - a 10-digit integer in seconds form, OR a 13-digit integer in
#     milliseconds form, that decodes to an instant at or after
#     2001-09-09T01:46:40Z (1000000000). We use 1e9 as the floor because every
#     real Unix epoch used in this repo is post-2001 and 1e9 cleanly excludes
#     byte counts, run ids, journal sequence numbers, and other large
#     integers that happen to be 10+ digits.
#   - the literal must be CURRENT OR FUTURE relative to a fixed reference
#     instant (default: the run's `now`). Past instants are inert — they
#     cannot red CI after they have elapsed, so the guard only blocks the
#     time-bomb shape. The reference instant is overridable via
#     EPOCH_GUARD_NOW so the negative proof can replay the 2026-09-08 incident
#     against a backdated clock without depending on the real wall clock.
#
# Exemptions (encoded inline so the exemption lives next to the literal it
# defends, not in a separate allow-list that drifts):
#   - `date +%s`, `date +%s%3N`, `$(date ...)`, `time.time()`,
#     `int(time.time())`, `datetime...timestamp()` — dynamic reads of the
#     runtime clock. These are the correct shape and are what #4500 moved
#     the fixtures to.
#   - `epoch-guard: exempt` on the same line as the literal — explicit
#     inline opt-out for a literal that is large, 10+ digits, and provably
#     NOT a wall-clock instant (byte counts, run ids, sentinel far-future
#     markers used as "never expires", fixed-clock test scaffolding). The
#     exemption is auditable in `git blame` next to the number it defends.
#   - Prometheus `@ <expr>` evaluation offsets are not epochs and are not
#     matched (the `@` form is not a bare integer literal).
#
# This test is OFFLINE (no network, no GitHub API) so it runs in the P14
# suite on hosted runners. It has two phases:
#   1. clean-tree scan: run the scanner over tests/ and bin/ with the real
#      `now` and assert zero findings. The negative fixture
#      tests/fixtures/epoch-guard-negative.json is EXCLUDED — it is the proof
#      target, not a scanned file.
#   2. negative proof: run the scanner over the negative fixture with
#      EPOCH_GUARD_NOW backdated to before the embedded literal and assert
#      it fires on `1788854400` with file+line. This proves the guard would
#      have caught the original incident.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
negative_fixture="$here/fixtures/epoch-guard-negative.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

cd "$repo_root"

# --- scanner ---------------------------------------------------------------
# scan_epochs <now_seconds> <path...>
# Prints `file:line: <literal> (<decoded-iso>)` for each offending literal.
# Exits non-zero if any finding is emitted.
scan_epochs() {
  local now_s="$1"; shift
  local paths=("$@")
  local findings=0
  # Match runs of 10-13 digits. We filter to [1-9][0-9]{9,12} so we catch both
  # 10-digit (seconds) and 13-digit (milliseconds) epoch forms while
  # excluding the 14+ digit journal/run-id/sha-fragment noise that lives in
  # the fixtures. A leading 0 would make the number octal and not an epoch.
  while IFS= read -r line; do
    # shellcheck disable=SC2001
    file="${line%%:*}"
    rest="${line#*:}"
    lineno="${rest%%:*}"
    content="${rest#*:}"
    # Exemption 1: inline opt-out.
    case "$content" in
      *epoch-guard:\ exempt*) continue;;
    esac
    # Exemption 2: dynamic clock reads on the same line.
    case "$content" in
      *date\ +%s*|*date\ +%s%3N*|*\$\(date*|*time.time\(\)*|*datetime*timestamp\(\)*) continue;;
    esac
    # Pull every 10-13 digit run out of the line and test each.
    for num in $(printf '%s' "$content" | grep -oE '[1-9][0-9]{9,12}'); do
      len=${#num}
      decoded=""
      if [ "$len" -eq 10 ]; then
        s="$num"
      elif [ "$len" -eq 13 ]; then
        # milliseconds -> seconds
        s="${num%???}"
      else
        # 11 or 12 digits: not a clean seconds or ms epoch form; skip.
        continue
      fi
      # Floor: 1000000000 (2001-09-09). Below that is not a modern epoch.
      [ "$s" -ge 1000000000 ] 2>/dev/null || continue
      # Time-bomb shape: current or future relative to the reference instant.
      [ "$s" -ge "$now_s" ] 2>/dev/null || continue
      iso=$(date -u -d "@$s" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
      echo "$file:$lineno: $num ($iso)"
      findings=$((findings + 1))
    done
  done < <(grep -rnE '[1-9][0-9]{9,12}' "${paths[@]}" 2>/dev/null)
  return $(( findings > 0 ? 1 : 0 ))
}

# --- phase 1: clean-tree scan ----------------------------------------------
# Real wall-clock now. The negative fixture is excluded — it is the proof
# target, not a scanned file. tests/fixtures/epoch-guard-negative.json is
# the only file in tests/fixtures/ named epoch-guard-*.
now_s="$(date +%s)"

# Build the scan list: tests/ and bin/ minus the negative fixture.
scan_list=()
while IFS= read -r f; do
  [ "$f" = "$negative_fixture" ] && continue
  scan_list+=("$f")
done < <(find tests bin -type f 2>/dev/null)

set +e
report="$(scan_epochs "$now_s" "${scan_list[@]}")"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "hardcoded-epoch-guard: clean-tree scan found absolute future epoch literals:" >&2
  printf '%s\n' "$report" >&2
  echo "(If the literal is NOT a wall-clock instant — byte count, run id," >&2
  echo "sentinel, fixed-clock scaffolding — add \`epoch-guard: exempt\` on" >&2
  echo "the same line. If it IS a real instant, make it relative to runtime" >&2
  echo "like #4500: int(time.time()) + N. Never hardcode a calendar epoch.)" >&2
  fail "clean-tree scan must be zero-finding; see above"
fi
ok "clean-tree scan: no absolute future epoch literals in tests/ or bin/"

# --- phase 2: negative proof ----------------------------------------------
# Backdate the clock to 2026-09-01 (before the 2026-09-08 incident instant)
# and run the scanner over ONLY the negative fixture. It must fire on
# 1788854400 with file+line, proving the guard would have caught the
# original #4217/#4508 incident.
[ -f "$negative_fixture" ] || fail "negative fixture missing: $negative_fixture"
backdated_now=$(date -u -d '2026-09-01T00:00:00Z' +%s)
set +e
proof="$(scan_epochs "$backdated_now" "$negative_fixture")"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "negative proof: scanner must fire on $negative_fixture"
printf '%s\n' "$proof" | grep -qE "^${negative_fixture}:[0-9]+: 1788854400 " \
  || fail "negative proof: must report 1788854400 with file+line, got: $proof"
ok "negative proof: guard fires on 1788854400 in $negative_fixture"

# --- phase 3: re-injection proof ------------------------------------------
# Copy the negative fixture's literal into a temp file inside tests/ and
# confirm the clean-tree scanner (real now) ALSO rejects it. This proves
# the guard catches the literal the moment it lands in a scanned path,
# independent of the backdated clock.
tmp_fixture="$(mktemp "$here/fixtures/epoch-guard-reinject-XXXXXX.json")"
trap 'rm -f "$tmp_fixture"' EXIT
cp "$negative_fixture" "$tmp_fixture"
set +e
reinject="$(scan_epochs "$now_s" "$tmp_fixture")"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "re-injection proof: scanner must fire on $tmp_fixture"
printf '%s\n' "$reinject" | grep -qE "^${tmp_fixture}:[0-9]+: 1788854400 " \
  || fail "re-injection proof: must report 1788854400, got: $reinject"
ok "re-injection proof: guard catches 1788854400 the moment it lands in tests/"
rm -f "$tmp_fixture"
trap - EXIT

echo "PASS: hardcoded-epoch-guard (clean-tree + negative + re-injection)"
