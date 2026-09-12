#!/usr/bin/env bash
# tests/token-efficiency-canonical-not-assembler.test.sh
#
# fleet-ops#5603 regression: lib/standing-rules/canonical.md is prose that
# mentions "prompt"/"packet"/"pi --print" and carries {{PLACEHOLDER}}
# substitution tokens. The token-efficiency gate's _looks_like_assembler()
# treated ANY file containing those words as a prompt assembler, so every
# PR touching canonical.md inherited an un-clearable REJECT (PR #5599).
#
# This drill pins the scoping: markdown outside prompts/ is a template only
# via prompts/ path membership or literal substitution code, while the real
# assembler detections (prompts/ templates, bin/ shell packets) are
# unchanged.
#
# Hosted by tests/fleet-token-efficiency.test.sh so P14 covers it without
# a workflow edit.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-token-efficiency-check"
lib="$repo_root/lib/fleet-token-efficiency-check.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"

scratch="$(mktemp -d -t token-eff-canonical.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/repo/bin" "$scratch/repo/lib/standing-rules" "$scratch/repo/prompts"
out_file="$scratch/out.txt"

check() {
    # check <relative-path> -> $rc
    set +e
    printf 'M\t%s\n' "$1" | "$bin" --name-status - --root "$scratch/repo" >"$out_file" 2>&1
    rc=$?
    set -e
}

# --- 1. the REAL canonical.md must not be classified as an assembler ------
canonical="$repo_root/lib/standing-rules/canonical.md"
[[ -f "$canonical" ]] || fail "missing $canonical"
# Fixture sanity: the real file still trips the original bug (word markers
# plus an early {{ placeholder) — otherwise this drill proves nothing.
grep -qi 'prompt' "$canonical" \
    || fail "canonical.md no longer contains 'prompt' — fixture lost its trigger"
grep -qF '{{' "$canonical" \
    || fail "canonical.md no longer contains '{{' — fixture lost its trigger"
grep -qiF 'pi --print' "$canonical" \
    || fail "canonical.md no longer contains 'pi --print' — fixture lost its trigger"
cp "$canonical" "$scratch/repo/lib/standing-rules/canonical.md"
check "lib/standing-rules/canonical.md"
[[ "$rc" == "0" ]] || fail "real canonical.md must not be a prompt assembler (rc=$rc out=$(cat "$out_file"))"
ok "real lib/standing-rules/canonical.md is not classified as an assembler"

# --- 2. canonical-shaped prose fixture (synthetic) must pass --------------
# Same shape: the words prompt/packet/pi --print plus an early {{ token,
# living outside prompts/.
cat >"$scratch/repo/lib/prose-doc.md" <<'EOF'
# Worker packet contract

Every worker prompt starts from a sealed packet. The renderer expands
{{SURFACE_PHRASE}} before dispatch, then hands off to `pi --print`.

The prompt is static; volatile context is appended after it.
EOF
check "lib/prose-doc.md"
[[ "$rc" == "0" ]] || fail "prose md outside prompts/ must pass (rc=$rc out=$(cat "$out_file"))"
ok "prose markdown outside prompts/ is not a prompt assembler"

# --- 3. control: a prompts/ template is still scanned ---------------------
cat >"$scratch/repo/prompts/bad-template.md" <<'EOF'
# bad template

{{FIRST_PLACEHOLDER}} sits before most of the static body.

$(date is fine here)

Sed doc sed sed sed sed sed sed sed sed sed.
EOF
check "prompts/bad-template.md"
[[ "$rc" == "1" ]] || fail "prompt template under prompts/ must still be checked (rc=$rc out=$(cat "$out_file"))"
ok "prompt templates under prompts/ are still scanned"

# --- 4. control: a bin/ shell packet assembler is still scanned -----------
cat >"$scratch/repo/bin/bad-agent" <<'EOF'
#!/usr/bin/env bash
assemble() {
    cat "$PROMPT_FILE"
    head -c 8000 "$LEDGER"
}
EOF
chmod +x "$scratch/repo/bin/bad-agent"
check "bin/bad-agent"
[[ "$rc" == "1" ]] || fail "bin/ shell packet assembler must still be checked (rc=$rc out=$(cat "$out_file"))"
ok "bin/ shell packet assemblers are still scanned"

# --- 5. markdown outside prompts/ with substitution code is a template ----
# The strong-marker escape hatch: literal .replace('{{ ... }})' template code
# in a .md file outside prompts/ still marks it an assembler.
cat >"$scratch/repo/lib/tpl-builder.md" <<'EOF'
# Template builder

Rendered via `tpl.replace('{{NOW_ISO}}', now)` then dispatched.

{{EARLY_PLACEHOLDER}}

More prose here to push the placeholder before the static body ends.
EOF
check "lib/tpl-builder.md"
[[ "$rc" == "1" ]] || fail "md with literal substitution code must still classify as a template (rc=$rc out=$(cat "$out_file"))"
ok "literal substitution code still marks markdown as a template"

ok "token-efficiency canonical-not-assembler regression (fleet-ops#5603)"
