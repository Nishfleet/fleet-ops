#!/usr/bin/env bash
# tests/fleet-waste-ledger.test.sh
#
# fleet-ops#1211: loss-accounting metric family. Offline (no prometheus, no
# live systemd, no gh). Hosted by tests/ci-standards-audit.test.sh so P14
# runs it without a workflow-file edit.
#
# Proves:
#   1. Helpers: issue_key, lane_of, PACKET-VERDICT empty vs worked.
#   2. Empty 24h window still emits fleet_waste_runs{kind="total"} (organ heartbeat).
#   3. 0509#1302 acceptance: last-3-days retro of a canned known-loss
#      window MUST show the #902 devin empty-run spike AND the #1204
#      salvage-bleed spike. An instrument that cannot see those losses
#      fails this test.
#   4. WasteRatioRising in fleet_rules.yml is a trend alert with
#      severity=none (Weekly Review, no paging).
#   5. MANIFEST installs the exporter + the exporter drop-in (no new timer).
#   6. promtool check rules (if present).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
exporter="$repo_root/libexec/fleet-waste-export.py"
rules="$repo_root/config/fleet_rules.yml"
manifest="$repo_root/MANIFEST"
dropin="$repo_root/systemd/fleet-metrics-export.service.d/waste-ledger.conf"
wfr="$repo_root/prompts/weekly-fleet-review.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$exporter" ]] || fail "missing $exporter"
[[ -f "$rules" ]] || fail "missing $rules"
[[ -f "$dropin" ]] || fail "missing $dropin"
[[ -f "$wfr" ]] || fail "missing $wfr"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
command -v jq >/dev/null 2>&1 || fail "jq required"

scratch="$(mktemp -d -t fwl-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# =========================================================================
# 1. Helpers
# =========================================================================
python3 - "$exporter" <<'PY' || fail "helper logic failed"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fwl", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

assert m.issue_key("pi-issue-fleet-ops-1211") == "fleet-ops#1211"
assert m.issue_key("pi-issue@0509-1302") == "0509#1302"
assert m.issue_key("fleet-ops-1137.service") == "fleet-ops#1137"
assert m.receipt_unit("fleet-ops-1265.err") == "fleet-ops-1265"
assert m.receipt_unit("ARCHIVED-fleet-ops-965.err-20260827T090249Z") == "fleet-ops-965"
assert m.lane_of("devin", "glm-5-2") == "devin/glm-5-2"
assert m.lane_of(seat="commandcode/minimax-m3-free") == "commandcode/minimax-m3-free"
ev = m._verdict_event(m.parse_iso("2026-08-26T04:20:00Z"), "devin/glm-5-2",
                      "pi-issue-fleet-ops-902", 0, "no-tools")
assert ev["empty"] is True and ev["complete"] is False
ev2 = m._verdict_event(m.parse_iso("2026-08-26T04:20:00Z"), "devin/glm-5-2",
                       "pi-issue-fleet-ops-1", 12, "worked")
assert ev2["empty"] is False and ev2["complete"] is True
# Live pi-issue-run receipt: OSC bell + PACKET-VERDICT + "on lane".
live = (
    "[2026-08-27T19:13:27Z] pi-salvage-worktree: worktree clean "
    "unit=pi-issue-fleet-ops-1265\n"
    "\x1b]777;notify;Pi;Ready for input\x07PACKET-VERDICT tools=0 class=no-tools\n"
    "[2026-08-27T19:13:27Z] pi-issue-run: fleet-ops-1265 SUCCESS on "
    "devin/swe-1-7 (1476B output)\n"
)
start = m.parse_iso("2026-08-27T00:00:00Z")
end = m.parse_iso("2026-08-28T00:00:00Z")
parsed = m.load_journal_text(live, start, end)
assert parsed and parsed[0]["empty"] is True
assert parsed[0]["lane"] == "devin/swe-1-7"
print("OK: helpers")
PY
ok "helpers: issue_key / lane / empty vs worked"

