#!/usr/bin/env bash
# tests/prior-art-claim-check.test.sh
#
# fleet-ops#1250: build-shaped agent-ready issues must carry a Prior art
# section before intake may claim them. This test runs the REAL checker
# in bin/prior-art-claim-check (not a copy of its predicate).
#
# Phase A: intake tick + prompts carry the gate.
# Phase B: not-build-shaped is CLAIM_OK.
# Phase C: build-shaped without Prior art is BOUNCE (the drill).
# Phase D: build-shaped with a complete Prior art section is CLAIM_OK.
# Phase E: heading-only / n/a Prior art is still BOUNCE.
# Phase F: bounce flips agent-ready → agent-blocked and comments (fake gh).
# Phase G: bounce is a no-op gh-wise when the body is CLAIM_OK.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/prior-art-claim-check"
tick="$repo_root/lib/pi-intake-tick.sh"
intake="$repo_root/prompts/intake.md"
scout="$repo_root/prompts/scout.md"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "missing or not executable: $bin"
[[ -f "$tick" ]] || fail "missing: $tick"

scratch="$(mktemp -d -t prior-art-claim.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

check() {
    local body="$1"
    printf '%s\n' "$body" >"$scratch/body.md"
    "$bin" --body "$scratch/body.md"
}

# ============================================================================
# Phase A: wiring — tick calls the checker BEFORE the claim push
# ============================================================================
grep -qF 'prior-art-claim-check' "$tick" \
    || fail "lib/pi-intake-tick.sh must call prior-art-claim-check"
grep -qF 'skipped-spec-incomplete' "$tick" \
    || fail "lib/pi-intake-tick.sh must print skipped-spec-incomplete on bounce"
python3 - "$tick" <<'PY' || fail "prior-art gate must run before the claim push"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
i_gate = text.find("prior-art-claim-check")
i_push = text.find("push --force-with-lease")
if i_gate < 0:
    sys.exit("prior-art-claim-check not found")
if i_push < 0:
    sys.exit("claim push not found")
if not (i_gate < i_push):
    sys.exit(f"gate at {i_gate} is after claim push at {i_push}")
PY
ok "A1: tick runs prior-art-claim-check before the claim push"

grep -qF 'prior-art-claim-check' "$intake" \
    || fail "prompts/intake.md must run prior-art-claim-check before claiming"
grep -qF 'Prior art' "$scout" \
    || fail "prompts/scout.md must require a Prior art section on build-shaped issues"
grep -qF 'bin/prior-art-claim-check /home/nish/.local/bin/prior-art-claim-check' "$manifest" \
    || fail "MANIFEST must install bin/prior-art-claim-check"
ok "A2: intake.md, scout.md, and MANIFEST carry the gate"

# ============================================================================
# Phase B: not build-shaped
# ============================================================================
body=$'Fix the seat cap math.\n\naccept:\n- tighten the JSON schema\n'
if out=$(check "$body"); then
    printf '%s\n' "$out" | grep -q '^CLAIM_OK:' \
        || fail "B: non-build body must print CLAIM_OK, got: $out"
    ok "B: non-build-shaped body is CLAIM_OK"
else
    fail "B: non-build-shaped body must exit 0"
fi

# ============================================================================
# Phase C: drill — synthetic build-issue without Prior art
# ============================================================================
drill=$'Build a visibility probe that scores AI-citation share.

accept:
- write the probe
- run it nightly

termination: bash tests/probe.test.sh
'
set +e
out=$(check "$drill" 2>"$scratch/err")
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "C: drill must exit 1 (BOUNCE), got $rc: $out $(cat "$scratch/err")"
printf '%s\n' "$out" | grep -q '^BOUNCE:' \
    || fail "C: drill stdout must say BOUNCE, got: $out"
grep -q 'fleet-ops#1250' "$scratch/err" \
    || fail "C: BOUNCE stderr must cite fleet-ops#1250: $(cat "$scratch/err")"
ok "C: drill (build a ... with no Prior art) bounces"

