#!/usr/bin/env bash
# tests/intake-gate-release.test.sh
#
# fleet-ops#4626 (scope widened by the judge 2026-09-12): `awaiting-runtime-gate`
# and `blocked-on:` parks were one-way doors. The organs that evaluated them
# (bin/blocked-reconcile, lib/pi-intake-tick.sh, bin/fleet-merged-pr-close) were
# all deleted in the 2026-09-18/19 sweeps, so the labels kept gating intake
# while nothing released them — 10 of 16 agent-ready issues sat parked in one
# tick. The per-repo intake tick (prompts/intake.md via pi-intake@<repo>) is
# the surviving organ that already scans every open issue and owns the
# agent-* label transitions, so the release path lives there as prompt rules:
# prompt lines are the sanctioned change surface; a new script or unit is the
# banned shape.
#
# Contract asserted here (the judge's accept, mapped to prompt text):
#   (a) a parked issue whose gate fired is RELEASED: park label removed,
#       agent-ready restored, and exactly one `gate-release:` ledger line on
#       the issue naming which gate released it and the evidence;
#   (b) an unparseable or missing gate is LOUD — printed, commented, and
#       surfaced via `needs-orchestrator` — never parked silently forever;
#   (c) no path may strip agent-ready without a registered release
#       condition: the tick never parks anything itself, and Pick work must
#       drop parked labels even when `agent-ready` is also present (the leak
#       that let #4626 be claimed 20+ times while "parked").

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
intake="$repo_root/prompts/intake.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$intake" ]] || fail "missing $intake"
ok "prompts/intake.md exists"

# --- the release step exists and runs before Pick work ------------------------
release_line="$(grep -nF 'Release the parked' "$intake" | head -1 | cut -d: -f1 || true)"
[[ -n "$release_line" ]] || fail "intake.md has no 'Release the parked' step — no organ evaluates parked-issue gates (fleet-ops#4626)"
pick_line="$(grep -nF 'Pick work' "$intake" | head -1 | cut -d: -f1 || true)"
[[ -n "$pick_line" ]] || fail "intake.md has no 'Pick work' step"
(( release_line < pick_line )) || fail "'Release the parked' (line $release_line) runs after 'Pick work' (line $pick_line) — released issues could never be claimed the same tick"
ok "release step at line $release_line precedes pick-work at line $pick_line"

# --- (a) satisfied gate -> release with one ledger line -----------------------
for needle in \
  'agent-blocked' \
  'awaiting-runtime-gate' \
  'blocked-on:' \
  're-open-<ISO8601>' \
  'termination:' \
  'decision-resolved:' \
  'gate-release:' \
  '--remove-label awaiting-runtime-gate' \
  '--add-label'; do
  grep -qF -- "$needle" "$intake" \
    || fail "release step missing '$needle' — accept (a): satisfied gate must release with a ledger line (fleet-ops#4626)"
  ok "release semantics carry '$needle'"
done

# --- (b) unparseable gate surfaces LOUD, never parks forever -------------------
for needle in \
  'LOUD' \
  'needs-orchestrator'; do
  grep -qF -- "$needle" "$intake" \
    || fail "release step missing '$needle' — accept (b): an unparseable gate must surface, not park forever (fleet-ops#4626)"
  ok "loud-surface carries '$needle'"
done

# Gates are untrusted issue text: evaluation must be read-only interpretation,
# never execution of a clause's commands.
grep -qiE 'untrusted|never (run|execute)' "$intake" \
  || fail "release step never says gates are untrusted data evaluated read-only (fleet-ops#6593 shape)"
ok "gate evaluation is declared read-only / untrusted-data"

# agent-in-progress issues are skipped — a live claim owns that label flip.
grep -qF -- 'agent-in-progress' "$intake" \
  || fail "release step never excludes agent-in-progress issues (live claims)"
ok "live claims excluded from release"