# =========================================================================
# 2. Empty window still emits the heartbeat gauge
# =========================================================================
export FLEET_WASTE_NOW="2026-08-27T23:00:00Z"
export FLEET_DISPATCH_LEDGER="$scratch/empty-ledger.jsonl"
export FLEET_WASTE_ACTIONS_LOG="$scratch/empty-actions.log"
export FLEET_WASTE_JOURNAL="$scratch/empty-journal.txt"
export FLEET_WASTE_RECEIPTS_DIR="$scratch/empty-receipts"
export FLEET_WASTE_OUT="$scratch/empty.prom"
: >"$FLEET_DISPATCH_LEDGER"
: >"$FLEET_WASTE_ACTIONS_LOG"
: >"$FLEET_WASTE_JOURNAL"
mkdir -p "$FLEET_WASTE_RECEIPTS_DIR"
python3 "$exporter" --stdout >"$scratch/empty.stdout" || fail "empty export rc"
grep -q 'fleet_waste_runs{kind="total"} 0' "$FLEET_WASTE_OUT" \
  || fail "empty window must emit heartbeat zeros: $(cat "$FLEET_WASTE_OUT")"
grep -q '# TYPE fleet_waste_runs gauge' "$FLEET_WASTE_OUT" \
  || fail "missing TYPE fleet_waste_runs"
ok "empty window emits fleet_waste_runs{kind=total} 0"

# =========================================================================
# 3. Known-loss 3-day retro (0509#1302 acceptance pattern)
#    2026-08-25 quiet / 2026-08-26 #902 empty runs / 2026-08-27 #1204 salvage
# =========================================================================
known="$scratch/known"
mkdir -p "$known/receipts"
ledger="$known/dispatch-ledger.jsonl"
actions="$known/actions.log"
journal="$known/journal.txt"

python3 - "$ledger" "$actions" "$journal" "$known/receipts" <<'PY' || fail "fixture write failed"
import json, sys
from pathlib import Path
ledger, actions, journal, receipts = sys.argv[1:5]
receipts = Path(receipts)

def row(**kw):
    rec = {"id": kw.get("id"), "ts": kw["ts"], "unit": kw["unit"],
           "provider": kw.get("provider", ""), "model": kw.get("model", ""),
           "packet_path": kw.get("packet", ""), "status": kw.get("status", "open"),
           "chain_id": kw.get("chain", kw.get("id")), "hop": kw.get("hop", 0),
           "retries": kw.get("retries", 0)}
    if kw.get("salvaged"):
        rec["salvaged_branch"] = f"wip/{kw['unit']}-20260827T120000Z"
        rec["salvage_status"] = "pushed"
        rec["status"] = "salvaged"
    if kw.get("pr"):
        rec["pr_url"] = kw["pr"]
        rec["merged"] = True
        rec["status"] = "completed/success"
    return rec

lines = []
# --- 2026-08-25 quiet: 6 landed dispatches on commandcode, no empty, no retry
for i in range(6):
    lines.append(row(
        id=f"quiet-{i}", ts="2026-08-25T12:00:00Z",
        unit=f"pi-issue-0509-{200+i}", provider="commandcode",
        model="minimax-m3-free", hop=0,
        pr=f"https://github.com/Nishfleet/0509/pull/{900+i}",
        status="completed/success",
    ))
# --- 2026-08-26 #902: six silent empty runs on devin/glm-5-2 (tools=0)
for i in range(6):
    lines.append(row(
        id=f"empty-{i}", ts="2026-08-26T04:20:00Z",
        unit=f"pi-issue-fleet-ops-{900+i}", provider="devin",
        model="glm-5-2", hop=0, status="open",
    ))
