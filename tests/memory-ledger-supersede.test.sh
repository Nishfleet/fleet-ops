#!/usr/bin/env bash
# tests/memory-ledger-supersede.test.sh
#
# fleet-ops#389: prove the ledger-supersession curator pass without
# touching the live vault or agent memory stores.
#
# Mechanism proof the issue names: fixture memory + fixture ledger line
# → the pass marks SUPERSEDED-BY:<date+title> and does not rewrite the
# claim. Unrelated memories stay unmarked. A second run is a no-op.
# A vault sync-conflict refuses to write.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/memory-ledger-supersede.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$bin" ]] || fail "missing $bin"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$bin" \
  || fail "memory-ledger-supersede is not valid Python"
ok "script parses"

scratch="$(mktemp -d -t memory-ledger-supersede.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

vault="$scratch/vault"
compiled="$vault/03 Knowledge/compiled/shared-memory/global"
agent_mem="$scratch/agent-memory"
ledger="$vault/_system/shared-memory/decisions-ledger.md"
mkdir -p "$compiled" "$agent_mem" "$(dirname "$ledger")" \
         "$vault/03 Knowledge/compiled/shared-memory/_history/global"

cat >"$ledger" <<'LEDGER'
# Decisions Ledger

## Contract
- Append-only.

## Ledger

### Product / fleet
- 2026-08-26 | 0509 EXCLUSIVE supply | New PRODUCT work generation (scouts, buffer, research seeding) targets 0509 ONLY; don't feed it every repo. siterep-public supply deferred. | fleet-ops intake-repos.json
- 2026-08-26 | loop for ALL repos | The gap-closure loop applies to ALL repos; VPS systemd only for what GitHub cannot host. | fleet-ops #185
- 2026-08-26 | capacity is measured, never declared | No hand-set constant may bind fleet throughput. | fleet-ops #217
- 2026-08-24 | Tailscale | Server→Mac tailnet traffic gets locked down via ACL after the 48h watch. | tailscale-acl-watch/

### Open questions Nish has NOT decided (do not treat as decided)
- 2026-08-26 | straitly seat | FLAG: an agent added paid-metered provider straitly. | fleet-restoration
LEDGER

cat >"$compiled/all-seven-products-in-scope.md" <<'MEM'
---
status: "current"
memory_id: "all-seven-products-in-scope"
created_at: "2026-08-25T12:00:00Z"
---

# All 7 products in scope

The fleet's stored belief: all 7 products in scope for scouts and intake.
MEM

cat >"$compiled/unrelated-tailscale.md" <<'MEM'
---
status: "current"
memory_id: "unrelated-tailscale"
created_at: "2026-08-24T00:00:00Z"
---

# Tailscale ACL pending

ACL draft blocks VPS to Mac; tripwire Wednesday, then Nish pastes the file.
MEM

history_file="$vault/03 Knowledge/compiled/shared-memory/_history/global/all-seven-products-in-scope.md"
cat >"$history_file" <<'MEM'
# archived copy — all 7 products in scope — must not be marked
MEM

cat >"$agent_mem/eleven-repos-enrolled.md" <<'MEM'
---
name: eleven-repos-enrolled
---

The agent-ready queue enrolled on 11 repos 2026-08-25. All 11 repos in scope.
MEM

cat >"$agent_mem/MEMORY.md" <<'IDX'
# Memory Index

- [All 7 products](all-seven-products-in-scope.md) — all 7 products in scope for scouts
- [Tailscale ACL pending](unrelated-tailscale.md) — ACL draft blocks VPS to Mac
IDX

run_pass() {
    python3 "$bin" \
        --vault "$vault" \
        --ledger "$ledger" \
        --compiled-root "$vault/03 Knowledge/compiled/shared-memory" \
        --agent-memory "$agent_mem" \
        "$@"
}

# --- 1. fixture ledger + fixture memory → mark -----------------------------
out="$(run_pass)"
echo "$out" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' \
  || fail "stdout is not JSON: $out"
marked="$(echo "$out" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["marked"])')"
[[ "$marked" -ge 3 ]] || fail "expected ≥3 files marked (compiled + agent + index), got $marked from $out"

stale="$compiled/all-seven-products-in-scope.md"
grep -F 'SUPERSEDED-BY:2026-08-26 0509 EXCLUSIVE supply' "$stale" \
  || fail "compiled stale memory was not marked"
grep -F 'The fleet'\''s stored belief: all 7 products in scope for scouts and intake.' "$stale" \
  || fail "compiled memory body was rewritten (curator must not author prose)"
ok "compiled stale memory marked; claim prose untouched"

grep -F 'SUPERSEDED-BY:2026-08-26 0509 EXCLUSIVE supply' "$agent_mem/eleven-repos-enrolled.md" \
  || fail "agent memory was not marked"
grep -F 'The agent-ready queue enrolled on 11 repos 2026-08-25. All 11 repos in scope.' \
    "$agent_mem/eleven-repos-enrolled.md" \
  || fail "agent memory body was rewritten"
ok "agent memory marked; claim prose untouched"

# Index: conflicting bullet marked, unrelated bullet not.
grep -F 'all 7 products in scope for scouts SUPERSEDED-BY:2026-08-26 0509 EXCLUSIVE supply' \
    "$agent_mem/MEMORY.md" \
  || fail "MEMORY.md conflicting bullet was not marked"
