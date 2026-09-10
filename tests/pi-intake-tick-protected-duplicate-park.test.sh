#!/usr/bin/env bash
# tests/pi-intake-tick-protected-duplicate-park.test.sh
#
# fleet-ops#5082: the protected duplicate-of-merged-work reclaim spin. A
# PROTECTED (owner-authored or critical-path) OPEN issue past
# PARK_MAX_CLAIMS whose own claim/issue-$N branch never merged a delivery
# PR can still have its `do:` already delivered — by ANOTHER issue's merged
# claim PR. Live case: 0509#2369 was re-claimed 3x in ~4h after claim/
# issue-2363's merged PR #2641 landed the identical files: work (its own
# PR #2643 closed unmerged on a content conflict, and #2641's body never
# named #2369 — so a `#N`-mention-only probe cannot catch the observed
# shape). The #4540 head-branch probe only sees delivery on the issue's OWN
# claim branch, so the same slow-spaced spin continued past every anti-loop
# gate. This test pins the new protected-duplicate park contract:
#
#   1. PARK_DUP_LOOKBACK env var is defined and overridable.
#   2. park_duplicate_delivery() exists as an extractable function and is
#      called from the park block with repo + issue number + body.
#   3. The branch fires only for _park_protected == 1, inside the
#      _park_claims > PARK_MAX_CLAIMS block, and only when the issue's own
#      claim-branch merged probe is empty.
#   4. On trip: awaiting-runtime-gate label added, agent-ready removed, a
#      fleet-ops#5082 comment posted, and the issue skipped (continue).
#   5. Functional probe cases via a stubbed gh (park vs no-park).
#   6. The existing #4540 / #4553 branches are untouched (their own tests
#      pin them).
#   7. shellcheck clean.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# === Test 1: PARK_DUP_LOOKBACK env var defined (overridable) ===
grep -qF 'PARK_DUP_LOOKBACK="${PI_INTAKE_PARK_DUP_LOOKBACK:-30}"' "$tick" \
    || fail "PARK_DUP_LOOKBACK env var not found (must be overridable for tests)"
ok "Test 1: PARK_DUP_LOOKBACK env var defined (default 30, overridable)"

# === Test 2: probe is an extractable function, called with repo+N+body ===
grep -qF 'park_duplicate_delivery() {' "$tick" \
    || fail "park_duplicate_delivery() function not found (tests extract it like blocked_filter)"
grep -qF '_park_dup=$(park_duplicate_delivery "$FULL" "$N" "$body")' "$tick" \
    || fail "park block must call park_duplicate_delivery \"\$FULL\" \"\$N\" \"\$body\""
ok "Test 2: park_duplicate_delivery() defined and called with repo + issue + body"

# === Test 3: branch guards — protected, past cap, own-branch merged empty ===
claims_line=$(grep -n 'if (( _park_claims > PARK_MAX_CLAIMS )); then' "$tick" | head -1 | cut -d: -f1)
prot_init=$(grep -n '_park_protected=0' "$tick" | head -1 | cut -d: -f1)
dup_guard=$(grep -n '^        if (( _park_protected == 1 )); then$' "$tick" | tail -1 | cut -d: -f1)
dup_marker=$(grep -n 'skipped-parked-protected-duplicate' "$tick" | head -1 | cut -d: -f1)
[[ -n "$claims_line" && -n "$prot_init" && -n "$dup_guard" && -n "$dup_marker" ]] \
    || fail "park block lines not found (claims cap / protection init / duplicate guard / marker)"
(( dup_guard > prot_init && prot_init > claims_line )) \
    || fail "duplicate branch must sit inside the claims-cap block after _park_protected is determined"
# own-branch merged probe must be empty before the duplicate probe runs
sed -n "${dup_guard},${dup_marker}p" "$tick" | grep -qF 'jq -e '\''length > 0'\''' \
    || fail "duplicate branch must first prove the claim/issue-\$N merged probe is empty"
sed -n "${dup_guard},${dup_marker}p" "$tick" | grep -qF -- '--head "claim/issue-$N" --state merged' \
    || fail "duplicate branch must reuse/run the merged claim/issue-\$N head-branch probe"
ok "Test 3: branch requires protected + past PARK_MAX_CLAIMS + empty own-branch merged probe"

# === Test 4: on trip — label flip + #5082 comment + continue ===
sed -n "${dup_guard},/^        fi$/p" "$tick" | grep -qF -- '--add-label awaiting-runtime-gate --remove-label agent-ready' \
    || fail "duplicate park must flip awaiting-runtime-gate on / agent-ready off"
