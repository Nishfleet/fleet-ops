#!/usr/bin/env bash
# tests/pi-packet-failed.test.sh
#
# fleet-ops#5444: pi-packet-failed@ used to run a single `logger` line — the
# terminal state of a retry-exhausted packet landed in a syslog nobody
# reads. The handler now writes four durable records: the syslog line
# (kept), a LOUD [PI-PACKET-FAILED] triage line, a findings-ledger row
# (source_organ=pi-packet, disposition=carried_over), and — when the failed
# unit carried PI_DEADMAN_DELIVERABLE (pi-systemd-run --deliverable) — an
# agent-ready fleet-ops issue via fleet-issue-file so the packet re-enters
# the queue.
#
# Hermetic phases use fake systemctl/journalctl/logger/fleet-issue-file and
# scratch triage/ledger files. The drill phase (stub unit) runs a REAL
# systemd --user end-to-end when available and self-skips in CI:
# a systemd-run stub fails with OnFailure=pi-packet-failed-drill@<unit>,
# a runtime-dir template invokes the repo handler, and the scratch sinks
# prove the whole chain fired.
#
# Also pins the wiring: pi-packet-failed@.service ExecStart calls the
# handler, pi-systemd-run adds pi-packet-failed@<unit> to OnFailure, and
# MANIFEST installs bin/pi-packet-failed.

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
grep -qF 'ExecStart=/home/nish/.local/bin/pi-packet-failed %i' "$unit_file" \
    || fail "pi-packet-failed@.service must ExecStart the handler"
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

