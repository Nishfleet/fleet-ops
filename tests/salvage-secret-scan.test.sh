#!/usr/bin/env bash
# tests/salvage-secret-scan.test.sh
#
# Proves the salvage pre-push secret-scan helper (fleet-ops#1204):
#   1. clean diff  -> exit 0 (push allowed)
#   2. planted fake credential in the salvaged diff -> exit 1 (quarantine)
#   3. placeholder values are NOT flagged -> exit 0
#   4. usage / unresolvable ref -> exit 2
#   5. --json emits a machine-readable verdict line
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/salvage-secret-scan"
scanner="$repo_root/lib/salvage_secret_scan.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$scanner" ]] || fail "scanner missing: $scanner"

# --- helper: build a temp repo with a baseline commit ----------------------
make_repo() {
    local d="$1"
    git init -q -b main "$d"
    git -C "$d" config user.email t@t
    git -C "$d" config user.name t
    printf 'hello\n' >"$d/README.md"
    git -C "$d" add README.md
    git -C "$d" commit -qm baseline
    # origin/HEAD is the default base; point it at the baseline.
    git -C "$d" branch -M main
    git -C "$d" update-ref refs/remotes/origin/HEAD HEAD
}

# --- 1. clean diff -> exit 0 ----------------------------------------------
scratch="$(mktemp -d -t salvage-scan.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
make_repo "$scratch/repo"
printf 'feature line\n' >>"$scratch/repo/README.md"
git -C "$scratch/repo" add README.md
git -C "$scratch/repo" commit -qm "salvage: clean work"
set +e
"$bin" "$scratch/repo" HEAD >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "clean diff must exit 0, got $rc"
ok "clean diff exits 0 (push allowed)"

# --- 2. planted fake credential -> exit 1 (quarantine) ---------------------
make_repo "$scratch/repo2"
cat >"$scratch/repo2/leak.txt" <<'EOF'
# planted fake credential fixture — NOT a real secret
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
EOF
git -C "$scratch/repo2" add leak.txt
git -C "$scratch/repo2" commit -qm "salvage: leaked credential"
set +e
out="$("$bin" "$scratch/repo2" HEAD 2>&1)"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "credential diff must exit 1, got $rc ($out)"
printf '%s\n' "$out" | grep -qi 'quarantine' || fail "must mention quarantine: $out"
printf '%s\n' "$out" | grep -qi 'aws_secret_access_key' || fail "must name the credential: $out"
ok "planted fake credential exits 1 (quarantine)"

# --- 3. placeholder values are NOT flagged -> exit 0 -----------------------
make_repo "$scratch/repo3"
cat >"$scratch/repo3/ok.txt" <<'EOF'
aws_secret_access_key = your_secret_key_here
token = <insert-your-token>
EOF
git -C "$scratch/repo3" add ok.txt
git -C "$scratch/repo3" commit -qm "salvage: placeholders only"
set +e
"$bin" "$scratch/repo3" HEAD >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "placeholder values must exit 0, got $rc"
ok "placeholder values exit 0 (not flagged)"

# --- 4. usage / unresolvable ref -> exit 2 ---------------------------------
set +e
"$bin" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "2" ]] || fail "no args must exit 2, got $rc"
set +e
"$bin" "$scratch/repo" no-such-ref >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "2" ]] || fail "unresolvable ref must exit 2, got $rc"
ok "usage and unresolvable ref exit 2"

# --- 5. --json emits a machine-readable verdict ----------------------------
make_repo "$scratch/repo4"
printf 'x\n' >>"$scratch/repo4/README.md"
git -C "$scratch/repo4" add README.md
git -C "$scratch/repo4" commit -qm "salvage: json"
json="$("$bin" "$scratch/repo4" HEAD --json)"
printf '%s\n' "$json" | grep -q '"verdict":"clean"' || fail "json must say clean: $json"
printf '%s\n' "$json" | grep -q '"commit":"' || fail "json must name the commit: $json"
ok "--json emits a machine-readable verdict"

# --- 6. sgscan layer: a finding quarantines even on a clean python scan -----
# A fake sgscan that reports an ERROR finding must flip a clean diff to
# quarantine (exit 1), proving the sgscan layer is wired in.
fake_sgscan="$here/fixtures/fake-sgscan-findings"
[[ -x "$fake_sgscan" ]] || fail "missing fixture: $fake_sgscan"
make_repo "$scratch/repo5"
printf 'feature\n' >>"$scratch/repo5/README.md"
git -C "$scratch/repo5" add README.md
git -C "$scratch/repo5" commit -qm "salvage: sgscan layer"
set +e
SGSCAN="$fake_sgscan" SGSCAN_TIMEOUT=5 "$bin" "$scratch/repo5" HEAD >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "sgscan finding must quarantine, got $rc"
ok "sgscan finding quarantines a clean python scan"

echo "ALL PASS"
