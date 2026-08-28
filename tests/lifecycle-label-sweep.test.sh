#!/usr/bin/env bash
# tests/lifecycle-label-sweep.test.sh
#
# Proves fleet-ops#376: unlabeled open issues get a lifecycle label within
# one existing heartbeat tick. No new scheduler.
#
#   - classify: default agent-ready; AUTO-REVERT SKIP/HALT → noise-class;
#     FLAG-for-Nish → nish-reserved; drill: prefix → drill:lifecycle
#   - sweep labels unlabeled issues and skips ones that already have a
#     lifecycle label (including drill:* and a non-lifecycle-only issue
#     like auto-revert-halt still gets a lifecycle label)
#   - drill: file an unlabeled fixture, run one tick, assert it now
#     carries a lifecycle label, then close it
#   - overlapping flock no-op
#   - contracts: tier1 call + MANIFEST entry
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/lifecycle-label-sweep"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

# --- classify (offline, no gh) --------------------------------------------
got=$("$bin" --classify "fix(seats): Devin rate-limit never benches")
[[ "$got" == "agent-ready" ]] || fail "default classify: $got"
ok "plain title without repo → agent-ready (title-only classify)"

got=$("$bin" --classify "AUTO-REVERT SKIP: only non-required checks failed")
[[ "$got" == "noise-class" ]] || fail "skip classify: $got"
ok "AUTO-REVERT SKIP → noise-class"

got=$("$bin" --classify "AUTO-REVERT HALT: revert commit itself is red on main")
[[ "$got" == "noise-class" ]] || fail "halt classify: $got"
ok "AUTO-REVERT HALT → noise-class"

got=$("$bin" --classify "FLAG-for-Nish: pick the pricing copy")
[[ "$got" == "nish-reserved" ]] || fail "flag classify: $got"
ok "FLAG-for-Nish → nish-reserved"

got=$("$bin" --classify "[flag-for-nish] hold this")
[[ "$got" == "nish-reserved" ]] || fail "flag case classify: $got"
ok "flag-for-nish (any case) → nish-reserved"

got=$("$bin" --classify "drill: unlabeled-lifecycle fixture")
[[ "$got" == "drill:lifecycle" ]] || fail "drill classify: $got"
ok "drill: prefix → drill:lifecycle"

# AUTO-REVERT wins over a nested FLAG (live halt titles never contain FLAG,
# but the prefix check must be first so a halt notice cannot become ready).
got=$("$bin" --classify "AUTO-REVERT SKIP: FLAG-for-Nish leftover")
[[ "$got" == "noise-class" ]] || fail "skip wins over flag: $got"
ok "AUTO-REVERT SKIP prefix wins over FLAG-for-Nish substring"

# --- live sweep with mocked gh --------------------------------------------
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"

cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_DIR/gh.log"
case "$1" in
  issue)
    case "$2" in
      list)
        cat "$FAKE_DIR/list.json"
        exit 0
        ;;
      view)
        num="$3"
        if [[ -f "$FAKE_DIR/view-${num}.json" ]]; then
          cat "$FAKE_DIR/view-${num}.json"
          exit 0
        fi
        if [[ -f "$FAKE_DIR/edits.log" ]] && grep -q -- "--add-label" "$FAKE_DIR/edits.log"; then
          label=$(grep -- '--add-label' "$FAKE_DIR/edits.log" | tail -1 \
            | awk '{for(i=1;i<=NF;i++) if($i=="--add-label"){print $(i+1); exit}}')
          printf '{"labels":[{"name":"%s"}],"title":"drill: unlabeled-lifecycle fixture"}\n' "$label"
          exit 0
        fi
        echo '{"labels":[],"title":"drill: unlabeled-lifecycle fixture"}'
        exit 0
        ;;
      edit)
        printf '%s\n' "$*" >>"$FAKE_DIR/edits.log"
        exit 0
        ;;
      comment)
        printf '%s\n' "$*" >>"$FAKE_DIR/comments.log"
        exit 0
        ;;
      create)
        printf '%s\n' "$*" >>"$FAKE_DIR/creates.log"
        if [[ "$*" == *"--label"* ]]; then
          echo "drill fixture must be filed unlabeled, got --label" >&2
          exit 1
        fi
        printf '[{"number":4242,"title":"drill: unlabeled-lifecycle fixture","labels":[]}]\n' \
          >"$FAKE_DIR/list.json"
        echo "https://github.com/Nishfleet/0509/issues/4242"
        exit 0
        ;;
      close)
        printf '%s\n' "$*" >>"$FAKE_DIR/closes.log"
        exit 0
        ;;
      *) echo "unexpected gh issue $*" >&2; exit 1 ;;
    esac
    ;;
  label)
    printf '%s\n' "$*" >>"$FAKE_DIR/labels.log"
    exit 0
    ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$scratch/bin/gh" "$bin"
