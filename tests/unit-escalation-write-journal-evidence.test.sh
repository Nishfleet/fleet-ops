#!/usr/bin/env bash
# tests/unit-escalation-write-journal-evidence.test.sh
#
# fleet-ops#2392 / ledger led-2026-08-28-manual-evidence-pinning-and-triage-
# greps-fleet-op (fleet-ops#1521 line 5): the escalation pipeline must attach
# the failing unit's last error lines to STOP-REASON automatically, so the
# senior auditor carries the failure evidence without a hand journalctl grep.
# The rule's named drill is "live writer run on a failed unit" — this test
# locks the writer's evidence shape offline (stubbed journalctl/systemctl
# on PATH):
#   1. detail.journal      = the last 5 journal lines for the failed unit
#   2. detail.journal_errors = the last N (default 5) error-priority lines
#      (syslog priority err or higher: err, crit, alert, emerg)
#   3. detail.unit          = the %i name passed in, never a placeholder
#   4. journal_errors is [] (empty array) when the unit left no
#      error-priority lines — never a missing key, never null
# Runs entirely offline; writes STOP-REASON to a scratch dir via
# UNIT_ESCALATION_AGENT_STATE so no real auditor is summoned.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
writer="$repo_root/bin/unit-escalation-write"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$writer" ]] || fail "$writer not executable"

scratch="$(mktemp -d -t escalate-evidence.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/bin"
PATH="$scratch/bin:$PATH"
export PATH

AS="$scratch/agent-state"
mkdir -p "$AS"
export UNIT_ESCALATION_AGENT_STATE="$AS"

# Fixtures: journalctl -o short-iso shaped lines, oldest -> newest.
# Fixture A has 8 lines; lines 4, 6, 8 are error-priority (err / emerg).
cat > "$scratch/fixture-a.all" <<'EOF'
2026-08-30T12:00:00.000000+00:00 netcup unit[100]: info line one
2026-08-30T12:00:01.000000+00:00 netcup unit[100]: info line two
2026-08-30T12:00:02.000000+00:00 netcup unit[100]: warning line three
2026-08-30T12:00:03.000000+00:00 netcup unit[100]: error line four
2026-08-30T12:00:04.000000+00:00 netcup unit[100]: info line five
2026-08-30T12:00:05.000000+00:00 netcup unit[100]: error line six
2026-08-30T12:00:06.000000+00:00 netcup unit[100]: info line seven
2026-08-30T12:00:07.000000+00:00 netcup unit[100]: emergency line eight
EOF
cat > "$scratch/fixture-a.errors" <<'EOF'
2026-08-30T12:00:03.000000+00:00 netcup unit[100]: error line four
2026-08-30T12:00:05.000000+00:00 netcup unit[100]: error line six
2026-08-30T12:00:07.000000+00:00 netcup unit[100]: emergency line eight
EOF

# Fixture B: clean runs only (no error-priority lines at all).
cat > "$scratch/fixture-b.all" <<'EOF'
2026-08-30T12:01:00.000000+00:00 netcup unit[200]: info line one
2026-08-30T12:01:01.000000+00:00 netcup unit[200]: info line two
2026-08-30T12:01:02.000000+00:00 netcup unit[200]: info line three
EOF
: > "$scratch/fixture-b.errors"

# Stub journalctl: honors the writer's three call shapes.
#   --user -u <unit> -n 5  --no-pager -o short-iso   -> last 5 general lines
#   --user -u <unit> -p err -n 5 --no-pager -o short-iso -> last 5 err lines
#   --user -u <unit> -n 20 --no-pager -q             -> OOM probe (no keywords)
# The fixture active is chosen by $JOURNAL_FIXTURE (a|b).
cat > "$scratch/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
fix="$JOURNAL_FIXTURE"
unit=""; p=""; n=""; q=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) p="$2"; shift 2 ;;
    -n) n="$2"; shift 2 ;;
    -q) q=1; shift ;;
    -u) unit="$2"; shift 2 ;;
    *) shift ;;
  esac
done
: "${unit:?journalctl stub: expected -u <unit>}"
n="${n:-5}"
if [ -n "$p" ]; then
  tail -n "$n" "$fix.errors"
elif [ -n "$q" ]; then
  tail -n 20 "$fix.all"
else
  tail -n "$n" "$fix.all"
fi
STUB
chmod +x "$scratch/bin/journalctl"

# Stub systemctl: no retry-absorb interference (Restart=no, zero counters) and
# non-oom result so the OOM probe stays the only oom signal source.
cat > "$scratch/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"-p Restart"*) echo "no" ;;
  *"-p NRestarts"*) echo "0" ;;
  *"-p StartLimitBurst"*) echo "0" ;;
  *"-p Result"*) echo "exit-code" ;;
  *"-p ExecMainStatus"*) echo "1" ;;
  *"-p MemoryPeak"*) echo "1024" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$scratch/bin/systemctl"

check_json() {
  # $1 = path to STOP-REASON.json, $2 = expected unit, $3 = python assert body
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, unit, body = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    doc = json.load(fh)
assert doc["reason"] == "unit-failure", doc
detail = doc["detail"]
assert detail["unit"] == unit, (detail["unit"], unit)
# The writer must ALWAYS emit an errors array in the detail.
assert isinstance(detail["journal"], list), detail
assert isinstance(detail["journal_errors"], list), detail
exec(body)  # case-specific assertions on `detail`
PY
}

# ---- Case A: mixed fixture -> journal = tail 5, journal_errors = 3 err lines ----
export JOURNAL_FIXTURE="$scratch/fixture-a"
out=$("$writer" "evidence-drill-2392a.service" 2>&1)
grep -q "wrote STOP-REASON" <<<"$out" \
  || fail "writer should write STOP-REASON for a plain failed unit (got: $out)"
check_json "$AS/STOP-REASON.json" "evidence-drill-2392a.service" \
  'assert detail["journal"] == open("'$scratch'/fixture-a.all", encoding="utf-8").read().splitlines()[-5:], detail["journal"]
assert detail["journal_errors"] == open("'$scratch'/fixture-a.errors", encoding="utf-8").read().splitlines()[-5:], detail["journal_errors"]
assert any("error line six" in l for l in detail["journal_errors"]), detail["journal_errors"]
assert not any("info line one" in l for l in detail["journal_errors"]), detail["journal_errors"]'
ok "Case A: journal=last 5 lines, journal_errors=last error-priority lines, unit=%i name"

# ---- Case B: no error-priority lines -> journal_errors == [] (never null/string) ----
export JOURNAL_FIXTURE="$scratch/fixture-b"
out=$("$writer" "evidence-drill-2392b.service" 2>&1)
grep -q "wrote STOP-REASON" <<<"$out" \
  || fail "writer should write STOP-REASON for a clean-log failed unit (got: $out)"
check_json "$AS/STOP-REASON.json" "evidence-drill-2392b.service" \
  'assert detail["journal_errors"] == [], detail["journal_errors"]
assert detail["journal"] == open("'$scratch'/fixture-b.all", encoding="utf-8").read().splitlines()[-5:], detail["journal"]'
ok "Case B: journal_errors=[] when the unit left no error-priority lines"

echo
echo "unit-escalation-write: journal evidence-pinning proven (fleet-ops#2392, ledger 2026-08-28)"