# write a script / create a service variants
for phrase in "write a script that syncs seats" "create a service that watches DNS"; do
    body=$'Do the thing.\n\n'"$phrase"$'\n'
    set +e
    check "$body" >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]] || fail "C2: '$phrase' must bounce, got $rc"
done
ok "C2: write a script / create a service also bounce"

# ============================================================================
# Phase D: complete Prior art section
# ============================================================================
complete=$'Build a visibility probe that scores AI-citation share.

## Prior art

Existing commercial tools: Semrush, Ahrefs, Surfer, AlsoAsked. Tested AlsoAsked and Ahrefs APIs this week. Rejected because none expose a fleet-scoped RAM governor or sit behind our seat caps.

accept:
- glue the winner if one appears; otherwise the smallest local probe
'
if out=$(check "$complete"); then
    printf '%s\n' "$out" | grep -q '^CLAIM_OK:' \
        || fail "D: complete Prior art must print CLAIM_OK, got: $out"
    ok "D: build-shaped + complete Prior art is CLAIM_OK"
else
    fail "D: complete Prior art must exit 0"
fi

compact=$'Write a script that rotates seats.

Prior art: existing GNU parallel and pi-systemd-run were tested; rejected because neither tracks per-seat weekly caps.
'
if check "$compact" >/dev/null; then
    ok "D2: compact Prior art: line is CLAIM_OK"
else
    fail "D2: compact Prior art: line must exit 0"
fi

# ============================================================================
# Phase E: heading-only / n/a is still bounce
# ============================================================================
heading_only=$'Build a pipeline for GEO scores.

## Prior art

## Accept
- ship it
'
set +e
check "$heading_only" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "E1: heading-only Prior art must bounce, got $rc"
ok "E1: heading-only Prior art bounces"

na=$'Create a service for uptime.

## Prior art
n/a
'
set +e
check "$na" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "E2: Prior art n/a must bounce, got $rc"
ok "E2: Prior art n/a bounces"

# ============================================================================
# Phase F: bounce subcommand flips labels (fake gh)
# ============================================================================
cat >"$scratch/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
exit 0
GH
chmod +x "$scratch/gh"
export GH="$scratch/gh"
export GH_LOG="$scratch/gh.log"
: >"$GH_LOG"

set +e
out=$("$bin" bounce -R Nishfleet/fleet-ops --issue 99 --body "$scratch/body.md" 2>"$scratch/err")
rc=$?
set -e
# body.md currently holds the last check() write (n/a fixture). Rewrite drill.
printf '%s\n' "$drill" >"$scratch/body.md"
: >"$GH_LOG"
set +e
out=$("$bin" bounce -R Nishfleet/fleet-ops --issue 99 --body "$scratch/body.md" 2>"$scratch/err")
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "F: bounce must exit 1, got $rc: $out $(cat "$scratch/err")"
grep -q -- '--remove-label agent-ready' "$GH_LOG" \
    || fail "F: bounce must remove agent-ready: $(cat "$GH_LOG")"
grep -q -- '--add-label agent-blocked' "$GH_LOG" \
    || fail "F: bounce must add agent-blocked: $(cat "$GH_LOG")"
grep -q 'issue comment 99' "$GH_LOG" \
    || fail "F: bounce must comment: $(cat "$GH_LOG")"
ok "F: bounce flips agent-ready → agent-blocked and comments"

# ============================================================================
# Phase G: CLAIM_OK bounce is a no-op (no gh writes)
# ============================================================================
printf '%s\n' "$complete" >"$scratch/body.md"
: >"$GH_LOG"
if "$bin" bounce -R Nishfleet/fleet-ops --issue 99 --body "$scratch/body.md" >/dev/null; then
    [[ ! -s "$GH_LOG" ]] || fail "G: CLAIM_OK bounce must not call gh, log=$(cat "$GH_LOG")"
    ok "G: CLAIM_OK bounce does not touch gh"
else
    fail "G: CLAIM_OK bounce must exit 0"
fi

echo "all phases passed"
