#!/usr/bin/env bash
# tests/hardcoded-epoch-guard.test.sh
#
# fleet-ops#4508: a hardcoded absolute Unix-seconds epoch in a tests/ or
# bin/ fixture that points at a FUTURE wall-clock instant is a time-bomb.
# The instant it rolls into the past, any "reset_s > 0" / "remaining > 0"
# assertion fed by it clamps to 0 and reds the suite for EVERY PR - exactly
# what felled the P14 fleet-metrics-export step on 2026-09-08
# (dailyQuotaResetAtUnix=1788854400, fixed relative-time in #4500 but with
# NO prevention gate). This is the prevention leg (fleet-ops#366
# mechanical-fix): a cheap static guard that fails the time-bomb at the PR
# that introduces it, not at midnight on the rollover. Third hit of the
# class (#4217, #4427, #4508); each prior fix only re-parametrized the one
# test.
#
# Rule (precise; exits 0 on the clean tree, fires on the bomb literal):
#   A 10-digit Unix-seconds literal (>= 1000000000, word-bounded so 13-digit
#   ms epochs, 12-digit `touch -t` stamps, 19-digit IDs, and byte constants
#   like 1073741824/3221225472 are NOT matched) that is FUTURE relative to
#   the guard's "now" AND sits in a fixture/stub/payload key-value field:
#     <reset|expir|until|deadline|renew|not_after|valid_to>... :/= <epoch>
#   the shape of `dailyQuotaResetAtUnix: 1788854400` and `"reset": <epoch>`.
#   `reset` subsumes resetAt / resetUnix / dailyQuotaResetAtUnix /
#   x-ratelimit-reset; `until` subsumes valid_until.
#
#   Exempt: dynamic `date +%s` / `$(date ...)` lines (wall-clock-relative by
#   design). Prometheus pass-through lines `metric{labels} <value>` do NOT
#   match - the value follows `}`, not a `:`/`=` key-value - so a static
#   pass-through assertion like `cycle_end_timestamp{...} 1790049771` is not
#   a time-bomb and is not flagged. Fixed-clock `NOW=<future>` constants
#   and byte sizes (MemoryHigh=3221225472) are not reset/expiry keys, so
#   they are not flagged either.
#
# Hosted by tests/fleet-metrics-export.test.sh so P14 runs this without a
# workflow-file edit (worker tokens cannot push .github/workflows/**). The
# negative fixture tests/fixtures/epoch-guard-negative.json carries the
# exact bomb literal 1788854400 and is excluded from the default tree scan
# by the epoch-guard-*.json basename rule; the test proves the guard fires
# on it by running with a frozen "now" (FLEET_EPOCH_GUARD_NOW) before that
# instant.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

command -v grep >/dev/null 2>&1 || fail "grep required"

# "now" for the future-check: real wall-clock by default, overridable for
# the frozen-clock proof run.
now="${FLEET_EPOCH_GUARD_NOW:-$(date +%s)}"

# 10-digit Unix-seconds epoch, word-bounded so a 13-digit millisecond epoch
# (e.g. a "never expires" sentinel 9999999999999, or a token expires_ms) is
# NOT matched: the bomb class is seconds-epoch literals (#4508 was
# dailyQuotaResetAtUnix=1788854400, 10 digits).
epoch_re='\b[1-9][0-9]{9}\b'
# reset/expiry key, optional word-tail + quote, then :/= , then the epoch.
key_re='(reset|expir|until|deadline|renew|not_after|valid_to)[a-z0-9_]*['"'"'"]?[[:space:]]*[:=][[:space:]]*'"$epoch_re"

# Print "file:lineno: future epoch <n>: <line>" for every hit in the given
# paths. The epoch-guard-*.json negative-fixture family is skipped during
# directory walks (scanned explicitly by the proof, step 3). One fast grep
# pass per path picks only key-value candidate lines; bash then future-
# checks the few matches (no per-line grep over the whole tree).
_check_line() {
  local file="$1" lineno="$2" content="$3" n
  [[ "$content" == *"date +%s"* || "$content" == *'$(date'* ]] && return
  for n in $(printf '%s' "$content" | grep -oE "$epoch_re"); do
    if (( n > now )); then
      echo "$file:$lineno: future epoch $n: $content"
    fi
  done
}

