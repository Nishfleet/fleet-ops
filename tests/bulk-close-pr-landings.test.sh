#!/usr/bin/env bash
# tests/bulk-close-pr-landings.test.sh
#
# Proves the housekeeping close tool's decision logic without reaching
# GitHub. The pure function `isDispositionOnly(title, files)` is the
# contract: title starts with `docs(pr-landing):` AND every changed
# file ends with `.md` (no real code diff). One ack comment is posted
# per close (`ackCommentBody`), audit-friendly and pinned to fleet-ops#1162.
#
# Live acceptance: the script's dry-run on `Nishfleet/fleet2` is run
# once at PR time (see VERIFY block in the PR description). This file
# locks the decision matrix that drives the close.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/bulk-close-pr-landings.mjs"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$script" ]] || fail "script not found: $script"
node --check "$script" || fail "script failed node --check"
node "$script" --help >/dev/null 2>&1 || fail "script --help failed"

cd "$repo_root"

node --input-type=module -e '
import {
  isDispositionOnly,
  ackCommentBody,
} from "./.github/scripts/bulk-close-pr-landings.mjs";

const eq = (got, want, msg) => {
  if (got !== want) throw new Error(`${msg}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
};
const deepEq = (got, want, msg) => {
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    throw new Error(`${msg}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
  }
};

// --- The 14 hand-classified "has real code diff" PRs (audit fixtures).
// These MUST be classified as NOT disposition-only (kept). If any of
// them start closing, the filter regressed and we will start eating
// real product work.
const hasCodeCases = [
  // #224 — 0509 #626 codex-node-checks vitest deflake
  { n: 224, title: "docs(pr-landing): 0509 #626 codex-node-checks vitest deflake landed on main",
    files: [
      { path: "PR-LANDING-DISPOSITION-0509-626-landed-20260820.md" },
      { path: "PR-LANDING-DISPOSITION-fleet2-13-superseded-20260820.md" },
      { path: "bin/fleet-dispatch" },
      { path: "bin/fleet-launch-parallel" },
      { path: "bin/fleet-memory" },
      { path: "bin/heartbeat-audit" },
      { path: "etc/lanes.json" },
      { path: "systemd/fleet2-heartbeat-audit.service" },
      { path: "tests/test_heartbeat_audit.py" },
      { path: "tests/test_launcher.py" },
      { path: "tests/test_memory.py" },
    ] },
  // #158 — tinystudio-in #115 (bin/, lib/, systemd/, tests/)
  { n: 158, title: "docs(pr-landing): tinystudio-in #115 superseded",
    files: [
      { path: "bin/fleet-failed-units" },
      { path: "bin/fleet-pr-landing" },
      { path: "lib/fleet_packet_builder.py" },
      { path: "systemd/fleet2-failed-units.service" },
      { path: "tests/test_pr_landing.py" },
    ] },
  // #328 — proof-seo #168 (bin/, etc/, lib/, tests/)
  { n: 328, title: "docs(pr-landing): proof-seo #168 reviewed + merged",
    files: [
      { path: "bin/fleet-dispatch" },
      { path: "etc/lanes.json" },
      { path: "lib/fleet_roster_scout.py" },
      { path: "tests/test_dispatch.py" },
    ] },
  // #225 — fleet2 #10 staleness-gate
  { n: 225, title: "docs(pr-landing): fleet2 #10 staleness-gate simplify-packet",
    files: [
      { path: "bin/fleet-e2e-heartbeat" },
      { path: "tests/test_e2e_heartbeat.py" },
    ] },
  // The four `bin/heartbeat-audit` + `tests/test_heartbeat_audit.py` siblings
  { n: 361, title: "docs(pr-landing): compound-engineering-plugin #1269",
    files: [{ path: "bin/heartbeat-audit" }, { path: "tests/test_heartbeat_audit.py" }] },
  { n: 357, title: "docs(pr-landing): context-hub #211",
    files: [{ path: "bin/heartbeat-audit" }, { path: "tests/test_heartbeat_audit.py" }] },
  { n: 365, title: "docs(pr-landing): last30days-skill #971",
    files: [{ path: "bin/heartbeat-audit" }, { path: "tests/test_heartbeat_audit.py" }] },
  { n: 364, title: "docs(pr-landing): context-hub #306",
    files: [{ path: "bin/heartbeat-audit" }, { path: "tests/test_heartbeat_audit.py" }] },
  // The four `tests/test_pr_landing.py` siblings
  { n: 376, title: "docs(pr-landing): context-hub #302",
    files: [{ path: "tests/test_pr_landing.py" }] },
  { n: 373, title: "docs(pr-landing): last30days-skill #929",
    files: [{ path: "tests/test_pr_landing.py" }] },
  { n: 375, title: "docs(pr-landing): printing-press-library #1769",
    files: [{ path: "tests/test_pr_landing.py" }] },
  { n: 372, title: "docs(pr-landing): last30days-skill #898",
    files: [{ path: "tests/test_pr_landing.py" }] },
  // The two `morning-check.sh` siblings
  { n: 403, title: "docs(pr-landing): last30days-skill #1007",
    files: [{ path: "morning-check.sh" }] },
  { n: 400, title: "docs(pr-landing): compound-engineering-plugin #1256",
    files: [{ path: "morning-check.sh" }] },
];
for (const c of hasCodeCases) {
  eq(isDispositionOnly(c.title, c.files), false, `#${c.n} has real code diff -> not disposition-only`);
}

