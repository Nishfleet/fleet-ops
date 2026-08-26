#!/usr/bin/env bash
# tests/fleet-claim.test.sh
#
# Proves fleet-claim creates an ad-hoc claim branch atomically and that a
# second agent starting the same scope sees the first claim.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-claim"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export XDG_RUNTIME_DIR="$scratch/run"
export FLEET_CLAIM_CHECKOUT_ROOT="$scratch/products"
export FLEET_CLAIM_REMOTE=origin
export FLEET_CLAIM_MAIN_BRANCH=main

mkdir -p "$FLEET_CLAIM_CHECKOUT_ROOT"

# Set up a bare remote and a product checkout.
bare="$scratch/bare/fleet-ops.git"
mkdir -p "$scratch/bare"
git -c init.defaultBranch=main init --bare -q "$bare"

checkout="$FLEET_CLAIM_CHECKOUT_ROOT/fleet-ops"
git -c init.defaultBranch=main clone -q "$bare" "$checkout"

(
    cd "$checkout"
    git config user.email "test@example.com"
    git config user.name "Test"
    echo 'init' > file.txt
    git add file.txt
    git commit -q -m 'initial'
    # CI runners (and any host whose init.defaultBranch is not main) name
    # the first commit master. fleet-claim fetches FLEET_CLAIM_MAIN_BRANCH=main.
    git branch -M main
    git push -q -u origin main
)

# --- first start succeeds ----------------------------------------------------
if ! out=$("$bin" start fleet-ops lib/seat-lib.sh); then
    fail "first start must succeed"
fi
printf '%s\n' "$out" | grep -q '^claimed:' || fail "expected 'claimed:' line, got: $out"

if ! git -C "$checkout" ls-remote origin 'refs/heads/claim/adhoc-lib_seat-lib.sh' 2>/dev/null | grep -q .; then
    fail 'claim branch missing on origin after start'
fi
ok 'first start creates claim branch'

# --- second start on same scope fails ----------------------------------------
set +e
out=$("$bin" start fleet-ops lib/seat-lib.sh 2>&1)
rc=$?
set -e
[[ "$rc" == 1 ]] || fail "second start must fail with rc=1, got rc=$rc"
printf '%s\n' "$out" | grep -q 'claimed-by-other' || fail "expected 'claimed-by-other' in: $out"
ok 'second start on the same scope is rejected'

# --- check semantics ---------------------------------------------------------
set +e
out=$("$bin" check fleet-ops lib/seat-lib.sh)
rc=$?
set -e
[[ "$rc" == 1 ]] || fail "check on claimed scope must return 1, got rc=$rc"
printf '%s\n' "$out" | grep -q '^claimed:' || fail "expected 'claimed:' from check, got: $out"

set +e
out=$("$bin" check fleet-ops prompts/intake.md)
rc=$?
set -e
[[ "$rc" == 0 ]] || fail "check on free scope must return 0, got rc=$rc"
printf '%s\n' "$out" | grep -q '^free:' || fail "expected 'free:' from check, got: $out"
ok 'check reports claimed and free scopes correctly'

# --- release and re-claim ----------------------------------------------------
out=$("$bin" release fleet-ops lib/seat-lib.sh)
printf '%s\n' "$out" | grep -q '^released:' || fail "expected 'released:' line, got: $out"

if git -C "$checkout" ls-remote origin 'refs/heads/claim/adhoc-lib_seat-lib.sh' 2>/dev/null | grep -q .; then
    fail 'claim branch still on origin after release'
fi

out=$("$bin" start fleet-ops lib/seat-lib.sh)
printf '%s\n' "$out" | grep -q '^claimed:' || fail "re-claim after release failed: $out"
ok 'release deletes branch and allows re-claim'

# --- concurrent starts: exactly one winner -----------------------------------
# Release the branch from the previous block first.
"$bin" release fleet-ops lib/seat-lib.sh >/dev/null

first_out="$scratch/first.out"
second_out="$scratch/second.out"

# Run two starts at the same time. The per-scope lock serialises them, so
# the second must see the branch created by the first and fail.
set +e
"$bin" start fleet-ops lib/seat-lib.sh >"$first_out" 2>&1 &
first_pid=$!
"$bin" start fleet-ops lib/seat-lib.sh >"$second_out" 2>&1 &
second_pid=$!

wait "$first_pid"
first_rc=$?
wait "$second_pid"
second_rc=$?
set -e

first_won=0; grep -q '^claimed:' "$first_out" || first_won=1
first_lost=0; grep -q 'claimed-by-other' "$first_out" || first_lost=1
second_won=0; grep -q '^claimed:' "$second_out" || second_won=1
second_lost=0; grep -q 'claimed-by-other' "$second_out" || second_lost=1