epoch_guard_hits() {
  local path line file rest lineno content
  for path in "$@"; do
    if [[ -d "$path" ]]; then
      while IFS= read -r line; do
        file="${line%%:*}"
        [[ "$(basename "$file")" == epoch-guard-*.json ]] && continue
        rest="${line#*:}"; lineno="${rest%%:*}"; content="${rest#*:}"
        _check_line "$file" "$lineno" "$content"
      done < <(grep -rInIE "$key_re" "$path" 2>/dev/null)
    elif [[ -f "$path" ]]; then
      while IFS= read -r line; do
        rest="${line#*:}"; lineno="${rest%%:*}"; content="${rest#*:}"
        _check_line "$path" "$lineno" "$content"
      done < <(grep -InIE "$key_re" "$path" 2>/dev/null)
    fi
  done
}

# --- 1. Clean tree: no hardcoded future epoch in tests/ or bin/ fixtures ---
clean_hits="$(epoch_guard_hits "$repo_root/tests" "$repo_root/bin")"
if [[ -n "$clean_hits" ]]; then
  fail "hardcoded future Unix-epoch literal in tests/ or bin/ (fleet-ops#4508 class):"$'\n'"$clean_hits"
fi
ok "clean tree: no hardcoded future epoch in tests/ or bin/ fixtures (now=$now)"

# --- 2. The bomb literal is present in the negative fixture --------------
neg="$repo_root/tests/fixtures/epoch-guard-negative.json"
[[ -f "$neg" ]] || fail "negative fixture missing: $neg"
grep -q '1788854400' "$neg" \
  || fail "negative fixture must carry the bomb literal 1788854400: $neg"
ok "negative fixture present with bomb literal 1788854400: $neg"

# --- 3. Prove the guard fires on the bomb literal (frozen clock) ----------
# 1788854400 = 2026-09-08T08:00:00Z. Freeze "now" one day before so the
# literal is FUTURE relative to the guard, then scan the negative fixture
# directly (the basename skip only applies to directory walks). Reassign
# the global `now` for this call, then restore the real wall-clock after.
frozen=$((1788854400 - 86400))
saved_now="$now"
now="$frozen"
fire_hits="$(epoch_guard_hits "$neg")"
now="$saved_now"
if [[ -z "$fire_hits" ]]; then
  fail "guard must fire on the bomb literal 1788854400 with frozen now=$frozen, got no hits"
fi
echo "$fire_hits" | grep -q '1788854400' \
  || fail "guard fired but did not name the bomb literal 1788854400:"$'\n'"$fire_hits"
ok "guard fires on re-injected 1788854400 (frozen now=$frozen):"$'\n'"$fire_hits"

# --- 4. Negative fixture is excluded from the default tree scan ---------
# (so the clean-tree run in step 1 stays clean even as the literal ages;
# the proof in step 3 scans it explicitly.)
if epoch_guard_hits "$repo_root/tests" "$repo_root/bin" | grep -q 'epoch-guard-negative'; then
  fail "negative fixture must be skipped by the default tree scan"
fi
ok "negative fixture is skipped by the default tree scan"

# --- 5. This lock is actually reached from a P14-listed test ------------
grep -Fq 'bash "$here/hardcoded-epoch-guard.test.sh"' "$here/fleet-metrics-export.test.sh" \
  || fail "fleet-metrics-export.test.sh must invoke this file (P14 host, fleet-ops#4508)"
ok "lock is wired through tests/fleet-metrics-export.test.sh (already in P14)"

echo "OK: hardcoded-epoch-guard.test.sh: future-epoch time-bomb class is locked (fleet-ops#4508)"
