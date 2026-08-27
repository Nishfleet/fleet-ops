#!/usr/bin/env bash
# tests/pi-issue-run-scratch-home-identity.test.sh
#
# fleet-ops#567 class lock: an offline pi-issue-run test that redirects HOME
# into scratch and then invokes bin/pi-issue-run must stub a working
# nishfleet-worker App identity (creds file + minting worker-token). Without
# that stub the run dies at DEAD APP IDENTITY before proving the path it
# owns. That was the tried-reset success path on origin/main at 4acc42e.
#
# PR #591 mirrored the app-identity stub into the five siblings. This file
# keeps that class from regressing. It does not weaken the scream in
# bin/pi-issue-run.
#
# Worker App tokens cannot add a P14 verify-command line. This lock rides
# on tests/worker-token-fail-closed.test.sh, which is already listed.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

noncomment_has() {
  local f="$1" needle="$2"
  grep -F -- "$needle" "$f" | grep -vE '^[[:space:]]*#' | grep -q .
}

# A file needs the stub when it actually redirects HOME and invokes the
# wrapper. Comment-only mentions do not count (fleet-ops#490).
needs_identity_stub() {
  local f="$1"
  grep -E '^[[:space:]]*export HOME=' "$f" | grep -vE '^[[:space:]]*#' | grep -q . || return 1
  grep -E 'bin/pi-issue-run|"\$bin"|\$bin[[:space:]]' "$f" \
    | grep -vE '^[[:space:]]*#' | grep -q . || return 1
  return 0
}

has_identity_stub() {
  local f="$1"
  noncomment_has "$f" "nishfleet-worker.env" || return 1
  noncomment_has "$f" "WORKER_TOKEN_BIN" || return 1
  noncomment_has "$f" "GH_TOKEN" || return 1
  return 0
}

# --- wiring: must actually run from a P14-listed parent ---------------------
host="$repo_root/tests/worker-token-fail-closed.test.sh"
[[ -f "$host" ]] || fail "missing P14 host: $host"
grep -E 'bash[[:space:]]+"\$here/pi-issue-run-scratch-home-identity.test.sh"' "$host" >/dev/null \
  || fail "tests/worker-token-fail-closed.test.sh must bash-invoke this file (fleet-ops#567)"
ok "lock is wired through tests/worker-token-fail-closed.test.sh (already in P14)"

# Empty-host + comment-only drill: a filename mention is not an invoke.
empty=$(mktemp)
trap 'rm -f "$empty"' EXIT
: >"$empty"
empty_hit=0
grep -E 'bash[[:space:]]+"\$here/pi-issue-run-scratch-home-identity.test.sh"' "$empty" \
  && empty_hit=1
[[ "$empty_hit" -eq 0 ]] || fail "empty-host drill must miss (hit=$empty_hit)"
printf '# tests/pi-issue-run-scratch-home-identity.test.sh\n' >"$empty"
comment_hit=0
grep -E 'bash[[:space:]]+"\$here/pi-issue-run-scratch-home-identity.test.sh"' "$empty" \
  && comment_hit=1
[[ "$comment_hit" -eq 0 ]] \
  || fail "comment-only filename must not satisfy the wiring lock (hit=$comment_hit)"
ok "wiring lock requires a bash invoke line; comment-only filename is not enough"

# --- drill: the #567 red shape must fail the scanner ------------------------
scratch="$(mktemp -d -t pi-issue-scratch-id.XXXXXX)"
trap 'rm -rf "$scratch" "$empty"' EXIT

cat >"$scratch/red-no-stub.test.sh" <<'EOF'
#!/usr/bin/env bash
# The 4acc42e tried-reset success path: scratch HOME, no creds, no mint stub.
export HOME="$scratch/home"
mkdir -p "$HOME"
bash "$repo_root/bin/pi-issue-run" "$inst"
EOF
needs_identity_stub "$scratch/red-no-stub.test.sh" \
  || fail "red fixture must be classified as needing a stub"
if has_identity_stub "$scratch/red-no-stub.test.sh"; then
  fail "red fixture (no stub) must fail has_identity_stub"
fi
ok "drill REJECT: scratch HOME + pi-issue-run with no App identity stub"

cat >"$scratch/comment-only.test.sh" <<'EOF'
#!/usr/bin/env bash
export HOME="$scratch/home"
mkdir -p "$HOME"
# : >"$HOME/.config/fleet-worker/nishfleet-worker.env"
# export WORKER_TOKEN_BIN="$stub_bin/worker-token"
# printf 'export GH_TOKEN=fake-test-token-cccccccccccccccc\n'
bash "$repo_root/bin/pi-issue-run" "$inst"
EOF
needs_identity_stub "$scratch/comment-only.test.sh" \
  || fail "comment-only fixture must still need a stub"
if has_identity_stub "$scratch/comment-only.test.sh"; then
  fail "comment-only stub lines must not satisfy has_identity_stub"
fi
ok "drill REJECT: comment-only App identity lines are not a stub"

cat >"$scratch/green-stubbed.test.sh" <<'EOF'
#!/usr/bin/env bash
export HOME="$scratch/home"
mkdir -p "$HOME"
mkdir -p "$HOME/.config/fleet-worker"
: >"$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"
cat >"$stub_bin/worker-token" <<'STUB'
#!/usr/bin/env bash
printf 'export GH_TOKEN=fake-test-token-cccccccccccccccc\n'
exit 0
STUB
export WORKER_TOKEN_BIN="$stub_bin/worker-token"
bash "$repo_root/bin/pi-issue-run" "$inst"
EOF
needs_identity_stub "$scratch/green-stubbed.test.sh" \
  || fail "green fixture must be classified as needing a stub"
has_identity_stub "$scratch/green-stubbed.test.sh" \
  || fail "green fixture (creds + WORKER_TOKEN_BIN + GH_TOKEN mint) must pass"
ok "drill PASS: scratch HOME + creds file + minting worker-token stub"

# --- live repo: every offline pi-issue-run test that redirects HOME ---------
shopt -s nullglob
live=("$here"/pi-issue-run-*.test.sh)
shopt -u nullglob
[[ ${#live[@]} -gt 0 ]] || fail "no tests/pi-issue-run-*.test.sh files found"

scanned=0
for f in "${live[@]}"; do
  [[ "$(basename "$f")" == "pi-issue-run-scratch-home-identity.test.sh" ]] && continue
  needs_identity_stub "$f" || continue
  scanned=$((scanned + 1))
  has_identity_stub "$f" \
    || fail "$(basename "$f") redirects HOME and invokes pi-issue-run but does not stub nishfleet-worker.env + WORKER_TOKEN_BIN + GH_TOKEN (fleet-ops#567)"
  ok "live stub present: ${f#"$repo_root"/}"
done
[[ "$scanned" -ge 1 ]] || fail "scanner found no live pi-issue-run tests that redirect HOME (broken matcher)"
ok "live: $scanned offline pi-issue-run test(s) stub App identity"

ok "pi-issue-run scratch-HOME App identity class lock (fleet-ops#567)"
