#!/usr/bin/env bash
# tests/opus-heartbeat-verify-cue-gate.test.sh
#
# fleet-ops#3731: the THOROUGH random_merged_pr_verify slot ran a PRIVATE
# cue grammar (a line-start check for "verification:"/"run-proof:") that
# had drifted from the merge-gate grammar in lib/exec-review-receipt.py.
# On fleet-ops#3717 — a merged PR whose body carried `## Verification` +
# a fenced run and a `## run-proof` heading — the slot reported
# verify_claim=null / has_verify_cue=false, and the judge filed a false
# "unverified merge" finding (this issue). The 2026-09-05/06 24h merged
# sample showed 9 of 60 PRs flagged by the slot grammar; every one of
# them carried real run evidence (`## Test plan` checked command boxes,
# `## Verification` command bullets, `## run-proof` headings).
#
# Fix: the slot classifies with the SHARED grammar — it loads
# has_receipt() from the installed lib/exec-review-receipt.py
# (~/.local/lib/pi-packet/exec-review-receipt.py, a symlink into the
# deploy clone, env seam OPUS_HB_RECEIPT_LIB) so the sampler, the worker
# --body gate, the heartbeat scan/disarm, and the tier1 arm gate can never
# disagree on the same body again. revert/ heads are exempt (same as the
# tier1 arm gate — auto-revert has no worker to produce a cue). The slot
# also reports the full 24h census (candidates_24h, classified_24h,
# missing_cue, missing_slugs) so one sampled false negative cannot
# masquerade as the fleet-wide rate.
#
# This test drives the gather's hermetic `--check-verify-cue-gate
# <fixture>` self-check (no live gh) over the real merged-body shapes,
# plus a source-pin scenario that greps the installed gather for the
# fleet-ops#3731 citation, the shared-grammar loader, the revert
# exemption, and the census keys, so a refactor cannot silently drop the
# shared grammar without failing here.
#
# Live/VPS-only (per the existing opus-heartbeat-* test convention): the
# gather script at /home/nish/.local/libexec/opus-heartbeat-gather is
# absent on hosted CI runners.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

GATHER="${OPUS_HB_GATHER:-/home/nish/.local/libexec/opus-heartbeat-gather}"
REPO_LIB="${OPUS_HB_RECEIPT_LIB:-$repo_root/lib/exec-review-receipt.py}"
TMP_DIR="$(mktemp -d -t opus-3731-gate.XXXXXX)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$GATHER" ]] || fail "gather missing: $GATHER"
[[ -f "$REPO_LIB" ]] || fail "receipt lib missing: $REPO_LIB"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM

cat >"$TMP_DIR/cases.json" <<'JSON'
{"cases": [
  {"name": "verification-fenced-3717", "expect": true,
   "body": "## What changed\n\n- x\n\n## Verification\n\n```\n$ bash tests/fleet-metrics-export.test.sh\nOK: section 9b passed\n```\n\nFull run completed with `exit 0`.\n\n## run-proof\n\n`bash tests/x.test.sh` exit 0.\n"},
  {"name": "testplan-checked-3734", "expect": true,
   "body": "## Summary\n\n- changed\n\n#### Test plan\n\n- [x] `bash tests/seat-lib-aimd.test.sh` — exit 0\n- [x] `bash tests/fleet-token-economy.test.sh` — exit 0\n- [ ] CI green\n"},
  {"name": "testplan-h2-1712", "expect": true,
   "body": "## Test plan\n\n- [x] `npx vitest run --project node` — 6826 tests pass\n"},
  {"name": "verification-bullet-cmd-3761", "expect": true,
   "body": "## Verification\n\n- `bash tests/fleet-close-and-archive-repo.test.sh` — all drill checks pass\n"},
  {"name": "testplan-unbackticked-result-3627", "expect": true,
   "body": "## Test plan\n\n- [x] fleet-restore-drill passes: backup/restore/verify OK\n"},
  {"name": "runproof-inline", "expect": true,
   "body": "## Summary\n\nrun-proof: journal fleet-heartbeat exit 0\n"},
  {"name": "verification-nocue", "expect": false,
   "body": "## Verification\n\n- I did the thing.\n"},
  {"name": "testplan-unchecked-only", "expect": false,
   "body": "## Test plan\n\n- [ ] `npm test` — to be run\n"},
  {"name": "bare-body", "expect": false,
   "body": "## Summary\n\n- changed some files\n\nCloses #1\n"},
  {"name": "prose-test-plan", "expect": false,
   "body": "## Summary\n\nhere is the test plan: run `npm test` later\n"}
]}
JSON

