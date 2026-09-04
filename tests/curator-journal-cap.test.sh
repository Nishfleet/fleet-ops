#!/usr/bin/env bash
# tests/curator-journal-cap.test.sh
#
# fleet-ops#1520 lock: nish-memory-curator stdout must not dump the full
# trust_denials.entries list into the journal. The live bug was ~40KB of
# historical dispositioned denials every 5 min (~11MB/day) that also
# poisoned broad journalctl greps. The fix lives in memory-compound
# (journal_safe_status, merged as nish3451/memory-compound#9 / be8c9db);
# this test is the fleet-ops class lock so a revert of that helper, or a
# stdout path that bypasses it, fails CI here.
#
# Two layers:
#   1. Offline: import the live memoryctl and prove journal_safe_status
#      empties entries, records entries_capped, and leaves the original
#      status dict untouched (so write_curator_status still persists the
#      full list to curator-health.json).
#   2. Live (VPS only): the most recent curator journal line is journal-
#      safe AND curator-health.json still holds the full entries list.
#      Hosted CI skips this layer (no unit, no vault health file).
#
# Hosted by tests/ci-standards-audit.test.sh so P14 runs it without a
# workflow-file edit (the worker App cannot push .github/workflows/**).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

MEMORYCTL="${MEMORYCTL:-/home/nish/workspaces/tooling/memory-compound/memoryctl.py}"
HEALTH="${CURATOR_HEALTH:-/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/curator-health.json}"
UNIT="${CURATOR_UNIT:-nish-memory-curator.service}"
# 2 KiB is well under the pre-fix ~40KB dump and well over the live
# journal-safe line (~467 bytes with 101 capped entries).
MAX_STDOUT_BYTES="${CURATOR_MAX_STDOUT_BYTES:-2048}"

# Hosted CI has no memory-compound checkout. Skip the import layer
# rather than fail the P14 batch; the live VPS run is the real lock.
if [[ ! -f "$MEMORYCTL" ]]; then
  ok "memoryctl absent ($MEMORYCTL) — hosted skip"
  echo "OK: curator-journal-cap.test.sh"
  exit 0
fi
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$MEMORYCTL" \
  || fail "memoryctl is not valid Python"

# --- 1. offline: journal_safe_status empties entries, records count ------
python3 - "$MEMORYCTL" <<'PY' || fail "journal_safe_status did not cap entries"
import importlib.util, json, sys
from pathlib import Path

path = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("memoryctl_1520", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

if not hasattr(mod, "journal_safe_status"):
    raise SystemExit("memoryctl has no journal_safe_status (the #1520 helper)")

entries = [
    {"id": f"denial-{i}", "class": "invalid_stored_outcome_proof"}
    for i in range(101)
]
original = {
    "healthy": True,
    "trust_denials": {
        "classes": {"invalid_stored_outcome_proof": 101},
        "dispositioned": 101,
        "entries": entries,
        "new": 0,
        "total": 101,
    },
    "version": "1.1.0",
}
# Deep-ish copy of the nested entries list so we can prove the original
# was not mutated in place (write_curator_status must still persist it).
original_len = len(original["trust_denials"]["entries"])

slim = mod.journal_safe_status(original)
td = slim["trust_denials"]
if td.get("entries") != []:
    raise SystemExit(f"stdout entries not empty: {td.get('entries')!r}")
if td.get("entries_capped") != 101:
    raise SystemExit(f"entries_capped want 101 got {td.get('entries_capped')!r}")
if td.get("total") != 101:
    raise SystemExit(f"total dropped: {td.get('total')!r}")
if td.get("dispositioned") != 101:
    raise SystemExit(f"dispositioned dropped: {td.get('dispositioned')!r}")
if td.get("new") != 0:
    raise SystemExit(f"new dropped: {td.get('new')!r}")
if td.get("classes") != {"invalid_stored_outcome_proof": 101}:
    raise SystemExit(f"classes dropped: {td.get('classes')!r}")
if slim.get("healthy") is not True:
    raise SystemExit("healthy flag dropped")

# Original must still hold the full list — health-file write uses it.
if len(original["trust_denials"]["entries"]) != original_len:
    raise SystemExit(
        "journal_safe_status mutated the original entries list; "
        "curator-health.json would lose evidence"
    )
if "entries_capped" in original["trust_denials"]:
    raise SystemExit("journal_safe_status wrote entries_capped onto the original")

# Printed size must stay well under the pre-fix ~40KB dump.
payload = json.dumps(slim, sort_keys=True)
if len(payload) >= 2048:
    raise SystemExit(f"journal-safe payload still large: {len(payload)} bytes")

# Missing trust_denials must not crash (review/curate error paths).
empty = mod.journal_safe_status({"healthy": False})
if "trust_denials" not in empty:
    raise SystemExit("missing trust_denials vanished instead of becoming {}")
PY
ok "1: journal_safe_status empties entries, records entries_capped=101, leaves original intact"

# --- 2. live: curator journal line is capped; health file is not ---------
# Hosted CI has no user systemd journal and no live vault health file.
# Skip that layer rather than fail the P14 batch.
if [[ "${CURATOR_JOURNAL_CAP_LIVE:-}" == "0" ]]; then
  ok "2: live layer skipped (CURATOR_JOURNAL_CAP_LIVE=0)"
  echo "OK: curator-journal-cap.test.sh"
  exit 0
fi

if ! command -v journalctl >/dev/null 2>&1; then
  ok "2: live layer skipped (no journalctl)"
  echo "OK: curator-journal-cap.test.sh"
  exit 0
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if ! systemctl --user cat "$UNIT" >/dev/null 2>&1; then
  ok "2: live layer skipped (unit $UNIT not installed)"
  echo "OK: curator-journal-cap.test.sh"
  exit 0
fi

# Pull recent curator JSON lines that carry trust_denials + dispositioned
# (the curate stdout shape). The review pass also emits trust_denials but
# its entries_capped is the shadow-review cap (200), not the curate 101.
live_json="$(
  journalctl --user -u "$UNIT" -o cat --since "2 hours ago" --no-pager 2>/dev/null \
    | python3 -c '
import json, sys
last = None
for raw in sys.stdin:
    line = raw.strip()
    if not line.startswith("{") or "trust_denials" not in line:
        continue
    if "dispositioned" not in line:
        continue
    last = line
if last is None:
    raise SystemExit(2)
print(last)
'
)" || {
  rc=$?
  if [[ $rc -eq 2 ]]; then
    ok "2: live layer skipped (no curate stdout in last 2h)"
    echo "OK: curator-journal-cap.test.sh"
    exit 0
  fi
  fail "journalctl/python parse of $UNIT stdout failed (rc=$rc)"
}

