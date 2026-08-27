#!/usr/bin/env bash
# tests/cancelled-while-queued-detector.test.sh
#
# fleet-ops#819: cancelled-while-queued billing-bomb detector.
# Offline. Uses --from-json to replay fixture runs so the inner loop
# runs anywhere. Proves:
#
#   1. Stale queued run (created 30+ min ago) -> 1 detected, 1
#      cancelled (dry-run returns ok=true), 1 filed, 0 deduped.
#   2. Fresh queued run (created <30 min ago) -> 0 detected, quiet.
#   3. Stale queued run with an open issue carrying the same hash
#      marker -> 1 detected, 0 filed, 1 deduped.
#   4. observe-to-close: a stale-queued run no longer in the
#      current scan but with an open labelled issue -> 0 detected,
#      the open issue is closed.
#   5. Pure-function unit tests: minutesBetween, isQueuedStatus,
#      runSignature, signatureHash, detectStaleQueued, isDuplicated,
#      renderIssueTitle, renderIssueBody, parseEnrolledRepos.
#   6. Workflow shape: workflow_call + schedule + issues:write.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/cancelled-while-queued-detector.mjs"
fixtures="$here/fixtures/cancelled-while-queued-detector"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "detector script not found: $script"
node --check "$script" || fail "detector script failed node --check"
node "$script" --help >/dev/null || fail "detector --help failed"

cd "$repo_root"

# --- pure-function unit tests ------------------------------------------------
node --input-type=module -e '
import {
  minutesBetween,
  isQueuedStatus,
  runSignature,
  signatureHash,
  toQueuedRun,
  detectStaleQueued,
  isDuplicated,
  renderIssueTitle,
  renderIssueBody,
  parseEnrolledRepos,
} from "./.github/scripts/cancelled-while-queued-detector.mjs";

// minutesBetween: a 30-min-old run with now=2026-08-23T11:32:00Z and
// created_at=2026-08-23T11:02:00Z is exactly 30.
const nowMs = Date.parse("2026-08-23T11:32:00Z");
if (minutesBetween("2026-08-23T11:02:00Z", nowMs) !== 30) throw new Error("minutesBetween 30min must be 30");
if (minutesBetween("", nowMs) !== 0) throw new Error("empty ts must be 0");
if (minutesBetween("not-a-date", nowMs) !== 0) throw new Error("invalid ts must be 0");
if (minutesBetween("2026-08-23T12:00:00Z", nowMs) !== 0) throw new Error("future ts must clamp to 0 (no negative wait)");

// isQueuedStatus: default statuses cover pending/queued/waiting,
// exclude in_progress/completed.
if (!isQueuedStatus("queued")) throw new Error("queued must be a queued status");
if (!isQueuedStatus("pending")) throw new Error("pending must be a queued status");
if (!isQueuedStatus("waiting")) throw new Error("waiting must be a queued status");
if (isQueuedStatus("in_progress")) throw new Error("in_progress must NOT be a queued status (already running, no auto-cancel)");
if (isQueuedStatus("completed")) throw new Error("completed must NOT be a queued status");
if (isQueuedStatus("cancelled")) throw new Error("cancelled must NOT be a queued status");
// Custom statuses override the default.
if (!isQueuedStatus("in_progress", ["in_progress"])) throw new Error("custom status list must override default");
if (isQueuedStatus("queued", ["pending"])) throw new Error("custom status list must drop defaults");

// runSignature: stable, repo+run_id.
if (runSignature("Nishfleet/0509", 123) !== "Nishfleet/0509\u241F123") throw new Error("signature must be repo+run_id with unit-separator");
if (runSignature("Nishfleet/0509", 123) !== runSignature("Nishfleet/0509", 123)) throw new Error("signature must be deterministic");
if (runSignature("Nishfleet/0509", 123) === runSignature("Nishfleet/0509", 124)) throw new Error("different run_ids must yield different signatures");
if (runSignature("Nishfleet/0509", 1) === runSignature("Nishfleet/fleet-ops", 1)) throw new Error("different repos must yield different signatures");

// signatureHash: 64 hex chars, deterministic.
const h = signatureHash("a\u241Fb");
if (!/^[0-9a-f]{64}$/.test(h)) throw new Error("hash must be sha256 hex");
if (signatureHash("a\u241Fb") !== h) throw new Error("hash must be deterministic");