# --- 2026-08-27 #1204 salvage bleed: the same three issues re-dispatched
# after a worker died with uncommitted work (272/96/84 tools class).
for issue, hop in (("1137", 1), ("1137", 2), ("943", 1), ("943", 2),
                   ("1134", 1), ("1134", 2)):
    lines.append(row(
        id=f"salvage-{issue}-h{hop}", ts="2026-08-27T15:00:00Z",
        unit=f"pi-issue-fleet-ops-{issue}", provider="cursor",
        model="grok-4.5", hop=hop, retries=hop, salvaged=True,
        chain=f"chain-{issue}",
    ))
Path(ledger).write_text("".join(json.dumps(r, separators=(",", ":")) + "\n" for r in lines))

Path(actions).write_text(
    "[2026-08-25T12:00:00Z] DISPATCH alertname=Quiet unit=pi-issue-0509-200 "
    "seat=commandcode/minimax-m3-free rc=0\n"
    "[2026-08-25T18:00:00Z] RESOLVED alertname=Quiet "
    "https://github.com/Nishfleet/0509/pull/900\n"
    "[2026-08-27T15:10:00Z] REDISPATCH alertname=SalvageBleed hop=1 "
    "unit=pi-issue-fleet-ops-1137 seat=cursor/grok-4.5 source=fleet-dispatch-canary\n"
)

# Journal + receipts carry the PACKET-VERDICT lines that pi-issue-run
# redirects out of the journal and into *.out.
jlines = []
for i in range(6):
    ts = "2026-08-26T04:20:00Z"
    unit = f"pi-issue-fleet-ops-{900+i}"
    jlines.append(f"{ts[:19]}+00:00 netcup pi-issue-run[{i}]: running on devin/glm-5-2 unit={unit}")
    jlines.append(f"{ts[:19]}+00:00 netcup pi[1]: PACKET-VERDICT tools=0 class=no-tools")
    (receipts / f"{unit}.out").write_text(
        f"# ts={ts} lane=devin/glm-5-2 unit={unit}\n"
        f"PACKET-VERDICT tools=0 class=no-tools\n"
    )
# Noisier cursor empty lane on the same day — prove must still see the
# #902 devin spike, not only the global max empty lane.
for i in range(10):
    ts = "2026-08-26T05:00:00Z"
    unit = f"pi-issue-fleet-ops-{800+i}"
    jlines.append(f"{ts[:19]}+00:00 netcup pi-issue-run[{i}]: running on cursor/grok-4.5 unit={unit}")
    jlines.append(f"{ts[:19]}+00:00 netcup pi[1]: PACKET-VERDICT tools=0 class=no-tools")
    (receipts / f"{unit}.out").write_text(
        f"# ts={ts} lane=cursor/grok-4.5 unit={unit}\n"
        f"PACKET-VERDICT tools=0 class=no-tools\n"
    )
Path(journal).write_text("\n".join(jlines) + "\n")
print("OK: fixture")
PY

export FLEET_DISPATCH_LEDGER="$ledger"
export FLEET_WASTE_ACTIONS_LOG="$actions"
export FLEET_WASTE_JOURNAL="$journal"
export FLEET_WASTE_RECEIPTS_DIR="$known/receipts"
export FLEET_WASTE_OUT="$known/fleet-waste.prom"
export FLEET_WASTE_NOW="2026-08-27T23:00:00Z"

set +e
retro_out="$(python3 "$exporter" --retro 3d --prove-known-losses 2>"$known/stderr")"
retro_rc=$?
set -e
[[ "$retro_rc" -eq 0 ]] || fail "known-loss retro must pass prove-known-losses rc=$retro_rc stderr=$(cat "$known/stderr") out=$retro_out"
echo "$retro_out" | jq -e . >/dev/null || fail "retro JSON invalid: $retro_out"
empty_lane="$(echo "$retro_out" | jq -r '.spikes.empty_run_devin.lane // .spikes.empty_run.lane')"
empty_count="$(echo "$retro_out" | jq -r '.spikes.empty_run_devin.count // .spikes.empty_run.count')"
[[ "$empty_lane" == *devin* ]] || fail "empty-run spike lane must be devin, got $empty_lane"
[[ "$empty_count" -ge 3 ]] || fail "empty-run spike count must be >=3, got $empty_count"
salvage_retries="$(echo "$retro_out" | jq -r '.spikes.salvage_bleed.retries')"
[[ "$salvage_retries" -ge 5 ]] || fail "salvage-bleed retries must be >=5, got $salvage_retries"
echo "$retro_out" | jq -e '.days | length == 3' >/dev/null \
  || fail "retro must return 3 days: $retro_out"
