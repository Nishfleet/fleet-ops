#!/usr/bin/env bash
# tests/pi-issue-start.test.sh
#
# Proves pi-issue-start no-ops when the worker is live and starts when not.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-issue-start"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT

# fleet-ops#1451: pi-issue-start now regenerates a missing .in before start.
# Redirect the packet dir, worker prompt, and gh to fakes so this test never
# touches the live ~/.local/state/pi-issues or the real gh.
export PI_ISSUES_DIR="$fake/issues"
mkdir -p "$PI_ISSUES_DIR"
printf '# stub worker prompt\n' > "$fake/worker.md"
export WORKER_PROMPT="$fake/worker.md"
cat >"$fake/gh" <<'FAKE'
#!/usr/bin/env bash
echo '{"title":"x","body":"x","labels":[]}'
exit 0
FAKE
chmod +x "$fake/gh"
export GH="$fake/gh"

cat >"$fake/systemctl" <<'FAKE'
#!/usr/bin/env bash
shift  # --user
: >"$FAKE_DIR/called"
printf '%s\n' "$*" >>"$FAKE_DIR/called"
case "$1" in
  is-active)
    cat "$FAKE_DIR/state"
    exit 0
    ;;
  show)
    echo 0
    exit 0
    ;;
  start)
    echo started
    exit 0
    ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$fake/systemctl"
export FAKE_DIR="$fake"

echo activating >"$fake/state"
out="$(SYSTEMCTL="$fake/systemctl" "$bin" fleet-ops-20)"
printf '%s\n' "$out" | grep -q 'no-op' || fail "activating must no-op, got: $out"
grep -q '^start ' "$fake/called" && fail "must not call start when activating: $(cat "$fake/called")"
ok "activating worker is a no-op"

: >"$fake/called"
echo inactive >"$fake/state"
out="$(SYSTEMCTL="$fake/systemctl" "$bin" fleet-ops-20)"
grep -q '^start ' "$fake/called" || fail "inactive must call start, called=$(cat "$fake/called")"
ok "inactive worker calls systemctl start"

# fleet-ops#82: this file is already on ci.yml verify-command. Workers cannot
# add a new workflow line (no Workflows permission). The exec-review prompt
# contract rides here so CI fails if someone deletes it from prompts/worker.md.
bash "$here/exec-review-prompt.test.sh" || fail "exec-review prompt contract tests failed"
# fleet-ops#1260: pstack playbooks are the default worker discipline.
# Hosted here so CI fails if someone deletes the routing from worker.md
# without a workflow edit (workers have no Workflows permission).
bash "$here/pstack-worker-prompt.test.sh" || fail "pstack worker prompt contract tests failed"