export MAX_STDOUT_BYTES
python3 - "$live_json" <<'PY' || fail "live curator stdout is not journal-safe"
import json, os, sys
line = sys.argv[1]
max_bytes = int(os.environ["MAX_STDOUT_BYTES"])
if len(line) >= max_bytes:
    raise SystemExit(
        f"live curator stdout {len(line)} bytes >= {max_bytes} (pre-fix dump is back)"
    )
status = json.loads(line)
td = status["trust_denials"]
entries = td.get("entries") or []
if entries:
    raise SystemExit(f"live stdout still carries entries: {len(entries)} items")
capped = td.get("entries_capped")
total = td.get("total")
if capped is None:
    raise SystemExit("live stdout missing entries_capped")
if total is None:
    raise SystemExit("live stdout missing total")
print(
    f"live_bytes={len(line)} entries={entries!r} "
    f"entries_capped={capped} total={total}"
)
PY
live_bytes=$(python3 -c 'import sys; print(len(sys.argv[1]))' "$live_json")
ok "2a: live curator stdout is journal-safe (${live_bytes} bytes)"

if [[ ! -f "$HEALTH" ]]; then
  ok "2b: health-file layer skipped (no $HEALTH)"
  echo "OK: curator-journal-cap.test.sh"
  exit 0
fi

python3 - "$HEALTH" "$live_json" <<'PY' || fail "health file lost the full entries list"
import json, sys
health_path, live_line = sys.argv[1], sys.argv[2]
health = json.loads(open(health_path, encoding="utf-8").read())
live = json.loads(live_line)
htd = health["trust_denials"]
ltd = live["trust_denials"]
entries = htd.get("entries") or []
if not entries:
    raise SystemExit("curator-health.json entries list is empty; doctor evidence is gone")
if len(entries) != htd.get("total"):
    raise SystemExit(
        f"health entries {len(entries)} != total {htd.get('total')}"
    )
# The live stdout cap must match the health-file total, so we know we
# compared the same run shape (capped count == full list length).
if ltd.get("entries_capped") != len(entries) and ltd.get("total") != htd.get("total"):
    raise SystemExit(
        f"live cap {ltd.get('entries_capped')} / total {ltd.get('total')} "
        f"does not match health {len(entries)} / {htd.get('total')}"
    )
print(f"health_bytes={__import__('os').path.getsize(health_path)} entries={len(entries)}")
PY
ok "2b: curator-health.json still holds the full entries list"

echo "OK: curator-journal-cap.test.sh"