sed -n "${dup_guard},/^        fi$/p" "$tick" | grep -qF 'fleet-ops#5082' \
    || fail "duplicate park comment must reference fleet-ops#5082"
sed -n "${dup_guard},/^        fi$/p" "$tick" | grep -q 'continue' \
    || fail "duplicate park must skip the claim (continue)"
sed -n "${dup_guard},/^        fi$/p" "$tick" | grep -qF 'label create awaiting-runtime-gate' \
    || fail "duplicate park must provision the label first (gh issue edit --add-label cannot auto-create it)"
ok "Test 4: trip flips labels, posts the fleet-ops#5082 comment, and skips"

# === Test 5: bounded deterministic probe shape ===
grep -qF -- 'gh pr list -R "$full" --state merged' "$tick" \
    || fail "merged-PR scan must list merged PRs for the repo"
grep -qF -- '--json number,title,body,headRefName,files' "$tick" \
    || fail "merged-PR scan must fetch number,title,body,headRefName,files"
grep -qF -- '--limit "${PARK_DUP_LOOKBACK:-30}"' "$tick" \
    || fail "merged-PR scan must be bounded by PARK_DUP_LOOKBACK"
grep -qF 'test("^claim/issue-[0-9]+$")' "$tick" \
    || fail "probe must recognise a different claim/issue-<M> head as 'another issue'"
grep -qF 'test("#" + $n + "\\b")' "$tick" \
    || fail "probe must recognise a #N title/body reference (word-bounded)"
grep -qF 'sed -n '\''s/^files:[[:space:]]*//p'\''' "$tick" \
    || fail "probe must read the issue's files: line"
ok "Test 5: probe is bounded (lookback) and deterministic (files: overlap + claim head or #N ref)"

# === Test 6: functional probe via stubbed gh ===
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"

cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_DIR/gh.log"
case "$*" in
  "pr list -R "*" --state merged --json number,title,body,headRefName,files --limit "*)
    cat "$FAKE_DIR/prs.json"; exit 0 ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$scratch/bin/gh"
export FAKE_DIR="$scratch"
export PATH="$scratch/bin:$PATH"

# Extract the function under test (the tick runs top-level; same pattern as
# blocked_filter in pi-intake-tick-blocked-filter-stale.test.sh).
awk '/^park_duplicate_delivery\(\)/,/^}/' "$tick" >"$scratch/dup.sh"
grep -qF 'park_duplicate_delivery()' "$scratch/dup.sh" || fail "function extraction failed"
# shellcheck disable=SC1090
source "$scratch/dup.sh"

prs() { cat >"$FAKE_DIR/prs.json"; }
issue_body='do: delete the throw error for the isRetryableMonitoringFailure branch
files: app/lib/monitoring.server.ts
termination: npm test'

# 6a. claim/issue-<M> head + files: overlap -> duplicate found (the live
#     #2369 shape: #2641 head claim/issue-2363, body never named #2369)
prs <<'JSON'
[{"number":2641,"title":"fix(monitoring): return retry_scheduled","body":"Fixes #2363.","headRefName":"claim/issue-2363","files":[{"path":"app/lib/monitoring.server.ts"},{"path":"tests/monitoring-scheduled-runtime.test.ts"}]}]
JSON
dup=$(park_duplicate_delivery "Nishfleet/0509" "2369" "$issue_body")
[[ "$dup" == "2641" ]] || fail "claim/issue-2363 + files: overlap must detect PR #2641 (got '$dup')"
ok "Test 6a: another issue's merged claim PR + files: overlap -> duplicate"

# 6b. non-claim head + #N body reference + overlap -> duplicate found
prs <<'JSON'
[{"number":77,"title":"manual fix","body":"same change as #2369","headRefName":"fix/manual-monitoring","files":[{"path":"app/lib/monitoring.server.ts"}]}]
JSON
dup=$(park_duplicate_delivery "Nishfleet/0509" "2369" "$issue_body")
[[ "$dup" == "77" ]] || fail "#2369-referencing merged PR with files: overlap must detect PR #77 (got '$dup')"
ok "Test 6b: #N-referencing merged PR + files: overlap -> duplicate"