# One must win and one must lose. Accept either order.
wins=0; losses=0
[[ "$first_rc" == 0 && "$first_won" == 0 ]] && wins=$((wins+1))
[[ "$second_rc" == 0 && "$second_won" == 0 ]] && wins=$((wins+1))
[[ "$first_rc" == 1 && "$first_lost" == 0 ]] && losses=$((losses+1))
[[ "$second_rc" == 1 && "$second_lost" == 0 ]] && losses=$((losses+1))

if [[ "$wins" != 1 || "$losses" != 1 ]]; then
    fail "concurrent starts: expected 1 win and 1 loss, got wins=$wins losses=$losses
first rc=$first_rc:
$(cat "$first_out")
second rc=$second_rc:
$(cat "$second_out")"
fi
ok 'concurrent starts produce exactly one winner'

# --- conflicts: pre-flight file-overlap scan ---------------------------------
# Hermetic gh stub so the open-PR scan runs but never touches real GitHub.
# The stub always returns an empty PR list; the adhoc-branch scan is what we
# exercise here (it uses the local bare remote).
ghstub="$scratch/bin"
mkdir -p "$ghstub"
cat >"$ghstub/gh" <<'STUB'
#!/usr/bin/env bash
echo '[]'
STUB
chmod +x "$ghstub/gh"
export PATH="$ghstub:$PATH"

# Clean slate: release any claim left by the concurrent-start block.
"$bin" release fleet-ops lib/seat-lib.sh >/dev/null 2>&1 || true

# No claims at all -> no conflicts, exit 0.
set +e
out=$("$bin" conflicts fleet-ops lib/seat-lib.sh 2>&1)
rc=$?
set -e
[[ "$rc" == 0 ]] || fail "conflicts with no claims must exit 0, got rc=$rc (out=$out)"
printf '%s\n' "$out" | grep -q '^no-conflicts:' || fail "expected 'no-conflicts:', got: $out"
ok 'conflicts: clear when no claims exist'

# Claim by full file path, then conflicts on the same path must see it.
"$bin" start fleet-ops lib/seat-lib.sh >/dev/null
set +e
out=$("$bin" conflicts fleet-ops lib/seat-lib.sh 2>&1)
rc=$?
set -e
[[ "$rc" == 1 ]] || fail "conflicts on a claimed file must exit 1, got rc=$rc (out=$out)"
printf '%s\n' "$out" | grep -q '^claim-conflict:' || fail "expected 'claim-conflict:', got: $out"
ok 'conflicts: detects a claim scoped to the same file path'

# Basename match: a claim scoped to the bare basename must be detected when
# the second agent asks about the full path. This is the realistic case where
# two agents name the same shared file differently.
"$bin" start fleet-ops seat-caps.json >/dev/null
set +e
out=$("$bin" conflicts fleet-ops config/seat-caps.json 2>&1)
rc=$?
set -e
[[ "$rc" == 1 ]] || fail "basename match must exit 1, got rc=$rc (out=$out)"
printf '%s\n' "$out" | grep -q 'claim-conflict:.*seat-caps.json' \
  || fail "expected a seat-caps.json claim-conflict, got: $out"
ok 'conflicts: detects a claim by basename when the path differs'

# An unrelated file is still clear (no false positive from the existing claims).
set +e
out=$("$bin" conflicts fleet-ops prompts/intake.md 2>&1)
rc=$?
set -e
[[ "$rc" == 0 ]] || fail "unrelated file must exit 0, got rc=$rc (out=$out)"
printf '%s\n' "$out" | grep -q '^no-conflicts:' || fail "expected 'no-conflicts:', got: $out"
ok 'conflicts: unrelated file is clear despite other live claims'

# Multi-file: one matching file in the list is enough to flag.
set +e
out=$("$bin" conflicts fleet-ops prompts/intake.md lib/seat-lib.sh 2>&1)
rc=$?
set -e
[[ "$rc" == 1 ]] || fail "multi-file with one match must exit 1, got rc=$rc (out=$out)"
printf '%s\n' "$out" | grep -q 'claim-conflict:.*seat-lib.sh' \
  || fail "expected a seat-lib.sh claim-conflict in multi-file mode, got: $out"
ok 'conflicts: one matching file in a multi-file request flags the lot'

# Release clears the conflict.
"$bin" release fleet-ops lib/seat-lib.sh >/dev/null
"$bin" release fleet-ops seat-caps.json >/dev/null
set +e
out=$("$bin" conflicts fleet-ops lib/seat-lib.sh config/seat-caps.json 2>&1)
rc=$?
set -e
[[ "$rc" == 0 ]] || fail "after release, conflicts must exit 0, got rc=$rc (out=$out)"
ok 'conflicts: clear again after all claims released'
