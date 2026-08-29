#!/usr/bin/env bash
# tests/git-mirror-update.test.sh
#
# fleet-ops#1213: local bare mirrors + git clone --reference-if-able.
# Hermetic: fake origins, no network.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/git-mirror-update"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t git-mirror.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

git_ident() {
    git -C "$1" config user.email mirror-test@localhost
    git -C "$1" config user.name mirror-test
}

# Same-line init.defaultBranch pin (fleet-ops#598 / ci-hosted-paths).
make_origin() {
    local name="$1"
    local bare="$scratch/origins/${name}.git"
    local checkout="$scratch/checkouts/${name}"
    mkdir -p "$scratch/origins" "$scratch/checkouts"
    git -c init.defaultBranch=main init --bare -q "$bare"
    git -c init.defaultBranch=main clone -q "$bare" "$checkout"
    git_ident "$checkout"
    printf 'base\n' >"$checkout/README"
    git -C "$checkout" add README
    git -C "$checkout" commit -q -m base
    git -C "$checkout" push -q origin HEAD:main
    git -C "$checkout" checkout -q -B main origin/main
}

make_intake() {
    cat >"$scratch/intake-repos.json" <<JSON
{
  "checkout_root": "$scratch/checkouts",
  "repos": [{"name": "demo"}]
}
JSON
}

export GIT_MIRROR_ROOT="$scratch/mirrors"
export GIT_MIRROR_INTAKE="$scratch/intake-repos.json"
export GIT_MIRROR_ORIGIN_BASE="$scratch/origins"
export GIT_MIRROR_CHECKOUT_ROOT="$scratch/checkouts"
export FLEET_OPS_CANONICAL_CHECKOUT="$scratch/no-such-canonical"

make_origin demo
make_intake

# --- 1. --help names the clone convention ---------------------------------
set +e
help_out="$("$bin" --help 2>&1)"
help_rc=$?
set -e
[[ "$help_rc" == "2" ]] || fail "--help must exit 2, got $help_rc"
printf '%s\n' "$help_out" | grep -q -- '--reference-if-able' \
    || fail "--help must name --reference-if-able: $help_out"
printf '%s\n' "$help_out" | grep -qi 'read-only' \
    || fail "--help must say mirrors are read-only: $help_out"
ok "--help names --reference-if-able and read-only"

# --- 2. creates a bare mirror ---------------------------------------------
"$bin"
mirror="$GIT_MIRROR_ROOT/demo.git"
[[ -d "$mirror" ]] || fail "expected bare mirror at $mirror"
[[ "$(git --git-dir="$mirror" rev-parse --is-bare-repository)" == "true" ]] \
    || fail "mirror must be bare"
git --git-dir="$mirror" rev-parse --verify -q refs/heads/main >/dev/null \
    || fail "mirror must have refs/heads/main"
ok "creates a bare mirror for each enrolled repo"

# --- 3. fetch picks up a new commit ---------------------------------------
printf 'second\n' >"$scratch/checkouts/demo/second.txt"
git -C "$scratch/checkouts/demo" add second.txt
git -C "$scratch/checkouts/demo" commit -q -m second
git -C "$scratch/checkouts/demo" push -q origin HEAD:main
"$bin"
git --git-dir="$mirror" cat-file -e "$(git -C "$scratch/checkouts/demo" rev-parse HEAD)^{commit}" \
    || fail "mirror fetch must pick up the new commit"
ok "lightweight fetch updates the mirror"

# --- 4. push to the mirror is refused -------------------------------------
printf 'do-not-land\n' >"$scratch/checkouts/demo/push-me.txt"
git -C "$scratch/checkouts/demo" add push-me.txt
git -C "$scratch/checkouts/demo" commit -q -m 'must not land on mirror'
new_sha="$(git -C "$scratch/checkouts/demo" rev-parse HEAD)"
set +e
push_err="$(git -C "$scratch/checkouts/demo" push "$mirror" HEAD:main 2>&1)"
push_rc=$?
set -e
[[ "$push_rc" != "0" ]] || fail "push to mirror must fail, got rc=0 ($push_err)"
printf '%s\n' "$push_err" | grep -qi 'read-only' \
    || fail "pre-receive must say read-only, got: $push_err"
mirror_main="$(git --git-dir="$mirror" rev-parse refs/heads/main)"
[[ "$mirror_main" != "$new_sha" ]] \
    || fail "refused push must not update refs/heads/main"
ok "mirrors refuse push (read-only fetch target)"

