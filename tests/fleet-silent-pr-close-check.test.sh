#!/usr/bin/env bash
# tests/fleet-silent-pr-close-check.test.sh — fleet-ops#6292
#
# Regression drill for the issue's acceptance: replay the #6258 timeline
# shape — closed event by the App identity, no closing comment, head branch
# deleted, owning issue open — and assert the detector flags it. Hermetic:
# a stub gh serves canned pulls/timeline/issue JSON; no live calls.
#
# Drills:
#   1. --help exits 0.
#   2. #6258 REPLAY: closed-not-merged by nishfleet-worker[bot], only a
#      comment >300s before the close, branch gone, issue open -> flag +
#      exit 1; --apply posts one deduped trace (second run re-flags but does
#      NOT re-comment).
#   3. Commented close (same actor, at the close) -> clean exit 0.
#   4. Merged PR -> clean exit 0 (land path, never the class).
#   5. Close by a human identity -> clean exit 0 (not the App).
#   6. Owning issue already closed -> clean exit 0.
#   7. pulls list gh failure -> exit 2 (fail-closed, never false green).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-silent-pr-close-check"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$bin" ]] || fail "missing $bin"
chmod +x "$bin"

scratch="$(mktemp -d -t silent-pr-close.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/bin" "$scratch/state"
gh_log="$scratch/gh-calls.log"
: >"$gh_log"

cat >"$scratch/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh' >> "$GH_LOG"
for a in "$@"; do printf ' %s' "$a" >> "$GH_LOG"; done
printf '\n' >> "$GH_LOG"
cmd="${1:-}"; shift || true
case "$cmd" in
    token) echo "stub gh: token generate must never run in tests" >&2; exit 1 ;;
    api)
        endpoint="${1:-}"
        case "$endpoint" in
            -X) printf '{}' ;;
            "repos/"*"/pulls?state=closed"*)
                [ "${MOCK_PULLS_RC:-0}" != "0" ] && exit "$MOCK_PULLS_RC"
                printf '%s' "${MOCK_CLOSED_PRS:-[]}" ;;
            "repos/"*"/git/refs/heads/"*)
                [ "${MOCK_BRANCH_EXISTS:-no}" = "yes" ] && printf '{"ref":"x"}' || exit 1 ;;
            *"timeline?"*)
                # per-PR timeline: MOCK_TIMELINE_<num>
                num=$(printf '%s' "$endpoint" | sed 's/.*issues\/\([0-9]*\)\/timeline.*/\1/')
                eval "printf '%s' \"\${MOCK_TIMELINE_$num:-[]}\"" ;;
            "repos/"*"/issues/"*)
                num="${endpoint##*/}"
                v="MOCK_ISSUE_$num"
                if [ -n "${!v:-}" ]; then printf '%s' "${!v}"; else printf '{"state":"open"}'; fi ;;
            *) printf '[]' ;;
        esac
        ;;
    issue)
        sub="${1:-}"
        case "$sub" in
            comment) : ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac
exit 0
EOF
chmod +x "$scratch/bin/gh"

export GH_LOG="$gh_log"
export GH_TOKEN="stub-token"
export PATH="$scratch/bin:/usr/local/bin:/usr/bin:/bin"
GH="$scratch/bin/gh"
export GH
export SILENT_CLOSE_STATE_DIR="$scratch/state"

# The #6258 fixture set (shape, not real payloads):
P6258_PRS='[{"number":6258,"merged_at":null,"head":{"ref":"claim/issue-6252"},"title":"worker delivery"}]'
# timeline: attest-requested comment 66 min before close (outside window),
# then the bare closed event at 03:19:27Z — no closing comment.
P6258_TIMELINE='[
 {"event":"commented","created_at":"2026-09-13T02:12:51Z","actor":{"login":"nishfleet-worker[bot]"}},
 {"event":"closed","created_at":"2026-09-13T03:19:27Z","actor":{"login":"nishfleet-worker[bot]"}}
]'

# --- 1. --help -------------------------------------------------------------------
"$bin" --help >"$scratch/help.out" 2>&1 || fail "--help exited nonzero"
ok "--help exits 0"

# --- 2. #6258 replay -> flag + exit 1, --apply traces once ------------------------
set +e
out="$(MOCK_CLOSED_PRS="$P6258_PRS" MOCK_TIMELINE_6258="$P6258_TIMELINE" \
      MOCK_BRANCH_EXISTS=no MOCK_ISSUE_6252='{"state":"open"}' \
      "$bin" fleet-ops 2>"$scratch/err.2")"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "#6258 replay: expected exit 1, got $rc (out: $out, err: $(cat "$scratch/err.2"))"
