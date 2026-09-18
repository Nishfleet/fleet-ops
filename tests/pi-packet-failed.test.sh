#!/usr/bin/env bash
# tests/pi-packet-failed.test.sh
#
# fleet-ops#5444: pi-packet-failed@ used to run a single `logger` line — the
# terminal state of a retry-exhausted packet landed in a syslog nobody
# reads. fleet-ops#5456 folded the handler into the escalation chain: it
# keeps the syslog line, then writes a structured STOP-REASON
# (reason=packet-exhausted, source=pi-packet-failed) through
# unit-escalation-write, and stop-escalation.path -> stop-escalation-dispatch
# terminates the chain in an ACTION (hop+1 relaunch under the hop cap, or
# the agent-ready [unit-death] issue + findings-ledger carried_over row +
# LOUD triage line). The dispatcher owns the #5444 records now; they are
# asserted in tests/stop-escalation-dispatch.test.sh. This file pins the
# handler's half: the kept syslog line, the %i unit-name mapping (bare
# instance vs full unit name), the STOP-REASON content, and the wiring.
#
# Hermetic phases put fake systemctl/journalctl/logger FIRST IN PATH (the
# writer calls them by name, not via env seams) and point the writer's
# state at scratch via UNIT_ESCALATION_AGENT_STATE / UNIT_ESCALATION_STOP_REASON
# / UNIT_ESCALATION_RECURRENCE_STATE so nothing touches the real agent-state
# dir (CI runners cannot write /home/nish — fleet-ops#5456 P14 failure).
#
# The drill phase (stub unit) runs a REAL systemd --user end-to-end when
# available and self-skips otherwise: a systemd-run stub fails with
# OnFailure=pi-packet-failed-drill@<unit>, a runtime-dir template invokes
# the repo handler, and the fake LOGGER + handler stderr prove the chain
# fired. The stub is named live-dummy* so BOTH the global 10-escalate.conf
# unit-escalation@ fire and the handler's own writer call are excluded
# (fleet-ops#4266 convention) — the drill never writes a real STOP-REASON
# and never summons a real auditor. The write path itself is covered by the
# hermetic phases; the dispatcher end is drilled by fleet-resilience-drill.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-packet-failed"
unit_file="$repo_root/systemd/pi-packet-failed@.service"
runner="$repo_root/bin/pi-systemd-run"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
bash -n "$bin" || fail "$bin fails bash -n"
bash -n "$runner" || fail "$runner fails bash -n"

# --help is the help-first contract for new bin/ files.
help_out="$("$bin" --help 2>&1)"
grep -q 'usage: pi-packet-failed' <<<"$help_out" || fail "--help must print usage"
ok "--help prints usage"

# --- wiring pins ------------------------------------------------------------
grep -qF 'ExecStart=/bin/bash -c '\''exec /home/nish/.local/bin/pi-packet-failed %i'\''' "$unit_file" \
    || fail "pi-packet-failed@.service must ExecStart the handler (runner-safe /bin/bash -c exec shape, fleet-ops#154)"
grep -qF 'pi-packet-failed@${unit}.service.service' "$runner" \
    || fail "pi-systemd-run OnFailure must include pi-packet-failed@<unit> (transient path)"
grep -qF 'unit-escalation@${unit}.service.service' "$runner" \
    || fail "pi-systemd-run OnFailure must keep unit-escalation@ (auditor rail)"
grep -Fxq 'bin/pi-packet-failed /home/nish/.local/bin/pi-packet-failed' "$manifest" \
    || fail "MANIFEST must install bin/pi-packet-failed"
ok "wiring: unit ExecStart, pi-systemd-run OnFailure, MANIFEST"