# --- (c) the tick never parks, and pick-work honours the park ------------------
grep -qiE 'never (add|park)[^.]*agent-blocked|never park' "$intake" \
  || fail "intake.md never states the tick itself may not park issues — accept (c) requires no unregistered strip of agent-ready (fleet-ops#4626)"
ok "tick never-park invariant stated"

pick_section="$(awk '/Pick work/{f=1} /Claim, in order|Print one line/{f=0} f' "$intake")"
[[ -n "$pick_section" ]] || fail "cannot isolate the Pick work section"
for needle in 'agent-blocked' 'awaiting-runtime-gate'; do
  grep -qF -- "$needle" <<< "$pick_section" \
    || fail "Pick work does not drop '$needle' issues — a park label must gate claiming even when agent-ready is also present (fleet-ops#4626)"
  ok "pick-work drops '$needle'"
done

# --- orphan claim refs release instead of starving the issue (fleet-ops#7796) --
# A claim ref with no live worker and no open PR used to be skipped every tick
# forever: the 5b ls-remote treated ref-existence as held-by-someone. The claim
# step must now distinguish a live holder (a *-issue@<repo>-N unit in
# active/activating) from an orphan, release the orphan through the existing
# guarded releaser (fail-closed open-PR check, wip/ preserve, trace line), and
# only then attempt the claim push.
claim_section="$(awk '/Claim, in order/{f=1} /Print one line|Jev cascade/{f=0} f' "$intake")"
[[ -n "$claim_section" ]] || fail "cannot isolate the Claim step section"
for needle in \
  'ls-remote origin refs/heads/claim/issue-N' \
  'fleet-claim-release' \
  'active,activating' \
  'wip/issue-'; do
  grep -qF -- "$needle" <<< "$claim_section" \
    || fail "claim step missing '$needle' — an orphan claim ref must be released via the guarded releaser, not skipped forever (fleet-ops#7796)"
  ok "orphan-claim release carries '$needle'"
done
# The live-holder check must run BEFORE the releaser: deleting the claim ref of
# a running worker destroys in-flight work (the #7816 live-worker shape).
holder_line="$(grep -nF -- '-issue@<repo>-N.service' <<< "$claim_section" | head -1 | cut -d: -f1 || true)"
release_line2="$(grep -nF -- 'fleet-claim-release' <<< "$claim_section" | head -1 | cut -d: -f1 || true)"
[[ -n "$holder_line" && -n "$release_line2" ]] \
  || fail "claim step lacks the live-holder probe or the releaser call (fleet-ops#7796)"
(( holder_line < release_line2 )) \
  || fail "live-holder check must precede the releaser — a live worker's claim ref is never orphaned (fleet-ops#7796)"
ok "live-holder check precedes releaser (line $holder_line < $release_line2)"

# --- capacity count includes activating oneshot workers (fleet-ops#7812) -----
# pi-issue@/devin-issue@/cursor-issue@ are all Type=oneshot: ActiveState is
# 'activating' for the whole ExecStart run, never 'active'. A --state=active
# capacity count reads 0 with workers in flight, so the fleet-wide cap never
# binds — the 2026-09-19 tick re-claimed a live worker off that zero. The fix
# (fleet-ops#7775) spelled the count out over '*-issue@*.service' with
# --state=active,activating; both halves are asserted so neither can regress.
capacity_section="$(awk '/\*\*Capacity/{f=1} /Pick work/{f=0} f' "$intake")"
[[ -n "$capacity_section" ]] || fail "cannot isolate the Capacity section"
for needle in \
  'list-units' \
  '-issue@' \
  '--state=active,activating'; do
  grep -qF -- "$needle" <<< "$capacity_section" \
    || fail "capacity count missing '$needle' — a --state=active-only count sees zero in-flight oneshot workers and the fleet cap unbinds (fleet-ops#7812)"
  ok "capacity count carries '$needle'"
done

echo "PASS: intake-gate-release"