printf '%s' "$out" | grep -q "SILENT-PR-CLOSE repo=Nishfleet/fleet-ops pr=6258" \
    || fail "no flag line for the replayed shape: $out"
printf '%s' "$out" | grep -q "issue=6252 issue_state=open" || fail "flag line missing owning issue: $out"
printf '%s' "$out" | grep -q "branch_exists=no" || fail "flag line missing branch evidence: $out"
printf '%s' "$out" | tail -1 | grep -q "silent_pr_closes=1" || fail "bad measure line: $out"

: >"$gh_log"
set +e
out="$(MOCK_CLOSED_PRS="$P6258_PRS" MOCK_TIMELINE_6258="$P6258_TIMELINE" \
      MOCK_BRANCH_EXISTS=no MOCK_ISSUE_6252='{"state":"open"}' \
      "$bin" fleet-ops --apply 2>"$scratch/err.2b")"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "--apply replay: expected exit 1, got $rc"
grep -q "issue comment 6252" "$gh_log" || fail "--apply posted no trace on the owning issue: $(cat "$gh_log")"
: >"$gh_log"
set +e
MOCK_CLOSED_PRS="$P6258_PRS" MOCK_TIMELINE_6258="$P6258_TIMELINE" \
    MOCK_BRANCH_EXISTS=no MOCK_ISSUE_6252='{"state":"open"}' \
    "$bin" fleet-ops --apply >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "dedup rerun: expected exit 1, got $rc"
if grep -q "issue comment" "$gh_log"; then
    fail "deduped rerun posted a second trace comment: $(cat "$gh_log")"
fi
ok "#6258 replay flags, --apply traces once, dedupe holds"

# --- 3. commented close -> clean ---------------------------------------------------
: >"$gh_log"
COMMENTED_TL='[
 {"event":"commented","created_at":"2026-09-13T03:19:26Z","actor":{"login":"nishfleet-worker[bot]"}},
 {"event":"closed","created_at":"2026-09-13T03:19:27Z","actor":{"login":"nishfleet-worker[bot]"}}
]'
set +e
out="$(MOCK_CLOSED_PRS="$P6258_PRS" MOCK_TIMELINE_6258="$COMMENTED_TL" \
      MOCK_ISSUE_6252='{"state":"open"}' "$bin" fleet-ops 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "commented close: expected exit 0, got $rc ($out)"
printf '%s' "$out" | tail -1 | grep -q "silent_pr_closes=0" || fail "commented close flagged: $out"
ok "commented close -> clean"

# --- 4. merged PR -> clean -----------------------------------------------------------
MERGED_PRS='[{"number":7000,"merged_at":"2026-09-13T05:00:00Z","head":{"ref":"claim/issue-6999"}}]'
set +e
out="$(MOCK_CLOSED_PRS="$MERGED_PRS" "$bin" fleet-ops 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "merged PR: expected exit 0, got $rc"
ok "merged PR -> clean"

# --- 5. human close -> clean -----------------------------------------------------------
HUMAN_TL='[
 {"event":"closed","created_at":"2026-09-13T03:19:27Z","actor":{"login":"nish3451"}}
]'
set +e
out="$(MOCK_CLOSED_PRS="$P6258_PRS" MOCK_TIMELINE_6258="$HUMAN_TL" \
      MOCK_ISSUE_6252='{"state":"open"}' "$bin" fleet-ops 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "human close: expected exit 0, got $rc ($out)"
ok "human-actor close -> clean"

# --- 6. owning issue closed -> clean ---------------------------------------------------
set +e
out="$(MOCK_CLOSED_PRS="$P6258_PRS" MOCK_TIMELINE_6258="$P6258_TIMELINE" \
      MOCK_BRANCH_EXISTS=no MOCK_ISSUE_6252='{"state":"closed"}' \
      "$bin" fleet-ops 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "closed issue: expected exit 0, got $rc ($out)"
ok "owning issue closed -> clean"

# --- 7. pulls failure -> exit 2 ----------------------------------------------------------
set +e
MOCK_PULLS_RC=1 "$bin" fleet-ops >/dev/null 2>"$scratch/err.7"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "pulls failure: expected exit 2, got $rc"
grep -q "PULLS-LIST-FAILED" "$scratch/err.7" || fail "no loud flag on pulls failure"
ok "pulls failure -> exit 2 fail-closed"

echo "PASS: fleet-silent-pr-close-check"