# --- hermetic scaffolding ----------------------------------------------------
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# mk_fakes <dir> <nrestarts> — fake systemctl answers `show -p <Prop> --value`
# per property (burst exhausted when <nrestarts> >= 3), fake journalctl prints
# five canned lines, fake logger records its argv.
mk_fakes() {
    local d="$1" nr="$2"
    mkdir -p "$d"
    cat >"$d/systemctl" <<EOF
#!/usr/bin/env bash
prop=""
prev=""
for a in "\$@"; do
    if [[ "\$prev" == "-p" ]]; then prop="\$a"; fi
    prev="\$a"
done
case "\$prop" in
    NRestarts) printf '%s\n' '$nr' ;;
    StartLimitBurst) printf '3\n' ;;
    Restart) printf 'on-failure\n' ;;
    Result) printf 'failure\n' ;;
    ExecMainStatus) printf '1\n' ;;
    MemoryPeak) printf '123456789\n' ;;
    Environment) printf 'HOME=/home/nish PI_DEADMAN_DELIVERABLE=/scratch/expected.md\n' ;;
    *) printf '\n' ;;
esac
exit 0
EOF
    cat >"$d/journalctl" <<'EOF'
#!/usr/bin/env bash
printf 'line one of the dead packet\nline two\nline three\nline four\nline five (last)\n'
EOF
    cat >"$d/logger" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/logger.calls"
EOF
    chmod +x "$d/systemctl" "$d/journalctl" "$d/logger"
}

# run_handler <fakes> <state-dir> <instance> [extra env...]
run_handler() {
    local d="$1" st="$2" inst="$3"; shift 3
    mkdir -p "$st"
    env PATH="$d:$PATH" LOGGER="$d/logger" \
        UNIT_ESCALATION_AGENT_STATE="$st" \
        UNIT_ESCALATION_STOP_REASON="$st/STOP-REASON.json" \
        UNIT_ESCALATION_RECURRENCE_STATE="$st/unit-escalation-recurrence.json" \
        "$@" "$bin" "$inst"
}


# --- Phase A: burst-exhausted packet -> syslog line kept ---------------------
# Glue sweep 2026-09-18: the STOP-REASON writer and its SENIOR-AUDITOR
# dispatcher were deleted. What survives is the syslog record and the fact
# that the exhausted packet's unit is left in --state=failed, where
# fleet-heartbeat-tier1 block 4 (the hourly failed-units pass) picks it up.
fa="$scratch/fa"; sta="$scratch/sta"
mk_fakes "$fa" 3
run_handler "$fa" "$sta" drillpkt \
    || fail "handler must exit 0"

grep -q 'packet drillpkt exhausted retries' "$fa/logger.calls" \
    || fail "syslog line must be kept: $(cat "$fa/logger.calls" 2>/dev/null)"
grep -q 'reason=packet-exhausted' "$fa/logger.calls" \
    || fail "syslog line must carry the reason: $(cat "$fa/logger.calls" 2>/dev/null)"
grep -q 'unit pi-packet@drillpkt.service' "$fa/logger.calls" \
    || fail "syslog line must name the real unit: $(cat "$fa/logger.calls" 2>/dev/null)"
ok "syslog line preserved and names the real unit"

[[ -f "$sta/STOP-REASON.json" ]] \
    && fail "the deleted escalation writer must not be resurrected"
ok "no STOP-REASON written (escalation tower deleted)"

# --- Phase B: full unit name passes through unchanged -------------------------
# pi-systemd-run transients list pi-packet-failed@<unit>.service in OnFailure,
# so %i already carries the unit suffix; prefixing pi-packet@ again would
# double-name the relaunch target.
fb="$scratch/fb"; stb="$scratch/stb"
mk_fakes "$fb" 3
run_handler "$fb" "$stb" "mypkt-abc123.service" \
    || fail "handler must exit 0 for a full unit name"
grep -q 'unit mypkt-abc123.service' "$fb/logger.calls" \
    || fail "full unit name must pass through unchanged: $(cat "$fb/logger.calls" 2>/dev/null)"
ok "full unit name %i maps to itself (no double pi-packet@ prefix)"

# --- Phase D: missing arg fails ------------------------------------------------
set +e
"$bin" >"$scratch/noarg.out" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "missing instance arg must fail"
ok "missing arg exits non-zero"