grep -F 'ACL draft blocks VPS to Mac SUPERSEDED-BY' "$agent_mem/MEMORY.md" \
  && fail "MEMORY.md unrelated bullet was marked" || true
grep -F '[Tailscale ACL pending](unrelated-tailscale.md) — ACL draft blocks VPS to Mac' \
    "$agent_mem/MEMORY.md" \
  || fail "MEMORY.md unrelated bullet was rewritten"
ok "MEMORY.md marks only the conflicting index entry"

# --- 2. unrelated compiled memory stays clean ------------------------------
grep -F 'SUPERSEDED-BY:' "$compiled/unrelated-tailscale.md" \
  && fail "unrelated tailscale memory was marked" || true
ok "unrelated memory not marked"

# Nearby ledger lines that share words ("only", "never", "ALL repos") must
# not inherit a marker — title-only exclusive/solely is the conflict shape.
grep -F 'SUPERSEDED-BY:2026-08-26 loop for ALL repos' "$stale" \
  && fail "loop-for-all-repos line leaked a marker (body 'only' is not title-narrowing)" || true
grep -F 'SUPERSEDED-BY:2026-08-26 capacity is measured, never declared' "$stale" \
  && fail "capacity/never-declared line leaked a marker" || true
ok "non-narrowing ledger titles do not mark"

# --- 3. open-questions FLAG line does not mark -----------------------------
grep -F 'SUPERSEDED-BY:2026-08-26 straitly seat' "$stale" \
  && fail "open-questions FLAG line leaked a marker" || true
ok "open-questions section is ignored"

# --- 4. history copies are not swept ---------------------------------------
grep -F 'SUPERSEDED-BY:' "$history_file" \
  && fail "_history copy was marked" || true
ok "_history is skipped"

# --- 5. ledger itself is never modified ------------------------------------
if grep -F 'SUPERSEDED-BY:' "$ledger"; then
    fail "ledger file was modified"
fi
ok "ledger file untouched"

# --- 6. idempotent second run ----------------------------------------------
out2="$(run_pass)"
marked2="$(echo "$out2" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["marked"])')"
[[ "$marked2" == "0" ]] || fail "second run re-marked files: $out2"
count="$(grep -c 'SUPERSEDED-BY:2026-08-26 0509 EXCLUSIVE supply' "$stale" || true)"
[[ "$count" == "1" ]] || fail "second run duplicated the marker (count=$count)"
ok "second run is a no-op (idempotent)"

# --- 7. --dry-run does not write -------------------------------------------
fresh="$compiled/dry-run-candidate.md"
cat >"$fresh" <<'MEM'
---
created_at: "2026-08-25T00:00:00Z"
---

all 7 products in scope
MEM
dry="$(run_pass --dry-run)"
dry_marked="$(echo "$dry" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["marked"])')"
[[ "$dry_marked" -ge 1 ]] || fail "dry-run should report the new candidate: $dry"
grep -F 'SUPERSEDED-BY:' "$fresh" && fail "dry-run wrote a marker" || true
ok "dry-run reports without writing"

# --- 8. sync-conflict refuse -----------------------------------------------
touch "$vault/note.sync-conflict-20260826.md"
set +e
conflict_out="$(run_pass 2>"$scratch/conflict.err")"
conflict_rc=$?
set -e
[[ "$conflict_rc" -eq 2 ]] || fail "sync-conflict should exit 2, got $conflict_rc"
echo "$conflict_out" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["sync_conflict"] is True' \
  || fail "sync-conflict JSON must set sync_conflict true: $conflict_out"
grep -F 'SUPERSEDED-BY:' "$fresh" && fail "sync-conflict still wrote" || true
rm -f "$vault/note.sync-conflict-20260826.md"
ok "sync-conflict exits 2 and writes nothing"

# --- 9. drop-in + MANIFEST wiring ------------------------------------------
dropin="$repo_root/systemd/nish-memory-curator.service.d/10-ledger-supersede.conf"
manifest="$repo_root/MANIFEST"
[[ -f "$dropin" ]] || fail "missing drop-in: $dropin"
grep -q '^ExecStart=/usr/bin/python3 /home/nish/.local/bin/memory-ledger-supersede$' "$dropin" \
  || fail "drop-in must ExecStart the pass (no leading '-', so a failed pass fails the curator)"
grep -q '^ExecStartPre=' "$dropin" && fail "this is a curator pass, not ExecStartPre" || true
bin_line="bin/memory-ledger-supersede.py /home/nish/.local/bin/memory-ledger-supersede"
drop_line="systemd/nish-memory-curator.service.d/10-ledger-supersede.conf /home/nish/.config/systemd/user/nish-memory-curator.service.d/10-ledger-supersede.conf"
grep -Fxq "$bin_line" "$manifest" || fail "MANIFEST missing: $bin_line"
grep -Fxq "$drop_line" "$manifest" || fail "MANIFEST missing: $drop_line"
ok "drop-in ExecStart and MANIFEST entries are locked"

echo "OK: ledger-supersession pass marks conflicting fixture memories and nothing else"
