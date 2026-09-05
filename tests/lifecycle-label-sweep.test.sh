#!/usr/bin/env bash
# tests/lifecycle-label-sweep.test.sh
#
# Proves fleet-ops#376: unlabeled open issues get a lifecycle label within
# one existing heartbeat tick. No new scheduler.
#
#   - classify: default agent-ready; AUTO-REVERT SKIP/HALT → noise-class;
#     FLAG-for-Nish → nish-reserved; drill: prefix → drill:lifecycle;
#     fix(failed-command) observe-to-close → observe-to-close
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

# fleet-ops#1401: exact failed-command title template → observe-to-close.
got=$("$bin" --classify "fix(failed-command): 01a03e61 — failed command walked past, never flagged")
[[ "$got" == "observe-to-close" ]] || fail "failed-command offline classify: $got"
ok "fix(failed-command) title → observe-to-close"

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
  pr)
    case "$2" in
      list)
        # fleet-ops#1083: class_lock_pr_merged probes
        # `gh pr list --head claim/issue-<N> --state merged`. The fake
        # returns a fixture file per issue number if present, else [].
        head=""
        prev=""
        for a in "$@"; do
          case "$prev" in
            --head) head="$a"; break ;;
          esac
          prev="$a"
        done
        num="${head#claim/issue-}"
        if [[ -f "$FAKE_DIR/merged-${num}.json" ]]; then
          cat "$FAKE_DIR/merged-${num}.json"
        else
          echo '[]'
        fi
        exit 0
        ;;
      *) echo "unexpected gh pr $*" >&2; exit 1 ;;
    esac
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
# fleet-ops#3270: lifecycle-label-sweep moved from heartbeat tier1 §6b to
# lifecycle-label-sweep.service (webhook-triggered). The contract now
# checks the .service unit, not tier1.
grep -q 'lifecycle-label-sweep' "$repo_root/systemd/lifecycle-label-sweep.service" \
  || fail "lifecycle-label-sweep.service must call lifecycle-label-sweep"
grep -q 'bin/lifecycle-label-sweep' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/lifecycle-label-sweep"
ok "contracts: .service unit call + MANIFEST entry present"

# Case 11: failed-command observe-to-close on fleet-ops → observe-to-close,
# not agent-ready (fleet-ops#1401). The body must carry the signal marker.
export LIFECYCLE_SWEEP_REPOS="Nishfleet/fleet-ops"
cat >"$scratch/list.json" <<'JSON'
[{"number":1401,"title":"fix(failed-command): 01a03e61 — failed command walked past, never flagged","body":"The session-close lint found a swallowed failure.\n\nsignal: failed-command-flagged/01a03e61","labels":[]}]
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err11.txt")
grep -q 'relabeled=1' <<<"$out" || fail "failed-command observe-to-close relabeled: $out"
grep -q -- '--add-label observe-to-close' "$scratch/edits.log" \
  || fail "failed-command add-label: $(cat "$scratch/edits.log")"
if grep -q -- '--add-label agent-ready' "$scratch/edits.log"; then
  fail "failed-command must not become agent-ready: $(cat "$scratch/edits.log")"
fi
grep -q 'lifecycle-label: observe-to-close' "$scratch/comments.log" \
  || fail "failed-command comment: $(cat "$scratch/comments.log")"
ok "failed-command observe-to-close issue → observe-to-close (not agent-ready)"

# Case 11b: existing observe-to-close label is left alone (is_lifecycle).
cat >"$scratch/list.json" <<'JSON'
[{"number":1402,"title":"fix(failed-command): 01a03e62 — failed command walked past, never flagged","body":"signal: failed-command-flagged/01a03e62","labels":[{"name":"observe-to-close"}]}]
JSON
: >"$scratch/edits.log"
out=$("$bin" 2>"$scratch/err11b.txt")
grep -q 'relabeled=0' <<<"$out" || fail "existing observe-to-close relabeled: $out"
[[ -s "$scratch/edits.log" ]] && fail "observe-to-close must not edit: $(cat "$scratch/edits.log")"
ok "existing observe-to-close is left alone"

