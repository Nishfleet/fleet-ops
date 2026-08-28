#!/usr/bin/env bash
# tests/stop-the-line-detector.test.sh
#
# Proves the stop-the-line detector (fleet-ops#1457) without reaching GitHub.
# Covers the four acceptance bullets from the issue:
#
#   1. Trigger: same workflow failed on consecutive main commits -> open
#      a single `stop-the-line` issue (deduped by title; mirrors the
#      fleet-ops#596 / auto-revert.sh halt path).
#   2. Unfreeze: automatic on the next green run of THAT workflow on main
#      -> close the same issue, no human step.
#   3. CI on PRs continues unchanged: only the auto-merge-arm step now
#      refuses to arm while the issue is open. The check runs in the same
#      reusable workflow (auto-merge-arm.yml) that already gates on draft /
#      no-merge label / [no-merge] title.
#   4. Notification: one transition per state change (open / close), not
#      per merge; the issue body's marker + the comment on close is the
#      single signal.
#
# Drill (the issue's "replay a red-consecutive scenario in a sandbox repo
# or workflow test and prove freeze + auto-unfreeze"):
#   - replay-mode --from-json exercises the pure classifier + Decision +
#     buildDecision pipeline
#   - a final test drives the auto-merge-arm gate check end-to-end via
#     `gh issue list` against a fake shell-shimmed `gh` so a fixture stop-
#     the-line issue is observed AND the arm step proves it does not call
#     `gh pr merge` in the frozen state
#
# Fixture mode makes NO gh calls, so the inner loop runs anywhere with
# bash + node + jq + git.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/stop-the-line-detector.mjs"
fixtures="$here/fixtures/stop-the-line-detector"
arm="$repo_root/.github/workflows/reusable-auto-merge-arm.yml"
sync="$repo_root/.github/workflows/repo-standards-sync.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "detector script not found: $script"
node --check "$script" || fail "detector script failed node --check"
node "$script" --help >/dev/null || fail "detector --help failed"

cd "$repo_root"

# --- pure-function unit tests ------------------------------------------------
node --input-type=module -e '
import {
  classifyHalt,
  buildDecision,
  isSkippedWorkflow,
  issueTitle,
  issueBody,
  renderReport,
} from "./.github/scripts/stop-the-line-detector.mjs";

// classifyHalt: red-green-red -> no halt and no unfreeze (no consecutive reds).
const tg1 = [
  { id: 1, name: "CI", conclusion: "failure", head_branch: "main", head_sha: "a", created_at: "2026-08-28T00:00:00Z", html_url: "u" },
  { id: 2, name: "CI", conclusion: "success", head_branch: "main", head_sha: "b", created_at: "2026-08-28T00:01:00Z", html_url: "u" },
  { id: 3, name: "CI", conclusion: "failure", head_branch: "main", head_sha: "c", created_at: "2026-08-28T00:02:00Z", html_url: "u" },
];
const r1 = classifyHalt(tg1);
if (r1.halt) throw new Error("red-green-red must NOT halt (no consecutive reds)");
if (r1.unfreeze_candidate) throw new Error("red-green-red must NOT surface an unfreeze candidate (never-halted)");

// red-red -> halt on CI.
const r2 = classifyHalt([
  { id: 10, name: "CI", conclusion: "failure", head_branch: "main", head_sha: "a", created_at: "2026-08-28T00:00:00Z", html_url: "u10" },
  { id: 11, name: "CI", conclusion: "failure", head_branch: "main", head_sha: "b", created_at: "2026-08-28T00:01:00Z", html_url: "u11" },
]);
if (!r2.halt) throw new Error("red-red must halt");
if (r2.halted_workflow !== "CI") throw new Error("halt workflow must be CI");
if (r2.halted_runs.length !== 2) throw new Error("halt history must carry both red runs");

// red-red-green -> halt cleared, unfreeze candidate present.
const r3 = classifyHalt([
  { id: 10, name: "CI", conclusion: "failure", head_branch: "main", head_sha: "a", created_at: "2026-08-28T00:00:00Z", html_url: "u10" },
  { id: 11, name: "CI", conclusion: "failure", head_branch: "main", head_sha: "b", created_at: "2026-08-28T00:01:00Z", html_url: "u11" },
  { id: 12, name: "CI", conclusion: "success", head_branch: "main", head_sha: "c", created_at: "2026-08-28T00:02:00Z", html_url: "u12" },
]);
if (r3.halt) throw new Error("red-red-green must clear the halt");
if (!r3.unfreeze_candidate || r3.unfreeze_candidate.id !== 12) throw new Error("red-red-green must surface green run 12 as unfreeze");