// toQueuedRun: null for in_progress, null for fresh, full record for stale.
const baseRun = {
  id: 1, name: "CI", event: "pull_request", status: "queued", conclusion: null,
  head_branch: "b", head_sha: "abc", created_at: "2026-08-23T11:00:00Z",
  html_url: "https://x", pull_request_numbers: [42], pull_requests: [{number: 42}],
};
if (toQueuedRun({ ...baseRun, status: "in_progress" }, { repo: "r", nowMs, queuedThresholdMinutes: 30 }) !== null) throw new Error("in_progress must yield null");
if (toQueuedRun({ ...baseRun, created_at: "2026-08-23T11:25:00Z" }, { repo: "r", nowMs, queuedThresholdMinutes: 30 }) !== null) throw new Error("fresh queued must yield null");
const r = toQueuedRun(baseRun, { repo: "Nishfleet/0509", nowMs, queuedThresholdMinutes: 30 });
if (r === null) throw new Error("stale queued must yield a record");
if (r.repo !== "Nishfleet/0509") throw new Error("record repo mismatch");
if (r.run_id !== 1) throw new Error("record run_id mismatch");
if (r.queued_for_minutes !== 32) throw new Error(`record queued_for_minutes must be 32, got ${r.queued_for_minutes}`);
if (r.pr !== 42) throw new Error("record pr mismatch");
if (r.hash !== signatureHash(runSignature("Nishfleet/0509", 1))) throw new Error("record hash must equal signatureHash(signature)");

// detectStaleQueued: filters to the threshold and only queued statuses.
const many = [
  baseRun, // stale queued
  { ...baseRun, id: 2, status: "in_progress" }, // excluded: in_progress
  { ...baseRun, id: 3, created_at: "2026-08-23T11:25:00Z" }, // excluded: fresh
  { ...baseRun, id: 4, status: "completed" }, // excluded: completed
  { ...baseRun, id: 5, status: "pending" }, // included: pending is queued
];
const out = detectStaleQueued(many, { repo: "Nishfleet/0509", nowMs, queuedThresholdMinutes: 30 });
if (out.length !== 2) throw new Error(`detectStaleQueued must return 2 (queued + pending), got ${out.length}`);
if (!out.some((x) => x.run_id === 1) || !out.some((x) => x.run_id === 5)) throw new Error("detectStaleQueued must keep the queued AND pending records");
if (out.some((x) => x.run_id === 2 || x.run_id === 3 || x.run_id === 4)) throw new Error("detectStaleQueued must drop in_progress, fresh, completed");

// isDuplicated: open issues carrying the hash marker are the dedup ledger.
const hash = signatureHash(runSignature("Nishfleet/0509", 1));
if (isDuplicated([], hash)) throw new Error("empty open issues must not dedup");
if (isDuplicated([{number: 1, body: "unrelated"}], hash)) throw new Error("non-matching body must not dedup");
if (isDuplicated([{number: 1, body: null}], hash)) throw new Error("null body must not dedup");
if (!isDuplicated([{number: 1, body: `<!-- cancelled-while-queued-sig: ${hash} -->\nbody`}], hash)) throw new Error("body with the marker must dedup");
// Differentiate from the findings-queued marker (different prefix).
if (isDuplicated([{number: 1, body: `<!-- signal: findings-queued/xyz -->`}], hash)) throw new Error("findings-queued marker must NOT dedup this detector");

// renderIssueTitle / renderIssueBody: name repo + workflow + run, carry
// the hash marker, name the threshold.
const fakeR = { repo: "Nishfleet/0509", run_id: 1, run_url: "u", workflow: "CI", event: "pull_request", head_branch: "b", head_sha: "abc", pr: 42, created_at: "2026-08-23T11:00:00Z", queued_for_minutes: 32, status: "queued", signature: "s", hash };
const title = renderIssueTitle(fakeR);
if (!title.includes("[cancelled-while-queued]")) throw new Error("title must carry the label tag");
if (!title.includes("Nishfleet/0509")) throw new Error("title must name the repo");
if (!title.includes("CI")) throw new Error("title must name the workflow");
if (!title.includes("#1")) throw new Error("title must name the run id");
const body = renderIssueBody(fakeR);
if (!body.includes(`<!-- cancelled-while-queued-sig: ${fakeR.hash} -->`)) throw new Error("body must carry the hash marker");
if (!body.includes("GitHub-hosted runner")) throw new Error("body must explain the billing surface");
if (!body.includes("45")) throw new Error("body must name the 45-min auto-discard threshold");
if (!body.includes("30")) throw new Error("body must name the 30-min cancel threshold");
if (!body.includes("observe-to-close")) throw new Error("body must name observe-to-close");