# --- 5. script itself never pushes ----------------------------------------
if grep -E '^[^#]*\bgit push\b' "$bin" >/dev/null; then
    fail "git-mirror-update must never invoke git push"
fi
ok "git-mirror-update source has no git push"

# --- 6. corrupt mirror is quarantined and recreated -----------------------
rm -rf "$mirror/objects"
mkdir -p "$mirror/objects"
"$bin"
[[ -d "$mirror" ]] || fail "update must recreate the mirror after quarantine"
[[ "$(git --git-dir="$mirror" rev-parse --is-bare-repository)" == "true" ]] \
    || fail "recreated mirror must be bare"
found_corrupt=0
for d in "$GIT_MIRROR_ROOT"/.corrupt-demo-*; do
    [[ -e "$d" ]] || continue
    found_corrupt=1
done
[[ "$found_corrupt" == "1" ]] || fail "corrupt mirror must be quarantined under .corrupt-demo-*"
ok "corrupt mirror is quarantined and replaced"

# --- 7. missing mirror degrades clone via --reference-if-able -------------
missing="$GIT_MIRROR_ROOT/no-such-mirror.git"
dest_plain="$scratch/clone-degrade"
git clone --reference-if-able "$missing" "$scratch/origins/demo.git" "$dest_plain" >/dev/null 2>&1 \
    || fail "clone --reference-if-able must succeed when the mirror path is absent"
git -C "$dest_plain" rev-parse --verify -q HEAD >/dev/null \
    || fail "degraded clone must have HEAD"
ok "missing mirror degrades to a plain clone"

# --- 7b. shallow checkout seed is unshallowed -----------------------------
# git clone --reference-if-able skips a shallow repo ("is shallow"). 0509's
# products checkout is shallow; a mirror seeded from it must be unshallowed
# or packet clones pay the full cost.
rm -rf "$scratch/checkouts/demo" "$mirror"
origin_uri="file://$scratch/origins/demo.git"
git clone --depth=1 -q "$origin_uri" "$scratch/checkouts/demo"
git_ident "$scratch/checkouts/demo"
[[ "$(git -C "$scratch/checkouts/demo" rev-parse --is-shallow-repository)" == "true" ]] \
    || fail "precondition: depth=1 file:// clone must be shallow"
"$bin"
[[ "$(git --git-dir="$mirror" rev-parse --is-shallow-repository)" == "false" ]] \
    || fail "mirror seeded from a shallow checkout must be unshallowed"
shallow_dest="$scratch/clone-unshallow"
shallow_warn="$(git clone --no-local --reference-if-able "$mirror" -q "$scratch/origins/demo.git" "$shallow_dest" 2>&1)"
printf '%s\n' "$shallow_warn" | grep -qi 'is shallow' \
    && fail "unshallowed mirror must not be skipped as shallow: $shallow_warn"
[[ -f "$shallow_dest/.git/objects/info/alternates" ]] \
    || fail "clone against unshallowed mirror must write alternates"
ok "shallow checkout seed is unshallowed for --reference-if-able"

# --- 8. time + bytes before/after (acceptance) ----------------------------
# Random blob so zlib cannot collapse the before/after comparison.
dd if=/dev/urandom of="$scratch/checkouts/demo/blob.bin" bs=1024 count=256 status=none
git -C "$scratch/checkouts/demo" add blob.bin
git -C "$scratch/checkouts/demo" commit -q -m blob
git -C "$scratch/checkouts/demo" push -q origin HEAD:main
"$bin"

before_dir="$scratch/clone-before"
after_dir="$scratch/clone-after"
TIMEFORMAT='%R'
before_time="$( { time git clone --no-local -q "$scratch/origins/demo.git" "$before_dir" ; } 2>&1 )"
after_time="$( { time git clone --no-local --reference-if-able "$mirror" -q "$scratch/origins/demo.git" "$after_dir" ; } 2>&1 )"
before_bytes="$(du -sb "$before_dir" | awk '{print $1}')"
after_bytes="$(du -sb "$after_dir" | awk '{print $1}')"
before_obj="$(du -sb "$before_dir/.git/objects" | awk '{print $1}')"
after_obj="$(du -sb "$after_dir/.git/objects" | awk '{print $1}')"

echo "packet clone before: ${before_time}s ${before_bytes}B (objects ${before_obj}B)"
echo "packet clone after:  ${after_time}s ${after_bytes}B (objects ${after_obj}B)"