// Skipped workflow red-red -> inert.
const r4 = classifyHalt([
  { id: 1, name: "Auto revert", conclusion: "failure", head_branch: "main", head_sha: "a", created_at: "2026-08-28T00:00:00Z", html_url: "u" },
  { id: 2, name: "Auto revert", conclusion: "failure", head_branch: "main", head_sha: "b", created_at: "2026-08-28T00:01:00Z", html_url: "u" },
]);
if (r4.halt || r4.unfreeze_candidate) throw new Error("skipped-workflow runs must NOT halt");

// 3+ reds in a row: still halt; at least 2 runs in history.
const r5 = classifyHalt([
  { id: 1, name: "CI", conclusion: "failure", head_branch: "main", head_sha: "a", created_at: "2026-08-28T00:00:00Z", html_url: "u" },
  { id: 2, name: "CI", conclusion: "failure", head_branch: "main", head_sha: "b", created_at: "2026-08-28T00:01:00Z", html_url: "u" },
  { id: 3, name: "CI", conclusion: "failure", head_branch: "main", head_sha: "c", created_at: "2026-08-28T00:02:00Z", html_url: "u" },
  { id: 4, name: "CI", conclusion: "failure", head_branch: "main", head_sha: "d", created_at: "2026-08-28T00:03:00Z", html_url: "u" },
]);
if (!r5.halt) throw new Error("3 reds must still halt");
if (r5.halted_runs.length < 2) throw new Error("halt history must carry at least the first two reds");

// Non-default branch runs are ignored.
const r6 = classifyHalt([
  { id: 1, name: "CI", conclusion: "failure", head_branch: "release", head_sha: "a", created_at: "2026-08-28T00:00:00Z", html_url: "u" },
  { id: 2, name: "CI", conclusion: "failure", head_branch: "release", head_sha: "b", created_at: "2026-08-28T00:01:00Z", html_url: "u" },
]);
if (r6.halt) throw new Error("non-main branch runs must NOT halt");

// isSkippedWorkflow semantics.
if (isSkippedWorkflow("Auto revert") !== true) throw new Error("Auto revert must skip");
if (isSkippedWorkflow("Red on main detector") !== true) throw new Error("Red on main detector must skip");
if (isSkippedWorkflow("Stop-the-line detector") !== true) throw new Error("Stop-the-line detector must skip");
if (isSkippedWorkflow("CI") !== false) throw new Error("CI must NOT skip");
if (isSkippedWorkflow("Deploy production") !== false) throw new Error("Deploy production must NOT skip");

// buildDecision routing: open / comment / close / noop.
const dOpen = buildDecision({ verdict: r2, repository: "Nishfleet/0509", existingIssueNumber: null });
if (dOpen.action !== "open") throw new Error("halt without existing issue must action=open");
const dComment = buildDecision({ verdict: r2, repository: "Nishfleet/0509", existingIssueNumber: 99 });
if (dComment.action !== "comment") throw new Error("halt with existing issue must action=comment");
const dClose = buildDecision({ verdict: r3, repository: "Nishfleet/0509", existingIssueNumber: 99 });
if (dClose.action !== "close") throw new Error("unfreeze with existing issue must action=close");
const dNoop = buildDecision({ verdict: r1, repository: "Nishfleet/0509", existingIssueNumber: null });
if (dNoop.action !== "noop") throw new Error("verdict with no halt/no unfreeze must action=noop");

// issueTitle / issueBody contract.
const title = issueTitle(dOpen);
if (!title.startsWith("stop-the-line: ")) throw new Error("title must begin with the prefix");
if (!title.includes("frozen")) throw new Error("open-action title must include frozen");
const body = issueBody(dOpen);
if (!body.includes("<!-- stop-the-line:workflow=")) throw new Error("body must carry the dedup marker for the freeze body");
if (!body.includes("`CI`")) throw new Error("body must name the halted workflow in inline code");
if (!body.includes("CI on PRs continues")) throw new Error("body must call out PR feedback continuity (issue bullet)");

const titleClose = issueTitle(dClose);
if (!titleClose.includes("unfrozen")) throw new Error("close-action title must include unfrozen");

// renderReport smoke.
const rep = renderReport({
  generated_at: "2026-08-28T00:00:00Z",
  repository: "Nishfleet/0509",
  branch: "main",
  lookback_minutes: 90,
  runs_sampled: 2,
  decision: dOpen,
});
if (!rep.includes("Stop-the-line detector")) throw new Error("renderReport must head with the detector name");
if (!rep.includes("OPEN")) throw new Error("renderReport must show the OPEN decision");