// parseEnrolledRepos: reads intake-repos.json, excludes permanent exclusions.
const enrolled = parseEnrolledRepos(JSON.stringify({
  repos: [{name: "0509"}, {name: "fleet-ops"}],
  excluded: [{name: "fleet2", permanent: true}, {name: "siterep", permanent: true}],
}));
if (!enrolled.includes("Nishfleet/0509")) throw new Error("0509 must be enrolled");
if (!enrolled.includes("Nishfleet/fleet-ops")) throw new Error("fleet-ops must be enrolled");
if (enrolled.includes("Nishfleet/fleet2")) throw new Error("permanently excluded fleet2 must NOT be enrolled");
if (enrolled.includes("Nishfleet/siterep")) throw new Error("permanently excluded siterep must NOT be enrolled");
if (parseEnrolledRepos("not json").length !== 0) throw new Error("invalid json must yield []");
if (parseEnrolledRepos("{}").length !== 0) throw new Error("empty object must yield []");

console.log("OK: pure function tests (minutesBetween, isQueuedStatus, signature, detect, dedup, render, enrolled)");
' || fail "pure function tests failed"

# --- replay: stale queued run -> 1 detected, 1 cancelled, 1 filed -----------
# The fixture run was created at 2026-08-23T11:00:00Z; pin --now to
# 2026-08-23T11:32:00Z so the detector sees it as 32 min old, just
# past the 30-min threshold.
node "$script" \
  --from-json "$fixtures/stale-queued.json" \
  --output-json /tmp/cwq-stale.json \
  --queued-threshold-minutes 30 \
  --lookback-hours 24 \
  --now 2026-08-23T11:32:00Z \
  --dry-run >/dev/null
node --input-type=module -e '
import { readFileSync } from "node:fs";
const r = JSON.parse(readFileSync("/tmp/cwq-stale.json", "utf8"));
const t = r.targets[0];
if (t.repo !== "Nishfleet/0509") throw new Error(`stale replay repo mismatch, got ${t.repo}`);
if (t.detected.length !== 1) throw new Error(`stale replay must detect 1, got ${t.detected.length}`);
if (t.detected[0].run_id !== 32636816498) throw new Error(`detected run_id mismatch, got ${t.detected[0].run_id}`);
if (t.detected[0].queued_for_minutes < 30) throw new Error(`detected queued_for_minutes must be >= 30, got ${t.detected[0].queued_for_minutes}`);
if (t.cancelled.length !== 1) throw new Error(`stale replay must cancel 1, got ${t.cancelled.length}`);
if (!t.cancelled[0].ok) throw new Error("dry-run cancel must report ok=true");
if (t.filed.length !== 1) throw new Error(`stale replay must file 1, got ${t.filed.length}`);
if (t.filed[0].deduped !== false) throw new Error("first stale-queued run must not be deduped");
if (t.closed.length !== 0) throw new Error("stale replay must not close anything (no open issues in fixture)");
if (t.errors.length !== 0) throw new Error(`stale replay must not error, got ${JSON.stringify(t.errors)}`);
console.log("OK: stale-queued run -> detected + cancelled + filed (no dedup, no close)");
' || fail "stale-queued replay failed"

# --- replay: fresh queued run -> 0 detected, quiet ---------------------------
# The fixture run was created at 2026-08-23T11:25:00Z; pin --now to
# 2026-08-23T11:32:00Z so the detector sees it as 7 min old, well
# under the 30-min threshold.
node "$script" \
  --from-json "$fixtures/fresh-queued.json" \
  --output-json /tmp/cwq-fresh.json \
  --queued-threshold-minutes 30 \
  --lookback-hours 24 \
  --now 2026-08-23T11:32:00Z \
  --dry-run >/dev/null
node --input-type=module -e '
import { readFileSync } from "node:fs";
const r = JSON.parse(readFileSync("/tmp/cwq-fresh.json", "utf8"));
const t = r.targets[0];
if (t.detected.length !== 0) throw new Error(`fresh-queued must yield 0 detected, got ${t.detected.length}`);
if (t.cancelled.length !== 0) throw new Error("fresh-queued must yield 0 cancelled");
if (t.filed.length !== 0) throw new Error("fresh-queued must yield 0 filed");
if (t.closed.length !== 0) throw new Error("fresh-queued must yield 0 closed");
console.log("OK: fresh-queued run (<30 min) -> quiet (no detect, no file)");
' || fail "fresh-queued replay failed"