# --- Phase E: live drill with a stub unit (skips without systemd --user) ------
# A real systemd chain: a stub unit fails -> OnFailure= fires
# pi-packet-failed-drill@<stub> -> the runtime template runs the repo handler.
# The stub is live-dummy* so the global escalation drop-in AND the handler's
# writer call both exclude it (fleet-ops#4266): the drill proves the wiring
# fires and the handler runs clean, without writing a real STOP-REASON or
# summoning an auditor. Probe = `list-units` works: `is-system-running`
# exits non-zero merely for "degraded" (any failed unit), the norm here.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if command -v systemctl >/dev/null 2>&1 && command -v systemd-run >/dev/null 2>&1 \
   && systemctl --user list-units --no-legend >/dev/null 2>&1 \
   && [[ -d "$XDG_RUNTIME_DIR" ]]; then
    ts="$(date -u +%s)"
    dstub="live-dummy-pf$ts"                    # the failing stub unit
    dtmpl="$XDG_RUNTIME_DIR/systemd/user/pi-packet-failed-drill@.service"
    fd6="$scratch/fd6"; std6="$scratch/std6"
    mkdir -p "$fd6" "$std6" "$(dirname "$dtmpl")"
    cat >"$fd6/logger" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fd6/logger.calls"
EOF
    chmod +x "$fd6/logger"
    cat >"$dtmpl" <<EOF
[Unit]
Description=drill: pi-packet-failed handler for stub unit %i (fleet-ops#5456)

[Service]
Type=oneshot
Environment=HOME=$HOME
Environment=LOGGER=$fd6/logger
Environment=UNIT_ESCALATION_AGENT_STATE=$std6
Environment=UNIT_ESCALATION_STOP_REASON=$std6/STOP-REASON.json
Environment=UNIT_ESCALATION_RECURRENCE_STATE=$std6/unit-escalation-recurrence.json
ExecStart=$bin %i
StandardOutput=file:$std6/handler.stdout
StandardError=file:$std6/handler.stderr
EOF
    systemctl --user daemon-reload
    # The stub fails once (Restart=no via transient default). No --collect:
    # the handler reads the dead stub's properties, so the unit object must
    # still be loaded when OnFailure runs. reset-failed in cleanup removes it.
    systemd-run --user --unit="$dstub" \
        --property="OnFailure=pi-packet-failed-drill@${dstub}.service.service" \
        -- /bin/false >/dev/null 2>&1 || true
    handler_unit="pi-packet-failed-drill@${dstub}.service.service"
    # Wait (bounded) for the handler to run: the fake logger's calls file is
    # the sink. Poll the file, not the unit state — on a slow runner the
    # unit can linger after the write.
    for _ in $(seq 1 60); do
        [[ -f "$fd6/logger.calls" ]] && break
        sleep 1
    done
    grep -q "packet $dstub.service exhausted retries" "$fd6/logger.calls" 2>/dev/null \
        || fail "drill: syslog line missing — $dstub failure never reached the handler (stderr: $(cat "$std6/handler.stderr" 2>/dev/null | tail -4))"
    # Glue sweep 2026-09-18: the writer and its exclusion list were deleted
    # with the escalation tower, so the drill is hermetic by construction —
    # the handler only records. Assert it stayed a recorder.
    grep -q "left in --state=failed" "$std6/handler.stderr" \
        || fail "drill: handler must only record (stderr: $(cat "$std6/handler.stderr" 2>/dev/null | tail -4))"
    [[ -f "$std6/STOP-REASON.json" ]] \
        && fail "drill: live-dummy stub must never write a STOP-REASON"
    # Cleanup: stub + handler instance and the runtime template.
    systemctl --user reset-failed "$dstub.service" "$handler_unit" >/dev/null 2>&1 || true
    rm -f "$dtmpl"
    systemctl --user daemon-reload
    ok "live drill: stub failure -> handler -> syslog line, writer exclusion holds"
else
    echo "SKIP: live drill (no functional systemd --user here)"
fi

echo "ALL OK: pi-packet-failed (fleet-ops#5444 fold, fleet-ops#5456)"