# 6c. #N mention but NO files: overlap -> no park (bare prose mention,
#     fleet-ops#3231)
prs <<'JSON'
[{"number":88,"title":"docs: mention #2369","body":"see #2369","headRefName":"claim/issue-2000","files":[{"path":"docs/notes.md"}]}]
JSON
dup=$(park_duplicate_delivery "Nishfleet/0509" "2369" "$issue_body")
[[ -z "$dup" ]] || fail "prose mention without files: overlap must NOT park (got '$dup')"
ok "Test 6c: #N mention without files: overlap -> no park (bare prose mention rejected)"

# 6d. claim/issue-<M> head but NO files: overlap -> no park
prs <<'JSON'
[{"number":99,"title":"fix(other): unrelated","body":"Fixes #2001","headRefName":"claim/issue-2001","files":[{"path":"app/lib/other.server.ts"}]}]
JSON
dup=$(park_duplicate_delivery "Nishfleet/0509" "2369" "$issue_body")
[[ -z "$dup" ]] || fail "another claim PR with no files: overlap must NOT park (got '$dup')"
ok "Test 6d: claim/issue-<M> without files: overlap -> no park"

# 6e. the issue's OWN claim/issue-$N head is never 'another issue'
prs <<'JSON'
[{"number":55,"title":"self","body":"","headRefName":"claim/issue-2369","files":[{"path":"app/lib/monitoring.server.ts"}]}]
JSON
dup=$(park_duplicate_delivery "Nishfleet/0509" "2369" "$issue_body")
[[ -z "$dup" ]] || fail "own claim/issue-2369 head must not count as 'another issue' (got '$dup')"
ok "Test 6e: own claim/issue-\$N head -> no park"

# 6f. no files: line -> no park, and gh is never probed
: >"$FAKE_DIR/gh.log"
dup=$(park_duplicate_delivery "Nishfleet/0509" "2369" "do: something
accept: it works")
[[ -z "$dup" ]] || fail "missing files: line must not park (got '$dup')"
[[ ! -s "$FAKE_DIR/gh.log" ]] || fail "missing files: line must skip the gh pr list probe entirely"
ok "Test 6f: no files: line -> no park, zero network"

# 6g. word-boundary on #N: a #23699 mention is NOT a #2369 reference
prs <<'JSON'
[{"number":66,"title":"fix(x): refs #23699","body":"","headRefName":"fix/other","files":[{"path":"app/lib/monitoring.server.ts"}]}]
JSON
dup=$(park_duplicate_delivery "Nishfleet/0509" "2369" "$issue_body")
[[ -z "$dup" ]] || fail "#23699 must not satisfy a #2369 reference (got '$dup')"
ok "Test 6g: #23699 does not count as a #2369 reference"

# 6h. multi-path files: line — one exact path overlap is enough
prs <<'JSON'
[{"number":44,"title":"fix(m): x","body":"","headRefName":"claim/issue-2363","files":[{"path":"workers/monitoring-workflow.ts"}]}]
JSON
dup=$(park_duplicate_delivery "Nishfleet/0509" "2369" "do: x
files: app/lib/monitoring.server.ts, workers/monitoring-workflow.ts")
[[ "$dup" == "44" ]] || fail "one matching path in a multi-path files: line must detect (got '$dup')"
ok "Test 6h: multi-path files: line, single overlap -> duplicate"

# 6i. a files: path that is not an exact match (different file) -> no park
prs <<'JSON'
[{"number":33,"title":"fix(m): x","body":"","headRefName":"claim/issue-2363","files":[{"path":"app/lib/monitoring-fanout.server.ts"}]}]
JSON
dup=$(park_duplicate_delivery "Nishfleet/0509" "2369" "$issue_body")
[[ -z "$dup" ]] || fail "near-miss path (monitoring-fanout vs monitoring) must not park (got '$dup')"
ok "Test 6i: exact-path match only (near-miss file -> no park)"

# 6j. gh probe failure -> empty output, still returns 0 (never aborts tick)
cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "boom" >&2; exit 1
FAKE
chmod +x "$scratch/bin/gh"
dup=$(park_duplicate_delivery "Nishfleet/0509" "2369" "$issue_body")
[[ -z "$dup" ]] || fail "gh failure must yield no duplicate (got '$dup')"
ok "Test 6j: gh probe failure -> no park, no abort"

# === Test 7: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$tick" --severity=warning
    ok "Test 7: shellcheck clean"
else
    echo "SKIP: Test 7: shellcheck not installed"
fi

echo "ALL OK: protected duplicate-of-merged-work park detector (fleet-ops#5082)"