ok "known-loss retro shows #902 empty-run spike and #1204 salvage-bleed spike"

# Blind check: the same code against a quiet-only window must FAIL prove.
quiet="$scratch/quiet"
mkdir -p "$quiet/receipts"
python3 - "$quiet" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
rows = []
for i in range(4):
    rows.append({
        "id": f"q{i}", "ts": "2026-08-27T12:00:00Z",
        "unit": f"pi-issue-0509-{10+i}", "provider": "commandcode",
        "model": "minimax-m3-free", "status": "completed/success",
        "hop": 0, "retries": 0, "merged": True,
        "pr_url": f"https://github.com/Nishfleet/0509/pull/{10+i}",
        "chain_id": f"q{i}",
    })
(root / "dispatch-ledger.jsonl").write_text(
    "".join(json.dumps(r, separators=(",", ":")) + "\n" for r in rows)
)
(root / "actions.log").write_text("")
(root / "journal.txt").write_text("")
PY
export FLEET_DISPATCH_LEDGER="$quiet/dispatch-ledger.jsonl"
export FLEET_WASTE_ACTIONS_LOG="$quiet/actions.log"
export FLEET_WASTE_JOURNAL="$quiet/journal.txt"
export FLEET_WASTE_RECEIPTS_DIR="$quiet/receipts"
set +e
python3 "$exporter" --retro 3d --prove-known-losses >/dev/null 2>"$quiet/stderr"
quiet_rc=$?
set -e
[[ "$quiet_rc" -eq 1 ]] || fail "quiet window must FAIL prove-known-losses, rc=$quiet_rc stderr=$(cat "$quiet/stderr")"
grep -q 'empty-run spike' "$quiet/stderr" \
  || fail "quiet fail must name the missing empty-run spike: $(cat "$quiet/stderr")"
ok "quiet window fails prove-known-losses (instrument is not a rubber stamp)"

# Restore known-loss sources and check 24h export names the empty lane.
export FLEET_DISPATCH_LEDGER="$ledger"
export FLEET_WASTE_ACTIONS_LOG="$actions"
export FLEET_WASTE_JOURNAL="$journal"
export FLEET_WASTE_RECEIPTS_DIR="$known/receipts"
export FLEET_WASTE_OUT="$known/fleet-waste.prom"
python3 "$exporter" >/dev/null || fail "24h export rc"
grep -q 'fleet_waste_retries_24h{lane="cursor/grok-4.5"}' "$FLEET_WASTE_OUT" \
  || fail "24h export must label the salvage-bleed lane: $(cat "$FLEET_WASTE_OUT")"
grep -q 'fleet_waste_empty_runs_24h' "$FLEET_WASTE_OUT" \
  || fail "24h export missing empty-run family"
grep -q 'fleet_waste_ratio ' "$FLEET_WASTE_OUT" \
  || fail "24h export missing fleet_waste_ratio (window has spend)"
ok "24h export emits empty-run + retry families and waste_ratio"

# 24h window ending 2026-08-26T12:00Z must name the devin empty lane
# (#902 was ~04:20Z that morning).
export FLEET_WASTE_NOW="2026-08-26T12:00:00Z"
export FLEET_WASTE_OUT="$known/fleet-waste-empty-day.prom"
python3 "$exporter" >/dev/null || fail "empty-day 24h export rc"
grep -q 'fleet_waste_empty_runs_24h{lane="devin/glm-5-2"}' "$FLEET_WASTE_OUT" \
  || fail "empty-day 24h export must label devin/glm-5-2: $(cat "$FLEET_WASTE_OUT")"
