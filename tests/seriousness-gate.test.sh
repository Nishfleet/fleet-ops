#!/usr/bin/env bash
# tests/seriousness-gate.test.sh
#
# Proves the build-seriousness classifier (fleet-ops #223) without reaching
# GitHub. The classify function is pure JSON-in / JSON-out; this feeds it
# fixtures for every trigger and the trivial case, and asserts the result.
#
# Covers the issue's stubbed acceptance: "control-plane diff -> auto-labeled"
# plus the other three triggers (diff-size, closes-keystone/gap-audit,
# claim-duration > 15 min) and the no-trigger case.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/seriousness-gate.mjs"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "gate script not found: $script"
node --check "$script" || fail "gate script failed node --check"
node "$script" --help >/dev/null || fail "gate --help failed"

cd "$repo_root"

run() {
  printf '%s' "$1" | node "$script"
}

# 1. control-plane-paths: a bin/ edit is serious even with a tiny diff.
r="$(run '{"changedFiles":["bin/pi-issue-run","README.md"],"additions":2,"deletions":1,"closingIssueLabels":[],"claimDurationMinutes":1}')"
[[ "$(printf '%s' "$r" | jq -r '.serious')" == "true" ]] || fail "bin/ edit must be serious"
printf '%s' "$r" | jq -e '.triggers | index("control-plane-paths") >= 0' >/dev/null || fail "control-plane-paths trigger missing"
ok "control-plane-paths (bin/) -> serious"

# Every control-plane prefix fires.
for p in systemd/pi@.service lib/seat-lib.sh config/seat-caps.json .github/workflows/ci.yml; do
  r="$(run "{\"changedFiles\":[\"$p\"],\"additions\":1,\"deletions\":0,\"closingIssueLabels\":[],\"claimDurationMinutes\":0}")"
  [[ "$(printf '%s' "$r" | jq -r '.serious')" == "true" ]] || fail "$p must be serious"
  printf '%s' "$r" | jq -e '.detail["control-plane-paths"].fired == true' >/dev/null || fail "$p control-plane not fired"
done
ok "all control-plane prefixes (systemd, lib, config, .github/workflows) fire"

# 2. diff-size: > 300 changed lines is serious even with no control-plane file.
r="$(run '{"changedFiles":["docs/readme.md","docs/guide.md"],"additions":250,"deletions":60,"closingIssueLabels":[],"claimDurationMinutes":1}')"
[[ "$(printf '%s' "$r" | jq -r '.serious')" == "true" ]] || fail "301-line diff must be serious"
printf '%s' "$r" | jq -e '.triggers | index("diff-size") >= 0' >/dev/null || fail "diff-size trigger missing"
ok "diff-size > 300 -> serious"

# Boundary: exactly 300 is NOT serious (the rule is > 300).
r="$(run '{"changedFiles":["docs/a.md"],"additions":300,"deletions":0,"closingIssueLabels":[],"claimDurationMinutes":0}')"
[[ "$(printf '%s' "$r" | jq -r '.serious')" == "false" ]] || fail "exactly 300 lines must NOT be serious"
ok "diff-size boundary: exactly 300 is not serious"

# 3. closes-keystone-or-gap-audit.
for lbl in keystone gap-audit KEYSTONE; do
  r="$(run "{\"changedFiles\":[\"docs/a.md\"],\"additions\":1,\"deletions\":0,\"closingIssueLabels\":[\"$lbl\"],\"claimDurationMinutes\":0}")"
  [[ "$(printf '%s' "$r" | jq -r '.serious')" == "true" ]] || fail "closing issue labeled $lbl must be serious"
done
ok "closes-keystone-or-gap-audit (case-insensitive) -> serious"

# 4. claim-duration > 15 min (Nish 2026-08-26: threshold is 15 min, not 1h).
r="$(run '{"changedFiles":["docs/a.md"],"additions":1,"deletions":0,"closingIssueLabels":[],"claimDurationMinutes":16}')"
[[ "$(printf '%s' "$r" | jq -r '.serious')" == "true" ]] || fail "16-min claim must be serious"
printf '%s' "$r" | jq -e '.triggers | index("claim-duration") >= 0' >/dev/null || fail "claim-duration trigger missing"
ok "claim-duration > 15 min -> serious"

# Boundary: exactly 15 min is NOT serious (the rule is > 15).
r="$(run '{"changedFiles":["docs/a.md"],"additions":1,"deletions":0,"closingIssueLabels":[],"claimDurationMinutes":15}')"
[[ "$(printf '%s' "$r" | jq -r '.serious')" == "false" ]] || fail "exactly 15 min must NOT be serious"
ok "claim-duration boundary: exactly 15 min is not serious"

# null claim duration is tolerated (no claim comment found) -> not serious on its own.
r="$(run '{"changedFiles":["docs/a.md"],"additions":1,"deletions":0,"closingIssueLabels":[],"claimDurationMinutes":null}')"
[[ "$(printf '%s' "$r" | jq -r '.serious')" == "false" ]] || fail "null claim duration must not be serious"
ok "null claim duration tolerated"

# 5. Trivial: a small docs-only PR with a fast claim is not serious.
r="$(run '{"changedFiles":["docs/readme.md"],"additions":5,"deletions":2,"closingIssueLabels":[],"claimDurationMinutes":3}')"
[[ "$(printf '%s' "$r" | jq -r '.serious')" == "false" ]] || fail "small docs PR must not be serious"
[[ "$(printf '%s' "$r" | jq -r '.triggers | length')" == "0" ]] || fail "trivial PR must have no triggers"
ok "trivial docs PR -> not serious"

# 6. Multiple triggers fire together.
r="$(run '{"changedFiles":["bin/foo","lib/bar"],"additions":400,"deletions":10,"closingIssueLabels":["keystone"],"claimDurationMinutes":30}')"
[[ "$(printf '%s' "$r" | jq -r '.serious')" == "true" ]] || fail "multi-trigger must be serious"
[[ "$(printf '%s' "$r" | jq -r '.triggers | length')" == "4" ]] || fail "all four triggers must fire: got $(printf '%s' "$r" | jq -c '.triggers')"
ok "all four triggers fire together"

echo "OK: seriousness-gate classifier is correct"