export FAKE_DIR="$scratch"
export PATH="$scratch/bin:$PATH"
export LIFECYCLE_SWEEP_LOCKDIR="$scratch/lock"
export LIFECYCLE_SWEEP_REPOS="Nishfleet/0509"
export LIFECYCLE_SWEEP_NOW="2026-08-26T16:00:00Z"
unset LIFECYCLE_SWEEP_DRILL || true

# Case 1: unlabeled generic on a product repo → scout-candidate (fleet-ops#457)
cat >"$scratch/list.json" <<'JSON'
[{"number":381,"title":"fix(seats): Devin rate-limit never benches","labels":[]}]
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"
: >"$scratch/labels.log"

out=$("$bin" 2>"$scratch/err1.txt")
grep -q 'relabeled=1' <<<"$out" || fail "generic relabeled: $out"
grep -q -- '--add-label scout-candidate' "$scratch/edits.log" \
  || fail "generic add-label: $(cat "$scratch/edits.log")"
grep -q 'lifecycle-label: scout-candidate' "$scratch/comments.log" \
  || fail "generic comment: $(cat "$scratch/comments.log")"
ok "unlabeled generic issue on 0509 → scout-candidate (admission, not blank approval)"

# Case 1b: unlabeled fleet-ops WITH a spec → agent-ready (builder gate + spec-gate)
export LIFECYCLE_SWEEP_REPOS="Nishfleet/fleet-ops"
cat >"$scratch/list.json" <<'JSON'
[{"number":457,"title":"feat(quality): inescapable per-role gates","body":"- required: a named gate / CI check / drill\n","labels":[]}]
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"
out=$("$bin" 2>"$scratch/err1b.txt")
grep -q -- '--add-label agent-ready' "$scratch/edits.log" \
  || fail "fleet-ops spec add-label: $(cat "$scratch/edits.log")"
ok "unlabeled fleet-ops issue with a spec → agent-ready (builder gate)"

# Case 1c: unlabeled fleet-ops WITHOUT a spec → refused (fleet-ops#543)
cat >"$scratch/list.json" <<'JSON'
[{"number":543,"title":"feat(quality): stamp ready with no spec","body":"please look at this\n","labels":[]}]
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"
out=$("$bin" 2>"$scratch/err1c.txt")
if grep -q -- '--add-label agent-ready' "$scratch/edits.log"; then
  fail "spec-less fleet-ops must not become agent-ready: $(cat "$scratch/edits.log")"
fi
grep -q 'SPEC-GATE-REFUSED' "$scratch/err1c.txt" \
  || fail "spec-less fleet-ops must log SPEC-GATE-REFUSED: $(cat "$scratch/err1c.txt")"
grep -q 'spec-gate: refused agent-ready' "$scratch/comments.log" \
  || fail "spec-less fleet-ops must comment the refusal: $(cat "$scratch/comments.log")"
ok "unlabeled fleet-ops issue without a spec → refused (spec-gate)"
export LIFECYCLE_SWEEP_REPOS="Nishfleet/0509"

# Case 2: AUTO-REVERT SKIP (live #361 shape) → noise-class, not agent-ready
cat >"$scratch/list.json" <<'JSON'
[{"number":361,"title":"AUTO-REVERT SKIP: only non-required checks failed","labels":[]}]
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err2.txt")
grep -q 'relabeled=1' <<<"$out" || fail "skip relabeled: $out"
grep -q -- '--add-label noise-class' "$scratch/edits.log" \
  || fail "skip add-label: $(cat "$scratch/edits.log")"
if grep -q -- '--add-label agent-ready' "$scratch/edits.log"; then
  fail "SKIP must not become agent-ready: $(cat "$scratch/edits.log")"
fi
ok "AUTO-REVERT SKIP → noise-class (not agent-ready)"

# Case 3: FLAG-for-Nish → nish-reserved
cat >"$scratch/list.json" <<'JSON'
[{"number":99,"title":"FLAG-for-Nish: pick the pricing copy","labels":[]}]
JSON
: >"$scratch/edits.log"

out=$("$bin" 2>"$scratch/err3.txt")
grep -q -- '--add-label nish-reserved' "$scratch/edits.log" \
  || fail "flag add-label: $(cat "$scratch/edits.log")"
ok "FLAG-for-Nish → nish-reserved"

# Case 4: already agent-ready → skip
cat >"$scratch/list.json" <<'JSON'
[{"number":10,"title":"already queued","labels":[{"name":"agent-ready"}]}]
JSON
: >"$scratch/edits.log"

out=$("$bin" 2>"$scratch/err4.txt")
grep -q 'relabeled=0' <<<"$out" || fail "ready skip relabeled: $out"
[[ -s "$scratch/edits.log" ]] && fail "ready must not edit: $(cat "$scratch/edits.log")"
ok "already agent-ready is left alone"

# Case 5: auto-revert-halt only (not a lifecycle label) still gets one
cat >"$scratch/list.json" <<'JSON'
[{"number":354,"title":"AUTO-REVERT SKIP: only non-required checks failed","labels":[{"name":"auto-revert-halt"}]}]
JSON
: >"$scratch/edits.log"

