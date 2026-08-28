#!/usr/bin/env bash
# tests/opus-heartbeat-follow-through.test.sh
#
# fleet-ops#1453 item 2: the judge prompt at
# /home/nish/.local/share/opus-heartbeat/judge-prompt.md MUST instruct the
# Opus judge to perform a follow-through check BEFORE filing `gh issue
# create`, and MUST name the new louder fault class
# "repair queue is not consuming repairs" with its required actions.
#
# Live #1453: from 00:30Z to 03:45Z, the heartbeat filed near-duplicate
# `gh issue create` items every hour, all describing "intake starvation" /
# "dispatch starvation". Each was a fresh open issue; the previous hour's
# filing was still open and unclaimed. The judge never noticed. The fix
# is to make the judge prompt REQUIRE the check.
#
# Scenarios (fleet-ops#366 mechanical-fix shape):
#   1. judge-prompt.md contains a "follow-through" section header.
#   2. judge-prompt.md explicitly forbids duplicate filing when a
#      heartbeat-filed issue for the same class is OPEN and unclaimed.
#   3. judge-prompt.md names the new louder fault class
#      "repair queue is not consuming repairs".
#   4. judge-prompt.md ties the louder fault to the narrow direct-dispatch
#      lever (`pi-systemd-run --unit repair-*`) and/or the boundary file
#      (`>> NISH-ESCALATIONS.md`).
#   5. judge-prompt.md states the gate condition
#      `dispatches_last_2h <= 1 AND ready_work > 50`.
#   6. The narrow direct-dispatch lever shape is described as
#      `--unit repair-*` (NOT just `--unit <name>`).
#   7. The prompt still demands the existing allowlist
#      (`gh issue create`, `systemctl --user start`, boundary append,
#       `pi-systemd-run --unit ...`) so the gate narrows the lever rather
#      than replacing it.
#   8. The three citation points (live #1453 mention, follow-through
#      block, narrow-lever block) are all present in the file — guards
#      against a future refactor that drops one.
#
# Pure offline grep / bash assertions. No live Opus, no live gh.
# The judge prompt is a hand-edited file at the canonical install path;
# a future refactor that deletes the section would be caught here.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

PROMPT_FILE="${OPUS_HB_PROMPT_FILE:-/home/nish/.local/share/opus-heartbeat/judge-prompt.md}"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -s "$PROMPT_FILE" ]] || fail "judge prompt missing or empty at $PROMPT_FILE"
command -v grep >/dev/null 2>&1 || fail "grep missing"

# Extract the textual body of the prompt (just for sanity — every test
# below uses grep -F or grep -E on the file directly so a test does not
# depend on the file's specific formatting).
body="$(cat "$PROMPT_FILE")"
[[ "$body" == *"You are the fleet's 2-hourly duty officer"* ]] \
  || fail "judge prompt missing the duty-officer boilerplate — wrong file?"

# --- 1. follow-through section header present ------------------------------
grep -qE '^#[[:space:]]*Fleet-ops#1453[[:space:]]*[—–-][[:space:]]*follow-through' "$PROMPT_FILE" \
  || grep -qE -i 'follow-through check' "$PROMPT_FILE" \
  || fail "judge prompt missing follow-through section header"
ok "test 1: follow-through section header present"

# --- 2. duplicate filing explicitly forbidden ------------------------------
# The phrase "do NOT file" or "must NOT file" or "NEVER file a duplicate"
# must appear in the follow-through block, and the phrase must refer to
# the duplicate-issue case (not some unrelated action).
if ! grep -qE '(NEVER|must NOT|do NOT)[[:space:]]+(file|create)[^.]*duplicate' "$PROMPT_FILE"; then
  if ! grep -qE 'duplicate[^.]*(file|create|filing)' "$PROMPT_FILE"; then
    fail "judge prompt does not forbid duplicate filing of equivalent fault issues"
  fi
fi
ok "test 2: judge prompt forbids duplicate filing of same-class issues"

# --- 3. louder fault class name --------------------------------------------
grep -qF 'repair queue is not consuming repairs' "$PROMPT_FILE" \
  || fail "judge prompt does not name the louder fault class 'repair queue is not consuming repairs'"