// --- The textbook pure-markdown cases (close targets).
// Sampled from the live fleet2 PR list (2026-08-27). All files are
// PR-LANDING-DISPOSITION-*.md / FAILED-UNIT-DISPOSITION-*.md.
const pureMdCases = [
  { n: 30, title: "docs(pr-landing): tinystudio-in #156 reviewed and merged",
    files: [{ path: "PR-LANDING-DISPOSITION-tinystudio-in-156-20260820.md" }] },
  { n: 31, title: "docs(pr-landing): tinystudio-in #140 superseded",
    files: [
      { path: "PR-LANDING-DISPOSITION-tinystudio-in-140-superseded-20260820.md" },
      { path: "PR-LANDING-DISPOSITION-tinystudio-in-186-already-merged-20260820.md" },
    ] },
  { n: 32, title: "docs(pr-landing): record 0509 #707 already merged",
    files: [
      { path: "PR-LANDING-DISPOSITION-0509-707-merged-20260820.md" },
      { path: "FAILED-UNIT-DISPOSITION-fleet-gate-lane-worker-0509-5-1787271632640261169-20260820.md" },
    ] },
  { n: 385, title: "docs(pr-landing): context-hub #216 DIRTY",
    files: [{ path: "PR-LANDING-DISPOSITION-context-hub-216-merge-blocked-20260821.md" }] },
];
for (const c of pureMdCases) {
  eq(isDispositionOnly(c.title, c.files), true, `#${c.n} pure md -> disposition-only`);
}

// --- Title-prefix guard.
// A `docs(quarantine):` PR whose body happens to say "PR-LANDING"
// must NOT match (live example: PRs #145, #150). The filter is prefix
// exact, not substring.
eq(isDispositionOnly("docs(quarantine): 0509 PR-LANDING #626", [{ path: "x.md" }]), false,
   "quarantine prefix excluded");
eq(isDispositionOnly("docs(disposition): foo", [{ path: "x.md" }]), false,
   "disposition prefix excluded");
eq(isDispositionOnly("fix(thing): PR-LANDING foo", [{ path: "x.md" }]), false,
   "fix prefix excluded");
eq(isDispositionOnly("docs(pr-landing) without colon", [{ path: "x.md" }]), false,
   "no colon after prefix excluded");
eq(isDispositionOnly("docs(pr-landing): ", [{ path: "x.md" }]), true,
   "empty body after colon still matches");

// --- Defensive input shapes.
eq(isDispositionOnly(null, [{ path: "x.md" }]), false, "null title");
eq(isDispositionOnly(undefined, [{ path: "x.md" }]), false, "undefined title");
eq(isDispositionOnly("docs(pr-landing): x", null), false, "null files");
eq(isDispositionOnly("docs(pr-landing): x", []), false, "empty files");
eq(isDispositionOnly("docs(pr-landing): x", [{ path: "bin/x" }]), false, "non-md file");
eq(isDispositionOnly("docs(pr-landing): x", [{ path: "x.md" }, { path: "y" }]), false,
   "mixed md + non-md excluded");
// Case-sensitive: real GitHub repos use lowercase .md, and treating
// .MD the same as .md risks matching non-markdown paths in odd-encoding
// repos. The filter is conservative on purpose.
eq(isDispositionOnly("docs(pr-landing): x", [{ path: "X.MD" }]), false, "uppercase .MD excluded");
eq(isDispositionOnly("docs(pr-landing): x", "not-an-array"), false, "non-array files excluded");
eq(isDispositionOnly("docs(pr-landing): x", [{ }]), false, "file with no path excluded");
eq(isDispositionOnly("docs(pr-landing): x", [{ path: null }]), false, "file with null path excluded");

// --- The ack comment is audit-friendly and pinned to fleet-ops#1162.
const body = ackCommentBody();
if (!body.startsWith(`<!-- ${"fleet-ops#1162"} -->`)) {
  throw new Error("ack comment must start with the issue marker for audit grep");
}
if (!body.includes("housekeeping") || !body.includes("disposition-only")) {
  throw new Error("ack comment must call out housekeeping + disposition-only rationale");
}
if (!body.includes("auto-merge-arm.yml")) {
  throw new Error("ack comment must reference the no-arm constraint so a future opener sees it");
}
' || fail "decision-logic test failed"

echo "PASS: bulk-close-pr-landings decision logic (14 keep cases + 4 close cases + guards + ack body)"