# Case 11c: cross-check that a normal fleet-ops unlabeled issue with a body
# but no failed-command signal still classifies as agent-ready.
cat >"$scratch/list.json" <<'JSON'
[{"number":1403,"title":"feat(quality): inescapable per-role gates","body":"- required: a named gate / CI check / drill\n","labels":[]}]
JSON
: >"$scratch/edits.log"
out=$("$bin" 2>"$scratch/err11c.txt")
grep -q -- '--add-label agent-ready' "$scratch/edits.log" \
  || fail "normal fleet-ops issue must still become agent-ready: $(cat "$scratch/edits.log")"
ok "normal fleet-ops unlabeled issue still → agent-ready"

# Case 12: decisions-ledger observe-to-close classify (fleet-ops#1083).
got=$("$bin" --classify "fix(decisions-ledger): 01a03e61 — decided question was re-asked")
[[ "$got" == "observe-to-close" ]] || fail "decisions-ledger offline classify: $got"
ok "fix(decisions-ledger) title → observe-to-close"

# Case 13: a fix(failed-command) issue labelled agent-ready whose class-lock
# PR has merged is reclassified to observe-to-close (fleet-ops#1083). This
# is the live #958 loop: PR #1066 merged with `Relates to #958`, the release
# path flipped it back to agent-ready, intake re-claimed it every tick.
export LIFECYCLE_SWEEP_REPOS="Nishfleet/fleet-ops"
cat >"$scratch/list.json" <<'JSON'
[{"number":958,"title":"fix(failed-command): 01a03e61 — failed command walked past, never flagged","body":"signal: failed-command-flagged/01a03e61","labels":[{"name":"agent-ready"}]}]
JSON
printf '[{"number":1066}]' >"$scratch/merged-958.json"
: >"$scratch/edits.log"
: >"$scratch/comments.log"
out=$("$bin" 2>"$scratch/err13.txt")
grep -q 'reclassified=1' <<<"$out" || fail "class-lock reclassified: $out"
grep -q -- '--remove-label agent-ready' "$scratch/edits.log" \
  || fail "class-lock must drop agent-ready: $(cat "$scratch/edits.log")"
grep -q -- '--add-label observe-to-close' "$scratch/edits.log" \
  || fail "class-lock must add observe-to-close: $(cat "$scratch/edits.log")"
grep -q 'class-lock PR merged' "$scratch/comments.log" \
  || fail "class-lock comment: $(cat "$scratch/comments.log")"
ok "agent-ready class-lock issue with merged PR → observe-to-close (fleet-ops#1083)"

# Case 13b: same issue but the class-lock PR has NOT merged → left alone.
cat >"$scratch/list.json" <<'JSON'
[{"number":959,"title":"fix(failed-command): 01a03e62 — failed command walked past, never flagged","body":"signal: failed-command-flagged/01a03e62","labels":[{"name":"agent-ready"}]}]
JSON
rm -f "$scratch/merged-959.json"
: >"$scratch/edits.log"
out=$("$bin" 2>"$scratch/err13b.txt")
grep -q 'reclassified=0' <<<"$out" || fail "no-merge reclassified: $out"
[[ -s "$scratch/edits.log" ]] && fail "no-merge must not edit: $(cat "$scratch/edits.log")"
ok "agent-ready class-lock issue with NO merged PR → left alone"

# Case 13c: a fix(decisions-ledger) issue labelled agent-in-progress whose
# class-lock PR merged → observe-to-close (fleet-ops#1083 / #1138).
cat >"$scratch/list.json" <<'JSON'
[{"number":1138,"title":"fix(decisions-ledger): 01a03e63 — decided question was re-asked","body":"signal: decisions-ledger/01a03e63","labels":[{"name":"agent-in-progress"}]}]
JSON
printf '[{"number":2000}]' >"$scratch/merged-1138.json"
: >"$scratch/edits.log"
out=$("$bin" 2>"$scratch/err13c.txt")
grep -q 'reclassified=1' <<<"$out" || fail "decisions-ledger reclassified: $out"
grep -q -- '--remove-label agent-in-progress' "$scratch/edits.log" \
  || fail "decisions-ledger must drop agent-in-progress: $(cat "$scratch/edits.log")"
grep -q -- '--add-label observe-to-close' "$scratch/edits.log" \
  || fail "decisions-ledger must add observe-to-close: $(cat "$scratch/edits.log")"
ok "agent-in-progress decisions-ledger issue with merged PR → observe-to-close"