[[ -f "$after_dir/.git/objects/info/alternates" ]] \
    || fail "reference clone must write objects/info/alternates"
[[ "$after_bytes" -lt "$before_bytes" ]] \
    || fail "reference clone dest must be smaller than a plain clone ($after_bytes >= $before_bytes)"
[[ "$after_obj" -lt "$before_obj" ]] \
    || fail "reference clone objects must be smaller ($after_obj >= $before_obj)"
ok "reference clone is smaller than a plain clone (time+bytes shown above)"

# --- 9. drop-in piggybacks the 5-min exporter, does not add a timer -------
dropin="$repo_root/systemd/fleet-metrics-export.service.d/10-git-mirrors.conf"
[[ -f "$dropin" ]] || fail "missing $dropin"
grep -q '^ExecStartPost=-/home/nish/.local/bin/git-mirror-update$' "$dropin" \
    || fail "drop-in must ExecStartPost=- git-mirror-update (dash: fetch fault must not fail export)"
grep -q 'fleet-ops#1213' "$dropin" || fail "drop-in must name fleet-ops#1213"
if grep -R -l 'git-mirror-update' "$repo_root/systemd"/*.timer >/dev/null 2>&1; then
    fail "must not add a new timer for git-mirror-update (heartbeat: no new schedules)"
fi
ok "exporter drop-in is ExecStartPost=- (no new timer)"

# --- 10. MANIFEST + clone convention in prompts/docs ----------------------
manifest="$repo_root/MANIFEST"
grep -Fxq 'bin/git-mirror-update /home/nish/.local/bin/git-mirror-update' "$manifest" \
    || fail "MANIFEST missing git-mirror-update"
grep -Fxq 'systemd/fleet-metrics-export.service.d/10-git-mirrors.conf /home/nish/.config/systemd/user/fleet-metrics-export.service.d/10-git-mirrors.conf' "$manifest" \
    || fail "MANIFEST missing exporter drop-in"

for f in \
    "$repo_root/prompts/worker.md" \
    "$repo_root/prompts/intake.md" \
    "$repo_root/prompts/heartbeat.md" \
    "$repo_root/bin/pi-systemd-run" \
    "$repo_root/README.md"
do
    grep -q -- '--reference-if-able' "$f" \
        || fail "$f must name git clone --reference-if-able (fleet-ops#1213)"
done
grep -qi 'never push' "$repo_root/prompts/worker.md" \
    || fail "worker.md must say never push to a mirror"
grep -qi 'never push' "$repo_root/prompts/heartbeat.md" \
    || fail "heartbeat.md must say never push to a mirror"
ok "MANIFEST, prompts, pi-systemd-run, and README name the clone convention"

# --- 11. symlink invocation resolves repo_root (fleet-ops#1390) -------------
# Installed as ~/.local/bin/git-mirror-update -> <repo>/bin/git-mirror-update.
# BASH_SOURCE[0] reports the symlink path, so repo_root must be derived via
# readlink -f or the canonical config/intake-repos.json is looked up at the
# symlink's directory (~/.local/config/...) and missing.
# Hermetic: run a copy of the real script through a symlink in a different
# directory, with the intended checkout's config present and GIT_MIRROR_INTAKE
# unset so the default resolution is exercised.
sym_root="$scratch/altrepo"
sym_bin="$sym_root/bin/git-mirror-update"
mkdir -p "$sym_root/bin" "$sym_root/config" "$scratch/symlink-dir"
cp "$bin" "$sym_bin"
chmod +x "$sym_bin"
ln -sf "$sym_bin" "$scratch/symlink-dir/git-mirror-update"
printf '{"checkout_root":"%s","repos":[]}' "$scratch/checkouts" \
    > "$sym_root/config/intake-repos.json"
set +e
sym_out="$(env -u GIT_MIRROR_INTAKE "$scratch/symlink-dir/git-mirror-update" 2>&1)"
sym_rc=$?
set -e
[[ "$sym_rc" == "0" ]] \
    || fail "symlink invocation must exit 0, got $sym_rc: $sym_out"
grep -q 'no enrolled repos' <<<"$sym_out" \
    || fail "symlink invocation must read the altrepo config, got: $sym_out"
grep -qi 'intake file missing' <<<"$sym_out" \
    && fail "symlink invocation must NOT resolve intake to the symlink dir: $sym_out"
ok "symlink invocation resolves repo_root via readlink -f (no intake-file-missing)"

echo "ALL git-mirror-update tests passed"