# --- replay: deduped against open issue -> no new filing ---------------------
node "$script" \
  --from-json "$fixtures/deduped.json" \
  --output-json /tmp/cwq-dedup.json \
  --queued-threshold-minutes 30 \
  --lookback-hours 24 \
  --now 2026-08-23T11:32:00Z \
  --dry-run >/dev/null
node --input-type=module -e '
import { readFileSync } from "node:fs";
const r = JSON.parse(readFileSync("/tmp/cwq-dedup.json", "utf8"));
const t = r.targets[0];
if (t.detected.length !== 1) throw new Error(`dedup fixture still detects the run, got ${t.detected.length}`);
if (t.filed.length !== 1) throw new Error("dedup fixture must report the filing decision");
if (t.filed[0].deduped !== true) throw new Error("open issue with the hash marker must dedupe — no new filing");
console.log("OK: signature bound — open issue with hash marker dedupes (no duplicate filing)");
' || fail "deduped replay failed"

# --- replay: observe-to-close (no current detection, open issue closes) -----
node "$script" \
  --from-json "$fixtures/observe-to-close.json" \
  --output-json /tmp/cwq-otc.json \
  --queued-threshold-minutes 30 \
  --lookback-hours 24 \
  --now 2026-08-23T11:32:00Z \
  --dry-run >/dev/null
node --input-type=module -e '
import { readFileSync } from "node:fs";
const r = JSON.parse(readFileSync("/tmp/cwq-otc.json", "utf8"));
const t = r.targets[0];
if (t.detected.length !== 0) throw new Error(`observe-to-close fixture: 0 detected (the run is in_progress now, not queued), got ${t.detected.length}`);
if (t.closed.length !== 1) throw new Error(`observe-to-close fixture must close 1 stale issue, got ${t.closed.length}`);
if (t.closed[0].number !== 9999) throw new Error(`closed issue number must be 9999, got ${t.closed[0].number}`);
console.log("OK: observe-to-close closes the labelled issue when the run is no longer reported as queued");
' || fail "observe-to-close replay failed"

# --- workflow shape: reusable + schedule + issues:write + auto-discovery -----
# The workflow file is parked under docs/pending-cancelled-while-queued/
# because the nishfleet-worker App has no workflows permission
# (nishfleet-worker CONTENTS / PULL_REQUESTS / ISSUES only). The PR
# delivers the workflow content; Nish's own scope lands it under
# .github/workflows/. Tests verify the parked copy has the right
# shape so a future refactor cannot regress the workflow content.
wf="$repo_root/docs/pending-cancelled-while-queued/cancelled-while-queued.yml"
[[ -f "$wf" ]] || fail "cancelled-while-queued.yml not found in docs/pending-cancelled-while-queued/"
grep -q 'workflow_call:' "$wf" || fail "cancelled-while-queued.yml must declare workflow_call"
grep -q 'schedule:' "$wf" || fail "cancelled-while-queued.yml must run on schedule (central sweep per #185)"
grep -q 'timeout-minutes:' "$wf" || fail "cancelled-while-queued.yml job must set timeout-minutes"
grep -q 'issues: write' "$wf" || fail "workflow needs issues: write to file labelled issues"
grep -q 'actions: read' "$wf" || fail "workflow needs actions: read to call the actions API"
grep -q 'config/intake-repos.json' "$wf" || fail "sweep must enumerate enrolled repos from config/intake-repos.json (#185 auto-discovery)"
grep -q 'cancel' "$script" || fail "detector must call the cancel endpoint"
grep -q "method.*POST\|POST" "$script" || fail "detector must POST to the cancel endpoint"
ok "cancelled-while-queued.yml shape (workflow_call + schedule + issues:write + actions:read + auto-discovery + POST)"

# --- contract: nested under the CI host (seat-lib.test.sh hosts the chain) -
grep -Fq 'bash "$here/cancelled-while-queued-detector.test.sh"' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "contracts: nested CI host"

# --- detector wiring is documented in AGENTS.md (findable from a worker) -----
grep -q 'cancelled-while-queued' "$repo_root/AGENTS.md" \
  || fail "AGENTS.md must name the detector so workers can re-run it"
ok "AGENTS.md documents the detector (so a worker can re-run it from a fresh checkout)"

echo "OK: cancelled-while-queued-detector: stale-queued cancel + labelled issue, dedup, observe-to-close, dry-run, workflow shape"