# Case 13d: a non-class-lock issue labelled agent-ready is never probed for
# a merged PR (the reclassification pass only runs on class-lock titles).
cat >"$scratch/list.json" <<'JSON'
[{"number":500,"title":"feat(quality): inescapable per-role gates","body":"- required: a named gate / CI check / drill\n","labels":[{"name":"agent-ready"}]}]
JSON
rm -f "$scratch/merged-500.json"
: >"$scratch/edits.log"
: >"$scratch/gh.log"
out=$("$bin" 2>"$scratch/err13d.txt")
grep -q 'reclassified=0' <<<"$out" || fail "non-class-lock reclassified: $out"
if grep -q 'pr list' "$scratch/gh.log"; then
  fail "non-class-lock must not probe pr list: $(grep 'pr list' "$scratch/gh.log")"
fi
ok "non-class-lock agent-ready issue is not probed for a merged PR"

# Case 13e: a class-lock issue already under observe-to-close with a merged
# PR is left alone (idempotent — observe-to-close is not in the reclassify
# candidate set).
cat >"$scratch/list.json" <<'JSON'
[{"number":960,"title":"fix(failed-command): 01a03e64 — failed command walked past, never flagged","body":"signal: failed-command-flagged/01a03e64","labels":[{"name":"observe-to-close"}]}]
JSON
printf '[{"number":1067}]' >"$scratch/merged-960.json"
: >"$scratch/edits.log"
out=$("$bin" 2>"$scratch/err13e.txt")
grep -q 'reclassified=0' <<<"$out" || fail "observe-to-close reclassified: $out"
[[ -s "$scratch/edits.log" ]] && fail "observe-to-close must not edit: $(cat "$scratch/edits.log")"
ok "class-lock issue already under observe-to-close is left alone (idempotent)"
export LIFECYCLE_SWEEP_REPOS="Nishfleet/0509"

# Case 14: discarded alone is a lifecycle label — sweep must NOT re-add
# scout-candidate (fleet-ops#2766). Live #1140 loop: discard drops
# scout-candidate, sweep treated the issue as unlabeled, re-added
# scout-candidate, panel re-discarded — 4 cycles in 90 min.
cat >"$scratch/list.json" <<'JSON'
[{"number":1140,"title":"feat(gate): require implementer and attestor to be different identities","labels":[{"name":"discarded"}]}]
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"
out=$("$bin" 2>"$scratch/err14.txt")
grep -q 'relabeled=0' <<<"$out" || fail "discarded-alone relabeled: $out"
[[ -s "$scratch/edits.log" ]] && fail "discarded-alone must not edit: $(cat "$scratch/edits.log")"
ok "discarded alone is a lifecycle label — sweep leaves it alone (fleet-ops#2766)"

# Case 14b: discarded+scout-candidate dual-label leftover is healed by
# dropping scout-candidate (fleet-ops#2766). Pre-fix leftovers still
# carry both labels; the heal pass makes discarded alone the terminal
# state so the auditor stops listing them.
cat >"$scratch/list.json" <<'JSON'
[{"number":1558,"title":"Remove or document dormant Slack/WhatsApp delivery channels","labels":[{"name":"scout-candidate"},{"name":"discarded"}]}]
JSON
: >"$scratch/edits.log"
out=$("$bin" 2>"$scratch/err14b.txt")
grep -q 'healed=1' <<<"$out" || fail "dual-label heal: $out"
grep -q -- '--remove-label scout-candidate' "$scratch/edits.log" \
  || fail "dual-label must drop scout-candidate: $(cat "$scratch/edits.log")"
if grep -q -- '--add-label' "$scratch/edits.log"; then
  fail "dual-label must not add any label: $(cat "$scratch/edits.log")"
fi
ok "discarded+scout-candidate dual-label → drop scout-candidate (fleet-ops#2766)"

# Case 14c: an unlabeled product issue still becomes scout-candidate
# (admission path unchanged by the discarded lifecycle addition).
cat >"$scratch/list.json" <<'JSON'
[{"number":9999,"title":"fix(search): empty state lacks cross-link","labels":[]}]
JSON
: >"$scratch/edits.log"
out=$("$bin" 2>"$scratch/err14c.txt")
grep -q 'relabeled=1' <<<"$out" || fail "unlabeled product still relabeled: $out"
grep -q -- '--add-label scout-candidate' "$scratch/edits.log" \
  || fail "unlabeled product must still get scout-candidate: $(cat "$scratch/edits.log")"