mk_fakes() {
    # $1 = dir to hold fakes; $2 = canned Environment value for `show`.
    local d="$1" envval="$2"
    mkdir -p "$d"
    cat >"$d/systemctl" <<EOF
#!/usr/bin/env bash
# fake systemctl: only \`show <unit> -p Environment --value\` is served.
for a in "\$@"; do [[ "\$a" == "show" ]] && { printf '%s\n' '$envval'; exit 0; }; done
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
    cat >"$d/fleet-issue-file" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/issuefile.calls"
# --body <body> is argv position after --body; record it too.
while [[ \$# -gt 0 ]]; do [[ "\$1" == "--body" ]] && { printf '%s\n' "\$2" > "$d/issuefile.body"; }; shift; done
printf 'https://example.invalid/issues/1\n'
exit "\${ISSUE_FILE_RC:-0}"
EOF
    chmod +x "$d/systemctl" "$d/journalctl" "$d/logger" "$d/fleet-issue-file"
}

run_handler() {
    # $1 = fakes dir, $2 = scratch state dir, $3 = instance arg, extra env via env
    local d="$1" st="$2" inst="$3"; shift 3
    mkdir -p "$st/pi-packets"
    env SYSTEMCTL="$d/systemctl" JOURNALCTL="$d/journalctl" LOGGER="$d/logger" \
        GH="$d/gh-unused" AGENT_STATE="$st" \
        FLEET_HEARTBEAT_TRIAGE="$st/triage.md" \
        FLEET_FINDINGS_LEDGER="$st/findings-ledger.jsonl" \
        FLEET_ISSUE_FILE="$d/fleet-issue-file" \
        PI_PACKET_STATE="$st/pi-packets" \
        "$@" "$bin" "$inst"
}

# --- Phase A: deliverable packet -> all four records -------------------------
fa="$scratch/fa"; sta="$scratch/sta"
mk_fakes "$fa" 'HOME=/home/nish PI_DEADMAN_DELIVERABLE=/scratch/expected.md PI_DEADMAN_DISPATCH=11111111-2222-3333-4444-555555555555'
mkdir -p "$sta/pi-packets"
printf 'drill packet body\n' > "$sta/pi-packets/drillpkt.in"
run_handler "$fa" "$sta" drillpkt \
    || fail "handler must exit 0 when all records land"

grep -q 'packet drillpkt exhausted StartLimitBurst' "$fa/logger.calls" \
    || fail "syslog line must be kept: $(cat "$fa/logger.calls" 2>/dev/null)"
ok "syslog line preserved"

grep -q '\[PI-PACKET-FAILED\]' "$sta/triage.md" \
    || fail "triage must carry the LOUD line: $(cat "$sta/triage.md" 2>/dev/null)"
grep -q 'pi-packet@drillpkt.service' "$sta/triage.md" \
    || fail "triage line must name the failed unit"
grep -q 'deliverable=/scratch/expected.md' "$sta/triage.md" \
    || fail "triage line must name the missing deliverable"
ok "triage LOUD line"

[[ -f "$sta/findings-ledger.jsonl" ]] || fail "findings-ledger row missing"
python3 - "$sta/findings-ledger.jsonl" <<'PY' || fail "ledger row schema wrong"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) == 1, f"want 1 row, got {len(rows)}"
r = rows[0]
assert r["source_organ"] == "pi-packet", r
assert r["disposition"] == "carried_over", r
assert r["ref"] == "pi-packet@drillpkt.service", r
assert r["finding_id"], r
# The direct-append fid MUST equal lib/findings_ledger.py's finding_id
# (sha256, not sha1 as that file's docstring claims) so fallback- and
# helper-written rows dedupe against each other.
import hashlib, re
title = f"packet {r['ref']} exhausted retries (StartLimitBurst) — terminal failure"
norm = re.sub(r"\W+", " ", title.strip().lower()).strip()
want = hashlib.sha256(f"pi-packet|{r['ref']}|{norm}".encode()).hexdigest()[:16]
assert r["finding_id"] == want, (r["finding_id"], want)
assert "line five (last)" in r["evidence_ref"], r
assert "/scratch/expected.md" in r["reason"], r
PY
ok "findings-ledger row (source_organ/disposition/ref/evidence)"

[[ -f "$fa/issuefile.calls" ]] || fail "--deliverable packet must re-queue via fleet-issue-file"
grep -q -- '--label agent-ready' "$fa/issuefile.calls" \
    || fail "re-queue issue must be agent-ready: $(cat "$fa/issuefile.calls")"
grep -q 'pi-packet@drillpkt.service' "$fa/issuefile.calls" \
    || fail "issue title must name the packet"
grep -q 'signal: pi-packet-exhausted/pi-packet@drillpkt.service' "$fa/issuefile.body" \
    || fail "issue body must carry the dedupe signal"
grep -q '/scratch/expected.md' "$fa/issuefile.body" \
    || fail "issue body must name the deliverable"
grep -q 'drillpkt.in' "$fa/issuefile.body" \
    || fail "issue body should cite the packet path"
ok "agent-ready re-queue issue via fleet-issue-file"

# --- Phase B: no deliverable -> records but no issue --------------------------
fb="$scratch/fb"; stb="$scratch/stb"
mk_fakes "$fb" 'HOME=/home/nish PATH=/usr/bin:/bin'
run_handler "$fb" "$stb" drillpkt \
    || fail "handler must exit 0 for a non-deliverable packet"
[[ -f "$fb/issuefile.calls" ]] \
    && fail "no --deliverable marker -> no issue filing, got: $(cat "$fb/issuefile.calls")"
grep -q '\[PI-PACKET-FAILED\]' "$stb/triage.md" || fail "triage line still required"
[[ -f "$stb/findings-ledger.jsonl" ]] || fail "ledger row still required"
ok "non-deliverable packet: records written, no issue filed"

# --- Phase C: installed helper is the ledger writer ---------------------------
fc="$scratch/fc"; stc="$scratch/stc"
mk_fakes "$fc" 'HOME=/home/nish'
cat >"$fc/findings_ledger.py" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fc/helper.calls"   # the append CLI argv
exit 0
EOF
chmod +x "$fc/findings_ledger.py"
run_handler "$fc" "$stc" drillpkt \
    FLEET_FINDINGS_LEDGER_HELPER="$fc/findings_ledger.py" \
    || fail "handler must exit 0 when the helper accepts the row"
[[ -f "$fc/helper.calls" ]] || fail "helper must be invoked with the append CLI"
grep -qF 'append --ledger' "$fc/helper.calls" \
    || fail "helper must be called with its append CLI: \$(cat "$fc/helper.calls")"
grep -qF -- '--disposition carried_over' "$fc/helper.calls" \
    || fail "helper must receive disposition=carried_over"
grep -qF -- '--source-organ pi-packet' "$fc/helper.calls" \
    || fail "helper must receive source_organ=pi-packet"
grep -qF -- '--ref pi-packet@drillpkt.service' "$fc/helper.calls" \
    || fail "helper must receive ref=<failed unit>"
[[ -f "$stc/findings-ledger.jsonl" ]] \
    && fail "helper accepted the row — direct append must not double-write"
ok "findings-ledger helper path (single writer when installed)"

# --- Phase C2: helper exit 3 ("skip: duplicate") is SUCCESS, not a rejection -
# the shipped helper exits 3 when the row is already recorded (same
# finding_id + disposition + ref). The recorder must treat that as the
# ledger being durable and must NOT direct-append a second identical row
# (caught live 2026-09-11: two runs -> two rows). It must say so, loudly.
fc2="$scratch/fc2"; stc2="$scratch/stc2"
mk_fakes "$fc2" 'HOME=/home/nish'
cat >"$fc2/findings_ledger.py" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fc2/helper.calls"
echo 'skip: duplicate' >&2
exit 3
EOF
chmod +x "$fc2/findings_ledger.py"
set +e
run_handler "$fc2" "$stc2" drillpkt \
    FLEET_FINDINGS_LEDGER_HELPER="$fc2/findings_ledger.py" 2>"$fc2/stderr"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "helper duplicate (rc 3) must be success, got exit $rc"
[[ -f "$stc2/findings-ledger.jsonl" ]] \
    && fail "duplicate must not direct-append a second row"
grep -q 'skip: duplicate' "$fc2/stderr" \
    || fail "duplicate must be logged: $(cat "$fc2/stderr" 2>/dev/null | tail -4)"
ok "findings-ledger helper duplicate (rc 3) treated as durable, no re-append"

# --- Phase C3: a genuine helper failure falls back to direct append, loud --
fc3="$scratch/fc3"; stc3="$scratch/stc3"
mk_fakes "$fc3" 'HOME=/home/nish'
cat >"$fc3/findings_ledger.py" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fc3/helper.calls"
echo 'findings_ledger: refusing row missing ref' >&2
exit 1
EOF
chmod +x "$fc3/findings_ledger.py"
set +e
run_handler "$fc3" "$stc3" drillpkt \
    FLEET_FINDINGS_LEDGER_HELPER="$fc3/findings_ledger.py" 2>"$fc3/stderr"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "fallback after genuine helper failure must still succeed, got exit $rc"
[[ -f "$stc3/findings-ledger.jsonl" ]] \
    || fail "a lost row is a silent drop — direct-append fallback must land the row"
grep -q 'WARN: findings-ledger helper' "$fc3/stderr" \
    || fail "helper rejection must be logged as WARN: $(cat "$fc3/stderr" 2>/dev/null | tail -4)"
grep -q 'rc=1' "$fc3/stderr" \
    || fail "WARN must carry the helper's rc + message"
ok "genuine helper failure -> loud WARN + direct-append fallback"

# --- Phase D: required issue-file failure is LOUD (non-zero) ------------------
fd="$scratch/fd"; std="$scratch/std"
mk_fakes "$fd" 'HOME=/home/nish PI_DEADMAN_DELIVERABLE=/scratch/expected.md'
set +e
run_handler "$fd" "$std" drillpkt ISSUE_FILE_RC=1 2>"$fd/stderr"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "a required issue filing that failed must exit non-zero"
grep -q 'ALERT' "$fd/stderr" || fail "failed filing must log ALERT: $(cat "$fd/stderr")"
grep -q '\[PI-PACKET-FAILED\]' "$std/triage.md" || fail "triage line must still land"
[[ -f "$std/findings-ledger.jsonl" ]] || fail "ledger row must still land"
ok "required-write failure is loud (exit $rc) while other sinks still land"

# --- Phase E: missing arg fails ------------------------------------------------
set +e
"$bin" >"$scratch/noarg.out" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "missing instance arg must fail"
ok "missing arg exits non-zero"

# --- Phase F: live drill with a stub unit (skips without systemd --user) ------
# A real systemd chain: a stub unit fails -> OnFailure= fires
# pi-packet-failed-drill@<stub> -> the runtime template runs the repo handler
# -> scratch triage + ledger + issue-file prove the full path. The drill
# template lives in $XDG_RUNTIME_DIR/systemd/user (ephemeral; never MANIFEST)
# so nothing permanent is installed.
# Probe = `list-units` works: `is-system-running` exits non-zero merely for
# "degraded" (any failed unit), which is the norm on this box.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if command -v systemctl >/dev/null 2>&1 && command -v systemd-run >/dev/null 2>&1 \
   && systemctl --user list-units --no-legend >/dev/null 2>&1 \
   && [[ -d "$XDG_RUNTIME_DIR" ]]; then
    ts="$(date -u +%s)"
    # live-dummy* is the established proof-unit convention (fleet-ops#4266):
    # unit-escalation-write excludes it, so the deliberate stub failure never
    # summons a real senior auditor via the global service.d drop-in.
    dstub="live-dummy-pf$ts"                    # the failing stub unit
    dtmpl="$XDG_RUNTIME_DIR/systemd/user/pi-packet-failed-drill@.service"
    fd6="$scratch/fd6"; std6="$scratch/std6"
    mk_fakes "$fd6" 'unused'
    mkdir -p "$std6" "$(dirname "$dtmpl")"
    cat >"$dtmpl" <<EOF
[Unit]
Description=drill: pi-packet-failed handler for stub unit %i (fleet-ops#5444)

[Service]
Type=oneshot
Environment=HOME=$HOME
Environment=SYSTEMCTL=systemctl
Environment=JOURNALCTL=journalctl
Environment=FLEET_HEARTBEAT_TRIAGE=$std6/triage.md
Environment=FLEET_FINDINGS_LEDGER=$std6/findings-ledger.jsonl
Environment=FLEET_FINDINGS_LEDGER_HELPER=$std6/no-such-helper
Environment=FLEET_ISSUE_FILE=$fd6/fleet-issue-file
Environment=AGENT_STATE=$std6
Environment=PI_PACKET_STATE=$std6/pi-packets
Environment=PI_PACKET_FAILED_DELIVERABLE=$std6/expected-deliverable.md
# systemd units get a clean env: GITHUB_ACTIONS never reaches the handler
# unless passed explicitly. On a hosted runner the worker-token mint cannot
# exist, so the handler must see the CI marker to skip minting (the fake
# fleet-issue-file still proves the re-queue path). On the VPS the var is
# empty and the real mint path is what gets drilled.
Environment=GITHUB_ACTIONS=${GITHUB_ACTIONS:-}
ExecStart=$bin %i
StandardOutput=file:$std6/handler.stdout
StandardError=file:$std6/handler.stderr
EOF
    systemctl --user daemon-reload
    # The stub fails once (Restart=no via transient default) and carries the
    # --deliverable marker so the drill also exercises the re-queue path.
    # No --collect: the handler reads the dead stub's Environment, so the
    # unit object must still be loaded when OnFailure runs. reset-failed in
    # cleanup removes it.
    systemd-run --user --unit="$dstub" \
        --setenv=PI_DEADMAN_DELIVERABLE="$std6/expected-deliverable.md" \
        --property="OnFailure=pi-packet-failed-drill@${dstub}.service.service" \
        -- /bin/false >/dev/null 2>&1 || true
    # Wait (bounded) for the handler instance to run to completion.
    handler_unit="pi-packet-failed-drill@${dstub}.service.service"
    # Wait for ALL drill sinks: the handler appends the triage line BEFORE
    # the ledger/issue writes finish, so polling only triage breaks the
    # loop early on a slow runner (green on the VPS, red on runners).
    for _ in $(seq 1 60); do
        if [[ -f "$std6/triage.md" && -f "$std6/findings-ledger.jsonl" && -f "$fd6/issuefile.calls" ]]; then
            break
        fi
        sleep 1
    done
    grep -q '\[PI-PACKET-FAILED\]' "$std6/triage.md" \
        || fail "drill: triage line missing — $dstub failure never reached the handler"
    grep -q "$dstub" "$std6/triage.md" || fail "drill: triage must name the stub unit"
    python3 - "$std6/findings-ledger.jsonl" <<PY || fail "drill: ledger row missing/invalid"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert any(r["ref"] == "$dstub.service" and r["disposition"] == "carried_over"
           and r["source_organ"] == "pi-packet" for r in rows), rows
PY
    grep -q -- '--label agent-ready' "$fd6/issuefile.calls" \
        || fail "drill: deliverable stub must trigger the agent-ready re-queue (handler stderr: $(cat "$std6/handler.stderr" 2>/dev/null | tail -6); unit env visible: $(systemctl --user show "$dstub.service" -p Environment --value 2>&1 | head -2); drill template: $(systemctl --user show "pi-packet-failed-drill@$dstub.service.service" -p Environment --value 2>&1 | head -3))"
    grep -q "$dstub" "$fd6/issuefile.calls" || fail "drill: issue must name the stub unit"
    # Cleanup: stub + handler instance and the runtime template.
    systemctl --user reset-failed "$dstub.service" "$handler_unit" >/dev/null 2>&1 || true
    rm -f "$dtmpl"
    systemctl --user daemon-reload
    ok "live drill: stub failure -> handler -> triage + ledger + agent-ready issue"
else
    echo "SKIP: live drill (no functional systemd --user here)"
fi

echo "ALL OK: pi-packet-failed (fleet-ops#5444)"
