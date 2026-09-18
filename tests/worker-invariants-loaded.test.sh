#!/usr/bin/env bash
# tests/worker-invariants-loaded.test.sh
#
# The per-run invariants (hard rules, PR body contract, memory budget, D1 rules)
# moved out of prompts/worker.md into the repo AGENTS.md on 2026-09-18. Moving
# them was only half the job: Pi's AGENTS.md context-file discovery walks up from
# the STARTUP cwd, and every one of these units starts in /home/nish, so the repo
# file is never reached that way. The units pass it explicitly with Pi's own
# --append-system-prompt flag instead.
#
# This test exists because the gap was not theoretical. In the window where the
# rules were in AGENTS.md but nothing loaded them, the first worker on the new
# rail (fleet-ops-7783) committed as "Nish" and ran 23 minutes past the merge of
# its own PR. If a future edit drops the flag, the rules go quiet again and
# nothing else fails — so fail here, loudly.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

invariants="$repo_root/AGENTS.md"
[[ -f "$invariants" ]] || fail "repo AGENTS.md not found at $invariants"

CANON='/home/nish/workspaces/tooling/fleet-ops-deploy-clone/AGENTS.md'

for unit in pi-issue@ pi-intake@ pi-scout@; do
    f="$repo_root/systemd/${unit}.service"
    [[ -f "$f" ]] || fail "missing $f"
    grep -q -- "--append-system-prompt \"$CANON\"" "$f" \
        || fail "${unit}.service must pass --append-system-prompt \"$CANON\" (the units start in /home/nish, so cwd discovery cannot reach the repo AGENTS.md)"
    # canonical checkout path, never cwd-relative: a unit must not depend on
    # which checkout it happens to run from (same class as fleet-ops#4921).
    grep -q -- '--append-system-prompt "AGENTS.md"' "$f" \
        && fail "${unit}.service must use the absolute canonical path, not a cwd-relative AGENTS.md"
    ok "${unit}.service appends the repo AGENTS.md"
done

# The rules themselves must still be in the file the units point at.
for needle in 'failed command' 'no-match probe' 'D1 schema rule' 'Memory budget rule' 'Agent names are forbidden'; do
    grep -q "$needle" "$invariants" \
        || fail "AGENTS.md lost the invariant rule: $needle"
done
ok "AGENTS.md still carries the hard rules, PR body contract, memory budget and D1 rules"

echo "worker-invariants-loaded: PASS"
