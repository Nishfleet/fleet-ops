#!/usr/bin/env bash
# tests/pi-intake-repair-verdict.test.sh
#
# fleet-ops#6034: the repair unit's TimeoutStartSec stays 1800, StartLimit
# stays 21600/2, and an output-only ExecStopPost writes
# INTAKE-REPAIR-VERDICT with elapsed/budget so a near-timeout run is
# readable in the journal. The 2026-09-18 rail collapse deleted
# bin/pi-intake-repair-run; this pin forbids restoring it. PACKET-VERDICT
# belongs to the agent, not this unit.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

unit="$repo_root/systemd/pi-intake-repair@.service"
[[ -f "$unit" ]] || fail "missing $unit"

grep -qx 'TimeoutStartSec=1800' "$unit" \
    || fail "TimeoutStartSec must stay 1800 (orchestrator sweep: no 2700s bump)"
if grep -qE 'TimeoutStartSec=2700|budget=2700s' "$unit"; then
    fail "unit still carries a 2700s timeout or budget — the bump is refused"
fi
ok "TimeoutStartSec=1800; no 2700s bump"

grep -qx 'StartLimitIntervalSec=21600' "$unit" \
    || fail "StartLimitIntervalSec must stay 21600 (fleet-ops#5036)"
grep -qx 'StartLimitBurst=2' "$unit" \
    || fail "StartLimitBurst must stay 2 (raising the burst re-wedges)"
ok "StartLimitIntervalSec=21600 StartLimitBurst=2 unchanged"

exec_start=$(grep '^ExecStart=' "$unit" || true)
[[ "$exec_start" == *'exec pi --print'* ]] \
    || fail "ExecStart must keep exec pi --print (the unit IS the worker)"
[[ "$exec_start" == *'--model worker-cheap'* ]] \
    || fail "ExecStart must keep --model worker-cheap"
if grep -q 'pi-intake-repair-run' <<<"$exec_start"; then
    fail "ExecStart must not resurrect the deleted pi-intake-repair-run wrapper"
fi
[[ ! -e "$repo_root/bin/pi-intake-repair-run" ]] \
    || fail "bin/pi-intake-repair-run must stay deleted (rail collapse ca33faa96)"
ok "ExecStart is exec pi --print; wrapper stays gone"

grep -qx 'RuntimeDirectory=pi-intake-repair-%i' "$unit" \
    || fail "RuntimeDirectory=pi-intake-repair-%i missing (start stamp lives there)"
grep -q 'ExecStartPre=/bin/sh -c .*RUNTIME_DIRECTORY/start' "$unit" \
    || fail "ExecStartPre must stamp \$RUNTIME_DIRECTORY/start"
ok "start stamp via RuntimeDirectory + ExecStartPre"

post=$(grep '^ExecStopPost=' "$unit" || true)
[[ -n "$post" ]] || fail "ExecStopPost missing"
[[ "$post" == ExecStopPost=-/bin/sh\ -c\ * ]] \
    || fail "ExecStopPost must be output-only (leading '-') so it cannot change exit/TERM Result, got: $post"
grep -q 'INTAKE-REPAIR-VERDICT' "$unit" \
    || fail "ExecStopPost must emit INTAKE-REPAIR-VERDICT"
grep -q 'elapsed=$${elapsed}s' "$unit" \
    || fail "elapsed must be shell-expanded (\$\${elapsed} so systemd does not eat it)"
grep -q 'budget=1800s' "$unit" \
    || fail "budget=1800s missing — must match TimeoutStartSec=1800"
grep -q 'result=$$SERVICE_RESULT' "$unit" \
    || fail "verdict must carry systemd SERVICE_RESULT"
grep -q 'repo=%i' "$unit" \
    || fail "verdict must name the instance as repo=%i"
if grep -E '^(ExecStart|ExecStartPre|ExecStopPost)=' "$unit" | grep -q 'PACKET-VERDICT'; then
    fail "Exec* lines must not emit PACKET-VERDICT (belongs to the agent)"
fi
ok "output-only INTAKE-REPAIR-VERDICT with elapsed/budget=1800s/result"

# Hermetic drill of the same $$ -> $ payload: a 3-second fake clock and a
# start stamp 3 seconds earlier must print elapsed=3s without touching
# stdout, and must not change the caller's exit code.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
echo 1000 >"$scratch/start"
cat >"$scratch/date" <<'EOF'
#!/bin/sh
echo 1003
EOF
chmod +x "$scratch/date"
payload=$(sed -n "s/^ExecStopPost=-\\/bin\\/sh -c '//p" "$unit" | sed "s/'$//")
[[ -n "$payload" ]] || fail "could not extract ExecStopPost -c payload"
decoded=${payload//\$\$/\$}
decoded=${decoded//\%i/fleet-ops}
set +e
out=$(
    PATH="$scratch:$PATH" \
    RUNTIME_DIRECTORY="$scratch" \
    SERVICE_RESULT=timeout \
    EXIT_STATUS=TERM \
    EXIT_CODE=killed \
    /bin/sh -c "$decoded" 2>"$scratch/err" >/dev/null
)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "decoded ExecStopPost must exit 0 (output-only), got $rc"
[[ -z "$out" ]] || fail "verdict leaked to stdout: $out"
grep -Fxq 'INTAKE-REPAIR-VERDICT repo=fleet-ops elapsed=3s budget=1800s result=timeout exit=TERM code=killed' \
    "$scratch/err" \
    || fail "decoded verdict mismatch: $(cat "$scratch/err")"
ok "decoded ExecStopPost: elapsed=3s on stderr, exit 0, stdout empty"

echo "all pi-intake-repair verdict checks passed"