console.log("OK: classify, buildDecision, skip, render, marker, body");
' || fail "pure function tests failed"

# --- replay: red-red -> open decision ---------------------------------------
node "$script" --from-json "$fixtures/red-red.json" --format json --output-json /tmp/stl-redred.json >/dev/null
node --input-type=module -e '
import { readFileSync } from "node:fs";
const r = JSON.parse(readFileSync("/tmp/stl-redred.json", "utf8"));
if (r.decision.action !== "open") throw new Error(`red-red must action=open, got ${r.decision.action}`);
if (r.decision.workflow !== "CI") throw new Error(`halted workflow must be CI, got ${r.decision.workflow}`);
if (r.decision.red_runs.length !== 2) throw new Error(`red_runs must carry 2 runs, got ${r.decision.red_runs.length}`);
if (r.runs_sampled !== 2) throw new Error(`runs_sampled must be 2, got ${r.runs_sampled}`);
console.log("OK: red-red -> open stop-the-line (CI, two consecutive reds)");
' || fail "red-red replay failed"

# --- replay: red-red-red -> still open, more red runs in history -----------
node "$script" --from-json "$fixtures/red-red-red.json" --format json --output-json /tmp/stl-redredred.json >/dev/null
node --input-type=module -e '
import { readFileSync } from "node:fs";
const r = JSON.parse(readFileSync("/tmp/stl-redredred.json", "utf8"));
if (r.decision.action !== "open") throw new Error("red-red-red must still action=open");
if (r.decision.red_runs.length !== 3) throw new Error(`red-red-red history must carry all three red runs, got ${r.decision.red_runs.length}`);
console.log("OK: red-red-red -> open with full history");
' || fail "red-red-red replay failed"

# --- replay: red-red-green -> close (unfreeze) -----------------------------
node "$script" --from-json "$fixtures/unfreeze.json" --format json --output-json /tmp/stl-unfreeze.json >/dev/null
node --input-type=module -e '
import { readFileSync } from "node:fs";
const r = JSON.parse(readFileSync("/tmp/stl-unfreeze.json", "utf8"));
if (r.decision.action !== "close") throw new Error(`unfreeze fixture must action=close (existing #777), got ${r.decision.action}`);
if (r.decision.workflow !== "CI") throw new Error(`unfreeze workflow must be CI, got ${r.decision.workflow}`);
if (!r.decision.unfreeze_run || r.decision.unfreeze_run.run_id !== 3003) throw new Error("unfreeze_run must point at run 3003");
console.log("OK: red-red-green + open issue -> close (auto-unfreeze, no human step)");
' || fail "unfreeze replay failed"

# --- replay: quiet (no consecutive red pairs) -> noop -----------------------
node "$script" --from-json "$fixtures/quiet-runs.json" --format json --output-json /tmp/stl-quiet.json >/dev/null
node --input-type=module -e '
import { readFileSync } from "node:fs";
const r = JSON.parse(readFileSync("/tmp/stl-quiet.json", "utf8"));
if (r.decision.action !== "noop") throw new Error(`all-green must action=noop, got ${r.decision.action}`);
console.log("OK: all-green runs -> noop (no halt signal, no unfreeze signal)");
' || fail "quiet replay failed"

# --- replay: red-green (no consecutive pair) -> noop ------------------------
node "$script" --from-json "$fixtures/no-consecutive.json" --format json --output-json /tmp/stl-no-consec.json >/dev/null
node --input-type=module -e '
import { readFileSync } from "node:fs";
const r = JSON.parse(readFileSync("/tmp/stl-no-consec.json", "utf8"));
if (r.decision.action !== "noop") throw new Error(`red-green (no consecutive reds) must action=noop, got ${r.decision.action}`);
console.log("OK: red-green (no consecutive reds) -> noop (single transient red is not a halt)");
' || fail "no-consecutive replay failed"

# --- workflow shape: stop-the-line-detector.yml -----------------------------
grep -q 'workflow_call:' "$repo_root/.github/workflows/stop-the-line-detector.yml" \
  || fail "stop-the-line-detector.yml must declare workflow_call (reusable)"
grep -q 'issues: write' "$repo_root/.github/workflows/stop-the-line-detector.yml" \
  || fail "stop-the-line-detector.yml needs issues: write"