out=$("$bin" 2>"$scratch/err5.txt")
grep -q 'relabeled=1' <<<"$out" || fail "halt-only relabeled: $out"
grep -q -- '--add-label noise-class' "$scratch/edits.log" \
  || fail "halt-only add-label: $(cat "$scratch/edits.log")"
ok "auto-revert-halt alone is not a lifecycle label; SKIP still gets noise-class"

# Case 5b: gap-audit only (live #367–#371 shape) → agent-ready (fleet-ops#402).
# gap-audit is a topic label, not a lifecycle label. Without this, findings
# sit on the gap-board and intake never claims them.
cat >"$scratch/list.json" <<'JSON'
[{"number":368,"title":"[gap-audit] fleet-heartbeat-failed-notify.service Telegram page names the wrong host","labels":[{"name":"gap-audit"}]}]
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err5b.txt")
grep -q 'relabeled=1' <<<"$out" || fail "gap-audit-only relabeled: $out"
grep -q -- '--add-label agent-ready' "$scratch/edits.log" \
  || fail "gap-audit-only add-label: $(cat "$scratch/edits.log")"
ok "gap-audit only → agent-ready (fleet-ops#402 leftovers)"

# Case 6: drill:* already present → skip
cat >"$scratch/list.json" <<'JSON'
[{"number":7,"title":"drill leftover","labels":[{"name":"drill:oomd"}]}]
JSON
: >"$scratch/edits.log"

out=$("$bin" 2>"$scratch/err6.txt")
grep -q 'relabeled=0' <<<"$out" || fail "drill:* skip: $out"
[[ -s "$scratch/edits.log" ]] && fail "drill:* must not edit: $(cat "$scratch/edits.log")"
ok "existing drill:* label counts as lifecycle; skipped"

# Case 7: mixed unlabeled + labeled in one list
cat >"$scratch/list.json" <<'JSON'
[
  {"number":1,"title":"ready already","labels":[{"name":"agent-in-progress"}]},
  {"number":2,"title":"fix the unlabeled one","labels":[]},
  {"number":3,"title":"blocked already","labels":[{"name":"agent-blocked"}]}
]
JSON
: >"$scratch/edits.log"

out=$("$bin" 2>"$scratch/err7.txt")
grep -q 'relabeled=1' <<<"$out" || fail "mixed relabeled: $out"
grep -q 'skipped=2' <<<"$out" || fail "mixed skipped: $out"
grep -q 'edit 2 ' "$scratch/edits.log" || fail "mixed should edit #2: $(cat "$scratch/edits.log")"
if grep -qE 'edit (1|3) ' "$scratch/edits.log"; then
  fail "mixed must not edit labeled issues: $(cat "$scratch/edits.log")"
fi
ok "only the unlabeled row in a mixed list is relabeled"

# Case 8: overlapping flock no-op
export LIFECYCLE_SWEEP_LOCKDIR="$scratch/lock-overlap"
mkdir -p "$LIFECYCLE_SWEEP_LOCKDIR"
exec 9>"$LIFECYCLE_SWEEP_LOCKDIR/sweep.lock"
flock -n 9 || fail "could not hold overlap lock"
out=$("$bin" 2>"$scratch/err8.txt")
exec 9>&-
printf '%s\n' "$out" | grep -q 'no-op' || fail "overlap must print no-op, got: $out"
ok "overlapping sweep is a no-op"
export LIFECYCLE_SWEEP_LOCKDIR="$scratch/lock"

# Case 9: drill files unlabeled fixture, tick labels it, then closes it
: >"$scratch/edits.log"
: >"$scratch/creates.log"
: >"$scratch/closes.log"
: >"$scratch/list.json"

out=$("$bin" --drill 2>"$scratch/err9.txt") || fail "drill must exit 0: $out / $(cat "$scratch/err9.txt")"
grep -q 'drill ok' <<<"$out" || fail "drill stdout: $out"
grep -q 'issue create' "$scratch/creates.log" || fail "drill must file an issue: $(cat "$scratch/creates.log")"
if grep -q -- '--label' "$scratch/creates.log"; then
  fail "drill fixture must be unlabeled at create: $(cat "$scratch/creates.log")"
fi
grep -q -- '--add-label drill:lifecycle' "$scratch/edits.log" \
  || fail "drill must label the fixture: $(cat "$scratch/edits.log")"
grep -q 'issue close 4242' "$scratch/closes.log" \
  || fail "drill must close the fixture: $(cat "$scratch/closes.log")"
ok "drill: unlabeled fixture is labeled after one tick, then closed"

# Case 10: contracts
grep -q 'lifecycle-label-sweep' "$repo_root/bin/fleet-heartbeat-tier1" \
  || fail "tier1 must call lifecycle-label-sweep"
grep -q 'bin/lifecycle-label-sweep' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/lifecycle-label-sweep"
ok "contracts: tier1 call + MANIFEST entry present"

echo "all lifecycle-label-sweep cases passed"
