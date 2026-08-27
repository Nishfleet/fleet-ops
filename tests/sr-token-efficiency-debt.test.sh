#!/usr/bin/env bash
# tests/sr-token-efficiency-debt.test.sh
#
# fleet-ops#670: the three shipped assembler hits the token-efficiency gate
# named on a full --all scan. This drill is the class guard so they cannot
# return: no byte-cap on the decisions ledger, and prompt {{placeholders}}
# live after the static body.
#
# Hosted by tests/pi-scout-packet-assembly.test.sh so P14 covers it without
# a workflow edit.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

assembly="$repo_root/lib/packet-assembly.sh"
[[ -f "$assembly" ]] || fail "missing $assembly"

# --- 1. packet_decisions_ledger must not byte-cap the ledger ---------------
fn=$(awk '/^packet_decisions_ledger\(/,/^}/' "$assembly")
[[ -n "$fn" ]] || fail "packet_decisions_ledger function not found"
if printf '%s\n' "$fn" | grep -Eq 'head[[:space:]]+-c'; then
    fail "packet_decisions_ledger still byte-caps with head -c (fleet-ops#670)"
fi
ok "packet_decisions_ledger has no head -c cap"

# --- 2. a ledger longer than 8KB is emitted in full ------------------------
scratch="$(mktemp -d -t token-eff-debt.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

plan="$scratch/plan.md"
{
    printf '# Plan\n\n## DECISIONS LEDGER\n\n'
    # 9KB of filler plus a unique tail the old 8KB cap would drop.
    python3 -c 'print("x" * 9000)'
    printf '\nLEDGER-TAIL-MARKER-670\n'
} >"$plan"

export PACKET_PLAN_FILE="$plan"
# shellcheck source=/dev/null
source "$assembly"
out=$(packet_decisions_ledger)
printf '%s\n' "$out" | grep -Fq 'LEDGER-TAIL-MARKER-670' \
    || fail "packet_decisions_ledger truncated a >8KB ledger (missing tail marker)"
ok "packet_decisions_ledger emits a >8KB ledger in full"

# --- 3. prompt templates: first {{ is in the last 30% of the static body --
# Mirrors lib/fleet-token-efficiency-check.py _findings_for_markdown (fleet-ops#523).
python3 - "$repo_root/prompts/researcher.md" "$repo_root/prompts/blind-audit.md" <<'PY' \
    || fail "prompt template placeholders are still before the static body"
import sys

def body_without_code(text: str) -> str:
    lines = text.splitlines()
    out = []
    in_code = False
    fence = ""
    for line in lines:
        stripped = line.lstrip()
        if not in_code and stripped.startswith("```"):
            in_code = True
            fence = stripped[:3]
            continue
        if in_code and stripped.startswith(fence):
            in_code = False
            fence = ""
            continue
        if not in_code:
            out.append(line)
    return "\n".join(out)

failed = 0
for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    lines = body_without_code(text).splitlines()
    placeholders = [i for i, line in enumerate(lines, start=1) if "{{" in line]
    if not placeholders:
        print(f"OK: {path} has no {{{{placeholders}}}}")
        continue
    first = placeholders[0]
    threshold = max(1, int(len(lines) * 0.7))
    if first <= threshold:
        print(
            f"FAIL: {path}: first {{{{ at line {first} of {len(lines)} "
            f"(threshold {threshold}); move placeholders to the end",
            file=sys.stderr,
        )
        failed = 1
    else:
        print(f"OK: {path}: first {{{{ at line {first} of {len(lines)}}}")
sys.exit(failed)
PY
ok "researcher.md and blind-audit.md keep placeholders after the static body"

ok "sr-token-efficiency debt (fleet-ops#670): ledger uncapped, placeholders last"