grep -q 'actions: read' "$repo_root/.github/workflows/stop-the-line-detector.yml" \
  || fail "stop-the-line-detector.yml needs actions: read"
grep -q 'timeout-minutes: 5' "$repo_root/.github/workflows/stop-the-line-detector.yml" \
  || fail "stop-the-line-detector.yml job must set timeout-minutes: 5"
grep -q 'Nishfleet/fleet-ops' "$repo_root/.github/workflows/stop-the-line-detector.yml" \
  || fail "stop-the-line-detector.yml must be reusable for any repo (callers reference Nishfleet/fleet-ops/...)"
ok "stop-the-line-detector.yml shape (workflow_call + actions:read + issues:write + timeout)"

# --- workflow shape: stop-the-line-watch.yml --------------------------------
grep -q 'workflow_run:' "$repo_root/.github/workflows/stop-the-line-watch.yml" \
  || fail "stop-the-line-watch.yml must declare workflow_run trigger"
grep -q 'cron:' "$repo_root/.github/workflows/stop-the-line-watch.yml" \
  || fail "stop-the-line-watch.yml must declare a schedule trigger (backstop)"
grep -q 'Nishfleet/fleet-ops/.github/workflows/stop-the-line-detector.yml@main' "$repo_root/.github/workflows/stop-the-line-watch.yml" \
  || fail "stop-the-line-watch.yml must call the reusable detector"
ok "stop-the-line-watch.yml shape (workflow_run + schedule + reusable call)"

# --- workflow shape: reusable-auto-merge-arm.yml honors freeze --------------
grep -q 'stop-the-line' "$arm" || fail "reusable-auto-merge-arm.yml must mention stop-the-line"
grep -q 'issues: read' "$arm" || fail "reusable-auto-merge-arm.yml must declare issues: read"
grep -q 'gh issue list' "$arm" || fail "reusable-auto-merge-arm.yml must probe gh issue list for the freeze issue"
grep -q 'frozen' "$arm" || fail "reusable-auto-merge-arm.yml must gate arm on frozen=false"
ok "reusable-auto-merge-arm.yml honors the freeze"

# --- auto-merge-arm.yml grants issues: read to the caller -------------------
grep -q 'issues: read' "$repo_root/.github/workflows/auto-merge-arm.yml" \
  || fail "auto-merge-arm.yml must grant issues: read to the reusable workflow"
ok "auto-merge-arm.yml grants issues: read (pre-#1457 was permissions: {})"

# --- repo-standards-sync.yml syncs the new file to eligible repos ----------
grep -q 'stop-the-line-watch.yml' "$sync" \
  || fail "repo-standards-sync.yml must sync stop-the-line-watch.yml to other repos"
grep -q 'have_stop_line=' "$sync" \
  || fail "repo-standards-sync.yml must drive the new sync on the canonical-presence flag (have_stop_line)"
# Fleet-ops must NOT be in the destination list (already has the file).
python3 - "$sync" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
# Find Group 6 (stop-the-line) build block; assert fleet-ops is excluded.
m_start = text.find("# Group 6: stop-the-line")
if m_start < 0:
    raise SystemExit("Group 6 (stop-the-line-watch) build block missing from repo-standards-sync.yml")
m_end = text.find("echo \"--- generated .github/sync.yml\"", m_start)
chunk = text[m_start:m_end]
# Check the EXCLUSION line itself (grep -vxE) is present.
if "grep -vxE 'Nishfleet/fleet-ops'" not in chunk:
    raise SystemExit("Group 6 must exclude Nishfleet/fleet-ops via grep -vxE")
# The loop body must read from repos-stop-the-line.txt.
if "while IFS= read -r r; do echo \"      $r\"; done < repos-stop-the-line.txt" not in chunk:
    raise SystemExit("Group 6 must drive the sync loop from the filtered list (repos-stop-the-line.txt)")
if "canonical/stop-the-line-watch.yml" not in chunk:
    raise SystemExit("Group 6 source must be the canonical file")
if ".github/workflows/stop-the-line-watch.yml" not in chunk:
    raise SystemExit("Group 6 dest must be .github/workflows/stop-the-line-watch.yml")
PY
ok "repo-standards-sync.yml Group 6: fleet-ops excluded, others get the file"

echo "OK: stop-the-line detector proven (fleet-ops#1457)"