ok "test 3: judge prompt names the 'repair queue is not consuming repairs' fault class"

# --- 4. louder fault class action: direct dispatch OR boundary --------------
# Either the prompt names "pi-systemd-run --unit repair-" as the action
# for the louder fault, OR it names NISH-ESCALATIONS.md as the boundary,
# OR both. Both must be reachable so the judge has a real lever when it
# sees the louder fault.
if ! grep -qE 'pi-systemd-run[[:space:]]+--unit[[:space:]]+repair-' "$PROMPT_FILE"; then
  fail "judge prompt does not mention the narrow --unit repair- lever shape"
fi
if ! grep -qE 'NISH-ESCALATIONS\.md' "$PROMPT_FILE"; then
  fail "judge prompt does not mention NISH-ESCALATIONS.md (boundary lever)"
fi
ok "test 4: judge prompt ties the louder fault to direct dispatch and boundary"

# --- 5. gate condition stated explicitly -----------------------------------
grep -qE 'dispatches_last_2h[[:space:]]*<=?[[:space:]]*1' "$PROMPT_FILE" \
  || fail "judge prompt does not state dispatches_last_2h <= 1"
grep -qE 'ready_work[[:space:]]*>[[:space:]]*50' "$PROMPT_FILE" \
  || fail "judge prompt does not state ready_work > 50"
ok "test 5: judge prompt states the gate condition (dispatches<=1 AND ready>50)"

# --- 6. narrow lever shape documented as 'repair-*' not '<name>' ----------
# The current prompt-upstream says "pi-systemd-run --unit <name> ...".
# The #1453 fix must add a 'repair-*' qualifier. Verify the new shape
# appears AT LEAST ONCE in the prompt (the gate paragraph).
grep -qF -- '--unit repair-' "$PROMPT_FILE" \
  || fail "judge prompt does not require the --unit repair- prefix"
# Negative control: the old generic "<name>" shape should NOT be the
# only description of the lever (it may still appear as the upstream
# allowlist line, but the new shape must be documented).
grep -qE -- '--unit <name>' "$PROMPT_FILE" \
  || fail "judge prompt lost the upstream '<name>' shape — wrong file?"
ok "test 6: judge prompt documents the narrow '--unit repair-' shape (and keeps the upstream <name> line)"

# --- 7. existing allowlist items preserved --------------------------------
grep -qF 'gh issue create' "$PROMPT_FILE" \
  || fail "judge prompt lost 'gh issue create' allowlist"
grep -qF 'systemctl --user start' "$PROMPT_FILE" \
  || fail "judge prompt lost 'systemctl --user start' allowlist"
grep -qF 'NISH-ESCALATIONS.md' "$PROMPT_FILE" \
  || fail "judge prompt lost NISH-ESCALATIONS.md boundary append"
ok "test 7: judge prompt keeps gh/systemctl/boundary allowlist"

# --- 8. citation points (live #1453, follow-through, narrow-lever) -------
# Three required citations — a future refactor that drops one would be
# caught. Use exact substrings so a paraphrase does not satisfy this
# test (the comments above pin the live wording).
# --- 8. citation points (live #1453, follow-through, narrow-lever) -------
# Three required citations — a future refactor that drops one would be
# caught. Use exact substrings so a paraphrase does not satisfy this
# test (the comments above pin the live wording). The case-insensitive
# match covers the live shape ("Fleet-ops#1453", "live #1453", etc.).
grep -qiE 'fleet-ops#1453|live[[:space:]]*#1453' "$PROMPT_FILE" \
  || fail "judge prompt does not cite fleet-ops#1453 anywhere (case-insensitive)"
grep -qiE 'follow-through[[:space:]]+check' "$PROMPT_FILE" \
  || fail "judge prompt does not mention 'follow-through check'"
grep -qiE 'narrow[[:space:]]+(direct-)?dispatch[[:space:]]+lever' "$PROMPT_FILE" \
  || fail "judge prompt does not call it the 'narrow direct-dispatch lever'"
ok "test 8: judge prompt has all three citation points (#1453, follow-through, narrow lever)"

exit 0
