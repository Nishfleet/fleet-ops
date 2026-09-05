#!/usr/bin/env bash
# tests/fleet-writer-token.test.sh
#
# fleet-ops#3445: every fleet organ that creates issues, comments, labels or
# PRs must mint and use the nishfleet-worker App token (worker-token --print)
# before any GitHub write, so writes never fall through to the human gh
# identity (which tripped the secondary "submitted too quickly" limit and
# blocked the orchestrator's PR for 20 minutes).
#
# This is the mechanical prevention for the class: it FAILS when a writer
# organ is added or edited without the App-token mint, so the regression
# cannot silently come back. It also pins the intake's 60s x attempt
# secondary-limit backoff.
#
# Offline; no gh / git / worker-token calls are made.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# A gh WRITE command is anything that creates/edits/closes an issue, comments,
# edits labels, creates a PR, or issues a mutating gh api call against an
# Issues/PRs/Labels/Comments resource. Non-content writes (e.g. siterep-uptime's
# best-effort external gist heartbeat) are intentionally out of scope: they do
# not consume the content-creation limit this issue fixes, and an App org token
# lacks gist scope.
WRITE_RE='gh (issue (create|comment|edit|close)|pr create|label create|label edit|api [^)]*/(issues|pulls|labels|comments)[^)]*(-X (POST|PATCH|PUT|DELETE)))'

BASH_MARK='_minted='
PY_MARK='_ensure_worker_token'

missing=0
checked=0

check_bash() {
    local f="$1"
    if ! grep -qF "$BASH_MARK" "$f"; then
        echo "FAIL-LIST: bash writer organ without App-token mint: $f" >&2
        missing=$(( missing + 1 ))
    fi
    checked=$(( checked + 1 ))
}
check_py() {
    local f="$1"
    if ! grep -qF "$PY_MARK" "$f"; then
        echo "FAIL-LIST: python writer without App-token mint: $f" >&2
        missing=$(( missing + 1 ))
    fi
    checked=$(( checked + 1 ))
}

# Python writer organs that run standalone and write directly to GitHub. The
# two here file issues themselves; the rest of the python helpers (e.g.
# lib/issue-file.py) are exec'd by a bash wrapper that already mints and so
# inherit GH_TOKEN. Add a new standalone python writer here with its mint.
check_py "bin/fleet-ops-drift.py"
check_py "libexec/fleet-metrics-export.py"

# Bash writer organs: files that directly issue a gh write command.
mapfile -t bash_writers < <(grep -rlE "$WRITE_RE" bin/ lib/pi-intake-tick.sh 2>/dev/null || true)
for f in "${bash_writers[@]}"; do
    case "$f" in
        *__pycache__*|*.p|*.py) continue ;;
    esac
    check_bash "$f"
done

[[ "$checked" -gt 0 ]] || fail "no writer organs were found to check (discovery broken)"
[[ "$missing" -eq 0 ]] || fail "$missing writer organ(s) lack the App-token mint"
ok "every writer organ ($checked) carries the nishfleet-worker App-token mint"

# The intake must implement the 60s x attempt secondary-limit backoff and the
# state gate (fleet-ops#3445), so a "submitted too quickly" does not fail the
# tick or hammer the limit.
tick="$repo_root/lib/pi-intake-tick.sh"
[[ -f "$tick" ]] || fail "intake tick missing: $tick"
grep -qF 'sleep $((60 * edit_attempt))' "$tick"  || fail "intake edit loop must back off 60s x attempt"
grep -qF 'sleep $((60 * comment_attempt))' "$tick" || fail "intake comment loop must back off 60s x attempt"
grep -qF '_gh_secondary_write' "$tick" || fail "intake must persist secondary-limit backoff state"
grep -qF 'gate: gh_rate_limit secondary' "$tick" || fail "intake must hold the tick on an active secondary backoff"
ok "intake backs off 60s x attempt and holds the tick on 'submitted too quickly'"

echo
echo "ALL PASS: fleet writer organs mint the App token; intake secondary-limit backoff pinned."