ok "unlabeled product issue still → scout-candidate after discarded lifecycle addition"

# Case 15: umbrella-labeled unlabeled issue → nish-reserved, NOT agent-ready
# (fleet-ops#3295). Umbrella = "tracking parent; not claimable". Without
# this guard the sweep defaults every unlabeled open issue to agent-ready
# (fleet-ops) / scout-candidate (product), intake dispatches a worker on
# the tracker, the worker finds no implementable work, and dies — a pure
# dead-seat loop (live #3128: 6 claims in one day).
export LIFECYCLE_SWEEP_REPOS="Nishfleet/fleet-ops"
cat >"$scratch/list.json" <<'JSON'
[{"number":3128,"title":"umbrella: seat health observability gaps","labels":[{"name":"umbrella"}]}]
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"
out=$("$bin" 2>"$scratch/err15.txt")
grep -q 'relabeled=1' <<<"$out" || fail "umbrella relabeled: $out"
grep -q -- '--add-label nish-reserved' "$scratch/edits.log" \
  || fail "umbrella must get nish-reserved: $(cat "$scratch/edits.log")"
if grep -q -- '--add-label agent-ready' "$scratch/edits.log"; then
  fail "umbrella must NOT get agent-ready: $(cat "$scratch/edits.log")"
fi
ok "umbrella-labeled unlabeled issue → nish-reserved (not agent-ready) (fleet-ops#3295)"

# Case 15b: umbrella on a product repo → nish-reserved, NOT scout-candidate.
# Umbrella means "not claimable" regardless of repo.
export LIFECYCLE_SWEEP_REPOS="Nishfleet/0509"
cat >"$scratch/list.json" <<'JSON'
[{"number":3120,"title":"umbrella: product tracking parent","labels":[{"name":"umbrella"}]}]
JSON
: >"$scratch/edits.log"
out=$("$bin" 2>"$scratch/err15b.txt")
grep -q 'relabeled=1' <<<"$out" || fail "umbrella product relabeled: $out"
grep -q -- '--add-label nish-reserved' "$scratch/edits.log" \
  || fail "umbrella product must get nish-reserved: $(cat "$scratch/edits.log")"
if grep -q -- '--add-label scout-candidate' "$scratch/edits.log"; then
  fail "umbrella product must NOT get scout-candidate: $(cat "$scratch/edits.log")"
fi
ok "umbrella-labeled unlabeled product issue → nish-reserved (not scout-candidate) (fleet-ops#3295)"

# Case 15c: umbrella + gap-audit → nish-reserved (umbrella wins; "not
# claimable" regardless of any other topic label).
export LIFECYCLE_SWEEP_REPOS="Nishfleet/fleet-ops"
cat >"$scratch/list.json" <<'JSON'
[{"number":3125,"title":"umbrella: gap-audit tracking parent","labels":[{"name":"umbrella"},{"name":"gap-audit"}]}]
JSON
: >"$scratch/edits.log"
out=$("$bin" 2>"$scratch/err15c.txt")
grep -q -- '--add-label nish-reserved' "$scratch/edits.log" \
  || fail "umbrella+gap-audit must get nish-reserved: $(cat "$scratch/edits.log")"
if grep -q -- '--add-label agent-ready' "$scratch/edits.log"; then
  fail "umbrella+gap-audit must NOT get agent-ready: $(cat "$scratch/edits.log")"
fi
ok "umbrella + gap-audit → nish-reserved (umbrella wins over gap-audit) (fleet-ops#3295)"

# Case 15d: a non-umbrella unlabeled fleet-ops issue still → agent-ready
# (the guard does not break the default path).
cat >"$scratch/list.json" <<'JSON'
[{"number":3300,"title":"feat(quality): inescapable per-role gates","body":"- required: a named gate / CI check / drill\n","labels":[]}]
JSON
: >"$scratch/edits.log"
out=$("$bin" 2>"$scratch/err15d.txt")
grep -q -- '--add-label agent-ready' "$scratch/edits.log" \
  || fail "non-umbrella fleet-ops issue must still get agent-ready: $(cat "$scratch/edits.log")"
ok "non-umbrella unlabeled fleet-ops issue still → agent-ready (guard does not break default)"
export LIFECYCLE_SWEEP_REPOS="Nishfleet/0509"

echo "all lifecycle-label-sweep cases passed"
