#!/usr/bin/env bash
# tests/nish-boundary-notify-classes.test.sh
#
# fleet-ops#1164: persist nish-boundary-notify CLASSES in git + lint.
# fleet-ops (auditor 2026-08-28): lock the no-seat abort class — a boundary
# entry whose body names no provider seats must reach the send step, not die
# under set -euo pipefail on the empty grep.
#
# fleet-ops#1164: persist nish-boundary-notify CLASSES in git + lint.
#
# nish-boundary-notify delivers the Nish-RESERVED escalation classes out of
# NISH-ESCALATIONS.md and into an actual message. Its CLASSES regex is the
# allowlist of classes that may page Nish. Standing rules
# (_system/shared-memory/global-standing-rules.md) reserve money, credentials,
# legal, product direction, one-shot public actions, and customer-data to Nish
# alone. If a token is dropped from CLASSES, that class silently stops reaching
# Nish — a credential page would be eaten without a sound (the 2026-08-26
# CREDENTIAL-BOUNDARY that sat undelivered).
#
# This test is the prevention: every Nish-reserved token from standing rules
# must appear in CLASSES. It fails if any is dropped, so a later overwrite of
# the script cannot silently regress the reserved set.
#
# Runs read-only against the repo. No live state is mutated.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/bin/nish-boundary-notify"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "missing: $script"
[[ -x "$script" ]] || fail "not executable: $script"

# The Nish-reserved set from standing rules, mapped to the CLASSES tokens.
# Standing rules reserve: money, credentials, legal, product direction,
# one-shot public actions, customer-data.
required_tokens=(
  MONEY-BOUNDARY
  CREDENTIAL-BOUNDARY
  LEGAL-BOUNDARY
  PRODUCT-DIRECTION
  ONE-SHOT-PUBLIC-ACTION
  CUSTOMER-DATA
)

# Extract the CLASSES value from the script (CLASSES='A|B|...').
classes_line="$(grep -E '^CLASSES=' "$script" | head -1)"
[[ -n "$classes_line" ]] || fail "no CLASSES= line in $script"
classes="${classes_line#CLASSES=}"
classes="${classes%\'}"
classes="${classes#\'}"
[[ -n "$classes" ]] || fail "CLASSES is empty in $script"

for token in "${required_tokens[@]}"; do
  grep -qE "(^|\|)$token(\||$)" <<<"$classes" \
    || fail "CLASSES is missing Nish-reserved token: $token"
  ok "CLASSES includes $token"
done

# The script must be syntactically valid bash.
bash -n "$script" || fail "bash syntax error in $script"

# --- no-seat abort regression (auditor 2026-08-28) ---------------------------
# A boundary entry with no provider seats in its body must not abort the
# script at the seats= grep (grep exits 1 on no match; set -euo pipefail then
# kills the whole run before the hermes send). The seats= line must tolerate
# an empty grep with || true.
seats_line="$(grep -E '^  seats=\$\(' "$script" | head -1)"
[[ "$seats_line" == *'|| true'* ]] \
    || fail "seats= must tolerate an empty grep (no-seat boundary entry would abort the send); got: $seats_line"
ok "seats= grep is no-match safe (no-seat boundary entries reach the send step)"

# Prove the pipeline class in isolation under the same shell flags the script
# runs under: a no-seat body must not trip set -e.
(
  set -euo pipefail
  body='2026-08-27T18:42:20Z LEGAL-BOUNDARY hash=legal-basics-sweep-1233 NISH DECISION NEEDED'
  seats=$(printf '%s' "$body" \
    | grep -oE '\b(devin|minimax|openrouter|cursor|deepseek|opencode-go)/[A-Za-z0-9._-]+' \
    | sort -u || true)
  [[ -z "$seats" ]] || { echo "FAIL: expected empty seats, got [$seats]"; exit 1; }
) || fail "no-seat body aborted under set -euo pipefail"
ok "no-seat body survives set -euo pipefail (empty seats, reaches send)"
ok "nish-boundary-notify is syntactically valid bash"

echo "OK: every Nish-reserved token is present in CLASSES (fleet-ops#1164)"