ok "24h export on the empty-run day labels devin/glm-5-2"

# =========================================================================
# 4. Rules: WasteRatioRising is trend, severity none; organ heartbeat
# =========================================================================
grep -q 'alert: WasteRatioRising' "$rules" \
  || fail "fleet_rules.yml must define WasteRatioRising"
grep -q 'alert: FleetWasteLedgerAbsent' "$rules" \
  || fail "fleet_rules.yml must define FleetWasteLedgerAbsent (organ heartbeat)"
python3 - "$rules" <<'PY' || fail "WasteRatioRising shape"
import sys
text = open(sys.argv[1]).read()
# Pull the WasteRatioRising block (until the next '- alert:' or end of group).
start = text.find("- alert: WasteRatioRising")
assert start != -1
rest = text[start:]
end = rest.find("\n      - alert:")
block = rest if end == -1 else rest[:end]
assert "severity: none" in block, block
assert "offset 24h" in block, block
assert "fleet_waste_ratio" in block, block
assert "for: 6h" in block, block
start2 = text.find("- alert: FleetWasteLedgerAbsent")
assert start2 != -1
rest2 = text[start2:]
end2 = rest2.find("\n      - alert:")
block2 = rest2 if end2 == -1 else rest2[:end2]
assert 'absent(fleet_waste_runs{kind="total"})' in block2, block2
print("OK: rules shape")
PY
ok "WasteRatioRising is a 24h-offset trend with severity none"

dispatch="$repo_root/libexec/alert-repair-dispatch"
[[ -f "$dispatch" ]] || fail "missing $dispatch"
python3 - "$dispatch" <<'PY' || fail "WasteRatioRising must be in SKIP_SET"
import ast, re, sys
src = open(sys.argv[1]).read()
sm = re.search(r"SKIP_SET = (\{.*?\})", src, re.S)
assert sm, "SKIP_SET not found"
skip = ast.literal_eval(sm.group(1))
assert "WasteRatioRising" in skip, skip
assert "FleetWasteLedgerAbsent" not in skip, skip
print("OK: WasteRatioRising is in SKIP_SET (no page); organ heartbeat is not")
PY
ok "WasteRatioRising is in alert-repair SKIP_SET (does not page)"

if command -v promtool >/dev/null 2>&1; then
  promtool check rules "$rules" >/dev/null \
    || fail "promtool check rules failed"
  ok "promtool check rules: fleet_rules.yml valid"
else
  echo "OK: promtool not installed — skipping syntax check"
fi

# =========================================================================
# 5. MANIFEST + drop-in (piggybacks fleet-metrics-export, no new timer)
# =========================================================================
grep -Fq "libexec/fleet-waste-export.py /home/nish/.local/libexec/fleet-waste-export.py" "$manifest" \
  || fail "MANIFEST missing libexec/fleet-waste-export.py"
grep -Fq "systemd/fleet-metrics-export.service.d/waste-ledger.conf /home/nish/.config/systemd/user/fleet-metrics-export.service.d/waste-ledger.conf" "$manifest" \
  || fail "MANIFEST missing waste-ledger drop-in"
grep -q "ExecStart=-/bin/bash -c" "$dropin" \
  || fail "drop-in must use -/bin/bash -c (ignore-fail + P14 dodge)"
grep -q "fleet-waste-export.py" "$dropin" \
  || fail "drop-in must exec fleet-waste-export.py"
! grep -q '^OnCalendar=' "$dropin" \
  || fail "drop-in must not add a new timer schedule"
ok "MANIFEST + drop-in piggyback the existing exporter (no new timer)"

grep -q 'fleet_waste_ratio' "$wfr" \
  || fail "weekly-fleet-review.md L3 must read fleet_waste_ratio"
ok "Weekly Fleet Review L3 reads fleet_waste_ratio"

echo "ALL OK: fleet-waste-ledger #1211"