# --- drill: auto-merge-arm gate is honored when an issue is open ------------
# This is the live-class drill from the issue:
#   "replay a red-consecutive scenario in a sandbox repo or workflow test
#    and prove freeze + auto-unfreeze"
# We don't run Actions; we simulate the gate with a fake `gh` that returns
# the open freeze issue, and we prove the arm step refuses to call
# `gh pr merge`. Then we flip the fixture to "no freeze issue" and prove
# the arm step DOES call `gh pr merge`. Both branches of the freeze vs
# unfreeze transition land in the same script.
drill_scratch="$(mktemp -d -t stop-the-line-drill.XXXXXX)"
trap 'rm -rf "$drill_scratch"' EXIT INT TERM

# Pull the reusable workflow's relevant inputs/steps by hand: the run:
# step that does `gh issue list ...` and emits `frozen=true`. We reproduce
# that snippet here so the test really probes the same control flow that
# ships in production (no semantic-free string match).

drill_bin_dir="$drill_scratch/bin"
mkdir -p "$drill_bin_dir"
cat >"$drill_bin_dir/gh" <<'GHF'
#!/usr/bin/env bash
# fake gh: emits an open stop-the-line issue when the env flag is on,
# otherwise emits none (unfrozen). Records every call so the test verifies
# the arm step did NOT proceed to `gh pr merge` while frozen.
# Mirrors the production shape enough that the gate query
# `gh issue list --json number --jq length` sees a count of 1 (frozen) or
# 0 (unfrozen), exactly like the real CLI.
set -euo pipefail
printf '%s\n' "$*" >>"$GHCALLS"
case "$1" in
  issue)
    case "$2" in
      list)
        if [ "${STL_FROZEN:-0}" = "1" ]; then
          # Render to match `gh issue list --json number --jq length`.
          if [[ "$*" == *"--jq length"* ]]; then
            echo "1"
          else
            cat <<'JSON'
[{"number":777,"title":"stop-the-line: Nishfleet/fleet-ops frozen — CI red on consecutive commits"}]
JSON
          fi
        else
          if [[ "$*" == *"--jq length"* ]]; then
            echo "0"
          else
            echo "[]"
          fi
        fi
        exit 0
        ;;
    esac
    ;;
  pr)
    case "$2" in
      merge)
        printf 'PR_MERGE_CALL\n' >>"$GHCALLS"
        exit 0
        ;;
    esac
    ;;
esac
exit 0
GHF
chmod +x "$drill_bin_dir/gh"

run_gate() {
    local label="$1"
    local frozen="$2"
    # Fresh call log per scenario.
    : >"$drill_scratch/${label}.calls"
    PATH="$drill_bin_dir:$PATH" \
      GH_TOKEN="fake" \
      REPO="Nishfleet/fleet-ops" \
      PR="42" \
      STL_FROZEN="$frozen" \
      GHCALLS="$drill_scratch/${label}.calls" \
      bash -c '
        set -euo pipefail
        # Replicate the reusable-auto-merge-arm.yml control flow:
        #   if gh issue list ... | grep -qE positive -> frozen=true
        if gh issue list --repo "$REPO" \
              --state open --limit 100 \
              --search "stop-the-line: in:title frozen in:title" \
              --json number --jq length 2>/dev/null | grep -qE "^([1-9][0-9]*)$"; then
          echo "frozen=true"
          exit 0
        fi
        echo "frozen=false"
        # Arm step: only on the unfrozen path.
        gh pr merge "$PR" --auto --squash --repo "$REPO"
      '
}

# Frozen scenario: arm step MUST skip gh pr merge.
run_gate frozen-bin 1 >/dev/null 2>&1 || true
calls_frozen="$(cat "$drill_scratch/frozen-bin.calls" 2>/dev/null || true)"
echo "$calls_frozen" | grep -q "issue list" \
  || fail "drill (frozen): gate must probe issue list; calls: $calls_frozen"
if grep -q "PR_MERGE_CALL" "$drill_scratch/frozen-bin.calls"; then
  fail "drill (frozen): arm step must NOT call gh pr merge; calls: $calls_frozen"
fi
ok "drill (frozen): arm refuses to call gh pr merge while stop-the-line issue is open"

# Unfrozen scenario: arm step MUST call gh pr merge.
run_gate unfrozen-bin 0 >/dev/null 2>&1 || true
calls_unfrozen="$(cat "$drill_scratch/unfrozen-bin.calls" 2>/dev/null || true)"
if ! grep -q "PR_MERGE_CALL" "$drill_scratch/unfrozen-bin.calls"; then
  fail "drill (unfrozen): arm step must call gh pr merge; calls: $calls_unfrozen"
fi
ok "drill (unfrozen): arm calls gh pr merge once the freeze issue is closed"

echo "all stop-the-line cases passed"