echo "== scenario 1: shared grammar — every real merged-body shape classifies as a receipt; prose/unchecked do not"
OPUS_HB_RECEIPT_LIB="$REPO_LIB" "$GATHER" --check-verify-cue-gate "$TMP_DIR/cases.json" \
  >"$TMP_DIR/gate.out" 2>"$TMP_DIR/gate.err" \
  || fail "scenario 1: shared grammar mismatched a real body shape ($(cat "$TMP_DIR/gate.err"))"
grep -q '"grammar":"shared"' "$TMP_DIR/gate.out" \
  || fail "scenario 1: slot did not load the shared lib ($(cat "$TMP_DIR/gate.out"))"
grep -q '"mismatches":\[\]' "$TMP_DIR/gate.out" \
  || fail "scenario 1: mismatches present ($(cat "$TMP_DIR/gate.out"))"
ok "scenario 1: --check-verify-cue-gate — all real merged-body shapes classify correctly under the shared grammar"

echo "== scenario 2: fallback path — a missing receipt lib drops to the legacy line check, never raises"
set +e
OPUS_HB_RECEIPT_LIB="$TMP_DIR/no-such-lib.py" "$GATHER" --check-verify-cue-gate "$TMP_DIR/cases.json" \
  >"$TMP_DIR/fb.out" 2>"$TMP_DIR/fb.err"
fb_rc=$?
set -e
[[ "$fb_rc" -eq 0 || "$fb_rc" -eq 1 ]] || fail "scenario 2: fallback path crashed (rc=$fb_rc) — the slot must never raise"
grep -q '"grammar":"fallback-line"' "$TMP_DIR/fb.out" \
  || fail "scenario 2: fallback did not label itself ($(cat "$TMP_DIR/fb.out"))"
ok "scenario 2: missing receipt lib -> grammar=fallback-line, no crash (a slot fault is data, not a crash)"

echo "== scenario 3: source-pin — the installed gather MUST cite #3731 and carry the shared-grammar plumbing"
grep -Fq "fleet-ops#3731" "$GATHER" || fail "scenario 3: gather lost the fleet-ops#3731 citation — shared grammar removed?"
grep -Fq "OPUS_HB_RECEIPT_LIB" "$GATHER" || fail "scenario 3: gather lost the OPUS_HB_RECEIPT_LIB seam"
grep -Fq "_receipt_classifier" "$GATHER" || fail "scenario 3: gather lost _receipt_classifier — private grammar back?"
grep -Fq 'head.startswith("revert/")' "$GATHER" || fail "scenario 3: gather lost the revert/ exemption (tier1 parity)"
grep -Fq '"missing_cue"' "$GATHER" || fail "scenario 3: gather lost the missing_cue census key"
grep -Fq -- "--check-verify-cue-gate" "$GATHER" || fail "scenario 3: gather lost the hermetic self-check"
ok "scenario 3: gather source pins the shared grammar (citation + seam + loader + revert exemption + census keys)"

echo "== scenario 4: installed default — the slot loads the installed receipt lib, grammar reports shared"
# The installed lib is a symlink into the deploy clone; post-merge it IS
# the repo grammar. Assert the plumbing resolves and reports — the strict
# shape assertions live in scenario 1 via the seam.
env -u OPUS_HB_RECEIPT_LIB "$GATHER" --check-verify-cue-gate "$TMP_DIR/cases.json" \
  >"$TMP_DIR/def.out" 2>"$TMP_DIR/def.err" || true
python3 - "$TMP_DIR/def.out" <<'PY' || fail "scenario 4: default run produced no JSON ($(cat "$TMP_DIR/def.err"))"
import json, sys
d = json.loads(open(sys.argv[1]).read())
assert d.get("grammar") in ("shared", "fallback-line"), f"unexpected grammar {d.get('grammar')}"
assert "results" in d and "mismatches" in d, "default run lost the results/mismatches keys"
print("default grammar:", d["grammar"], "mismatches:", d["mismatches"])
PY
ok "scenario 4: installed-lib path resolves and reports its grammar label"

echo "ALL PASS"
