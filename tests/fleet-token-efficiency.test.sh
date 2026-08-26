#!/usr/bin/env bash
# tests/fleet-token-efficiency.test.sh
#
# CI drill for sr-token-efficiency (fleet-ops#523).
# Proves bin/fleet-token-efficiency-check rejects anti-patterns in custom
# prompt assemblers and passes on clean changes.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-token-efficiency-check"
lib="$repo_root/lib/fleet-token-efficiency-check.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"

# --- scratch git repo with fixtures -----------------------------------------
scratch="$(mktemp -d -t token-eff.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/repo/bin" "$scratch/repo/lib" "$scratch/repo/prompts"

cd "$scratch/repo"
git init -q .
git config user.email "test@example.com"
git config user.name "Test"

# A good shell assembler: static prompt first, then target.
cat >"$scratch/repo/bin/good-scout" <<'EOF'
#!/usr/bin/env bash
packet_assemble() {
    cat "$PROMPT_FILE"
    echo
    echo "TARGET REPO: $REPO"
}
EOF
chmod +x "$scratch/repo/bin/good-scout"

# A bad shell assembler: volatile timestamp before the prompt, head -c cap,
# unsorted find, and a max_tokens flag.
cat >"$scratch/repo/bin/bad-agent" <<'EOF'
#!/usr/bin/env bash
assemble() {
    printf 'RUN_TS=%s\n' "$RUN_TS"
    cat "$PROMPT"
    {
        merged=$(find "$REPO_ROOT" -type f -not -path '*/\.git/*' | head -200)
        echo "$merged"
        head -c 8000 "$LEDGER"
    }
    pi --print --provider devin --model glm-5-2 \
       --max_tokens 4096 < packet.md
}
EOF
chmod +x "$scratch/repo/bin/bad-agent"

# A good prompt template (no placeholders, or placeholders at the end).
cat >"$scratch/repo/prompts/good-scout.md" <<'EOF'
# Scout

Do good work.

TARGET: Nishfleet/0509
EOF

# A bad prompt template with placeholders at the top.
cat >"$scratch/repo/prompts/bad-researcher.md" <<'EOF'
# Researcher

Run timestamp: {{NOW_ISO}}

Do frontier research.
EOF

# Bad Python in-place substitution.
cat >"$scratch/repo/lib/bad-sub.py" <<'EOF'
import sys
prompt_path, out_path = sys.argv[1], sys.argv[2]
tpl = open(prompt_path).read()
tpl = tpl.replace('{{NOW_ISO}}', now)
open(out_path, 'w').write(tpl)
EOF

# --- helper: run the gate and capture rc + output -----------------------------
out_file="$scratch/out.txt"
run_check() {
    local ns_file="$1" root="${2:-$scratch/repo}"
    set +e
    "$bin" --name-status "$ns_file" --root "$root" >"$out_file" 2>&1
    rc=$?
    set -e
}

# --- scenario 1: all fixture files staged -> should REJECT ------------------
cd "$scratch/repo"
git add -A
git diff --name-status --cached >"$scratch/all-status.txt"

run_check "$scratch/all-status.txt"
[[ "$rc" == "1" ]] || fail "bad fixtures must be rejected (rc=$rc out=$(cat "$out_file"))"

out="$(cat "$out_file")"
[[ "$out" == *"bad-agent"* ]] || fail "rejection must name bad-agent"
[[ "$out" == *"byte/line truncation"* ]] || fail "rejection must mention byte truncation"
[[ "$out" == *"head -n cap"* ]] || fail "rejection must mention head -n cap"
[[ "$out" == *"volatile content before static prompt"* ]] || fail "rejection must mention volatile before prompt"
[[ "$out" == *"max_tokens"* ]] || fail "rejection must mention max_tokens"
[[ "$out" == *"bad-researcher.md"* ]] || fail "rejection must name bad-researcher.md"
[[ "$out" == *"bad-sub.py"* ]] || fail "rejection must name bad-sub.py"
ok "gate rejects fixture assemblers with all anti-patterns"

# --- scenario 2: only good fixtures staged -> should pass -------------------
git reset -q
rm -f "$scratch/repo/bin/bad-agent" "$scratch/repo/prompts/bad-researcher.md" "$scratch/repo/lib/bad-sub.py"
git add -A
git diff --name-status --cached >"$scratch/good-status.txt"

run_check "$scratch/good-status.txt"
[[ "$rc" == "0" ]] || fail "good fixtures must pass (rc=$rc out=$(cat "$out_file"))"
ok "gate passes clean fixture assemblers"

# --- scenario 3: empty name-status -> pass ----------------------------------
: >"$scratch/empty-status.txt"
run_check "$scratch/empty-status.txt"
[[ "$rc" == "0" ]] || fail "empty diff must pass (rc=$rc out=$(cat "$out_file"))"
ok "gate passes empty diff"

# --- scenario 4: self-skip (gate's own files in a diff) -> pass -------------
mkdir -p "$scratch/self/bin" "$scratch/self/lib" "$scratch/self/tests" "$scratch/self/prompts"
cp "$bin" "$scratch/self/bin/fleet-token-efficiency-check"
cp "$lib" "$scratch/self/lib/fleet-token-efficiency-check.py"
cp "$repo_root/tests/fleet-token-efficiency.test.sh" "$scratch/self/tests/fleet-token-efficiency.test.sh"
cp "$repo_root/prompts/worker.md" "$scratch/self/prompts/worker.md"
cd "$scratch/self"
git init -q .
git config user.email "self@example.com"
git config user.name "Self"
git add -A
git diff --name-status --cached >"$scratch/self-status.txt"

run_check "$scratch/self-status.txt" "$scratch/self"
[[ "$rc" == "0" ]] || fail "gate must not trip on its own files (rc=$rc out=$(cat "$out_file"))"
ok "gate does not trip on its own files"

# --- scenario 5: --all on a clean root passes -------------------------------
cd "$scratch/repo"
git reset -q
git add -A
set +e
"$bin" --all --root "$scratch/repo" >"$out_file" 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "--all on a clean repo must pass (rc=$rc out=$(cat "$out_file"))"
ok "--all on a clean repo passes"

# --- scenario 6: --all on a root with bad untracked files rejects -----------
rm -f "$scratch/repo/bin/bad-agent" "$scratch/repo/prompts/bad-researcher.md" "$scratch/repo/lib/bad-sub.py"
cat >"$scratch/repo/bin/bad-agent" <<'EOF'
#!/usr/bin/env bash
assemble() {
    printf 'RUN_TS=%s\n' "$RUN_TS"
    cat "$PROMPT"
    head -c 8000 "$LEDGER"
}
EOF
set +e
"$bin" --all --root "$scratch/repo" >"$out_file" 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "--all must reject untracked bad files (rc=$rc out=$(cat "$out_file"))"
ok "--all rejects untracked bad assemblers"

ok "fleet-token-efficiency-check: PR gate, fixture drills, and self-skip pass"
