#!/usr/bin/env bash
# tests/fleet-failed-command-compound-ls-permission-denied.test.sh
#
# fleet-ops#1061: a compound bash chain (`;`-separated) where earlier
# commands succeed (systemctl show / echo "====") and a downstream
# `ls <path>` fails with `ls: cannot access '<path>': Permission denied`
# AND the chain's last command is a `stat <path> 2>/dev/null` whose own
# Permission-denied stderr is silenced — so the bash exit code is 1
# (stat's exit), not 2 (ls's exit). The worker walks past the failure
# with a thinking-only next turn plus a recovery toolCall (no
# user-facing text naming the failure). The detector already flags
# this class via the generic `is_error or code != 0` path:
# `REAL_ERR_RE` matches `Permission denied` in the visible `ls:` line,
# and no `LS_BENIGN_RE` / `BENIGN_STAGE_RE` short-circuit applies. The
# class is distinct from the live #794 / 4b-perm shape (a single
# `ls -l /etc/shadow` exit 2 alone) and the live #822 git-ref-probe
# shape (exit 128, no Permission denied). This file locks the live
# #1061 shape so a future detector refactor that broadens the ls
# exemption, drops `Permission denied` from REAL_ERR_RE, or stops
# walking past compound-chain failures, is caught. No
# `lib/failed-command-flagged.py` detection-logic change — a
# suppression would silence a real signal. The auto-filed issue
# closes via observe-to-close (fleet-ops#650) when the session mtime
# ages out of the 24h window.
#
# Live session: 2026-08-27T07-31-43-359Z_01a04221-c07f-7cf5-9a57-c466ca62454b.jsonl
# The agent ran
#   systemctl show restic-r2-backup.timer --property=NextElapseUSec,LastTriggerUSec,ActiveState 2>/dev/null; echo "===="; ls /var/cache/restic-live/.backup-artifact 2>&1; stat -c '%y %s' /var/cache/restic-live/.backup-artifact 2>/dev/null
# and got the live shape:
#   LastTriggerUSec=Thu 2026-08-27 04:39:10 IST
#   ActiveState=active
#   ====
#   ls: cannot access '/var/cache/restic-live/.backup-artifact': Permission denied
#
#
#   Command exited with code 1
# then continued with a thinking-only turn ("The timer ran at 04:39:10
# and the artifact is owned by root. Let me try a different probe.")
# plus a `ls /var/cache/restic-live/ 2>&1 | head` recovery toolCall —
# no user-facing text named the failure.
#
# The class is distinct from the live #794 / 4b-perm shape
# (single-command `ls -l /etc/shadow` exit 2) and the live #822
# git-ref-probe exemption (exit 128, silenced stderr, `fatal:` probe
# line). The live #1061 shape is a compound bash chain with `;`
# separators where:
#   1. earlier commands succeed and their stdout appears in the
#      toolResult (so the snippet starts with that successful output
#      — the ls error appears AFTER the `====` separator),
#   2. `ls` Permission denied is visible because `2>&1` was used,
#   3. `stat` Permission denied is silenced because `2>/dev/null` was
#      used, and stat is the LAST command so bash exits 1 (stat's
#      exit code), not 2 (ls's exit code).
# Pin both the visible `ls:` Permission-denied line AND the
# non-silenced bash exit-1 in the snippet — a future refactor that
# drops one of them is caught.
#
# Scenarios:
#   1. live #1061 shape: compound bash chain (`systemctl show ... ;
#      echo "====" ; ls Y 2>&1 ; stat Z 2>/dev/null`) exit 1, visible
#      `ls: cannot access '<path>': Permission denied`, thinking-only
#      + toolCall recovery -> finding. Snippet must carry BOTH
#      `ls: cannot access` AND `Permission denied` AND
#      `Command exited with code 1` — dropping either is a regression
#      in the snippet-capture path.
#   2. same shape plus a later user-facing flag -> clean.
#   3. cross-check: single-command `ls -l /etc/shadow` exit 2 (the
#      live #794 / 4b-perm shape, with `Permission denied`) is still
#      flagged — distinct shape, same `Permission denied` class.
#      Pin the contrast so a future refactor that drops the
#      compound-chain handling (and only flags single-command ls) is
#      caught.
#   4. cross-check: `ls <nonexistent>` exit 2 with the canonical
#      no-match line (`ls: cannot access '<path>': No such file or
#      directory`) is the live #794 exemption — same ls command,
#      different error class. That must stay exempt while the
#      Permission-denied shape is flagged. Pin the contrast so a
#      future refactor that broadens the ls exemption to
#      `Permission denied` (silencing #1061) OR that drops the
#      canonical no-match probe (silencing #794) is caught.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-compound-ls-permission-denied.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T08:00:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T10:00:00Z"
}

# --- 1. live #1061 shape: compound chain with ls Permission denied, walked --
# The live session slug 01a04221 was filed because the agent ran the
# compound chain `systemctl show ...; echo "===="; ls /var/cache/...;
# stat -c '%y %s' /var/cache/... 2>/dev/null` and got the visible
# `ls: cannot access '/var/cache/restic-live/.backup-artifact':
# Permission denied` line (because ls uses `2>&1`) while stat's
# Permission-denied stderr was silenced (because stat uses
# `2>/dev/null`); stat is the LAST command so bash exits 1 (stat's
# exit), not 2 (ls's exit). The agent then continued with a
# thinking-only turn ("The timer ran at 04:39:10 and the artifact is
# owned by root. Let me try a different probe.") plus a
# `ls /var/cache/restic-live/ 2>&1 | head` recovery toolCall — no
# user-facing text named the failure. Replay that exact shape.
write_session "compound-ls-permission-denied-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_check","name":"bash","arguments":{"command":"systemctl show restic-r2-backup.timer --property=NextElapseUSec,LastTriggerUSec,ActiveState 2>/dev/null; echo \"====\"; ls /var/cache/restic-live/.backup-artifact 2>&1; stat -c '%y %s' /var/cache/restic-live/.backup-artifact 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_check","toolName":"bash","isError":true,"content":[{"type":"text","text":"LastTriggerUSec=Thu 2026-08-27 04:39:10 IST\nActiveState=active\n====\nls: cannot access '/var/cache/restic-live/.backup-artifact': Permission denied\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The timer ran at 04:39:10 and the artifact is owned by root. Let me try a different probe."},{"type":"toolCall","id":"call_next","name":"bash","arguments":{"command":"ls /var/cache/restic-live/ 2>&1 | head"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_next","toolName":"bash","isError":false,"content":[{"type":"text","text":""}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"OK, moving on."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1061 compound ls Permission denied walked past should be a finding (got $count) $report"
slug=$(jq -r '.findings[0].slug' <<<"$report")
[[ "$slug" == "compound-ls-permission-denied-walked" ]] || fail "finding slug should be compound-ls-permission-denied-walked (got $slug)"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
# Pin the unique signals from the live #1061 toolResult so a future
# refactor that drops one of them is caught. The snippet is truncated
# to 200 chars; the leading `LastTriggerUSec=...` + `====` +
# `ls: cannot access '<path>': Permission denied` + `Command exited
# with code 1` lines all fit in 200 chars (the issue body's snippet
# proves it: `LastTriggerUSec=Thu 2026-08-27 04:39:10 IST
# ActiveState=active ==== ls: cannot access '/var/cache/restic-live/
# .backup-artifact': Permission denied   Command exited with code 1`).
grep -q "ls: cannot access" <<<"$snippet" \
  || fail "finding snippet should mention 'ls: cannot access' (got $snippet)"
grep -q "Permission denied" <<<"$snippet" \
  || fail "finding snippet should mention 'Permission denied' (got $snippet)"
grep -q "Command exited with code 1" <<<"$snippet" \
  || fail "finding snippet should mention 'Command exited with code 1' (got $snippet)"
ok "live #1061 compound ls Permission denied exit 1 walked past is flagged"
rm -f "$sessions/compound-ls-permission-denied-walked.jsonl"

# --- 2. same shape plus a later user-facing flag is clean -------------------
# The standing rule is satisfied when the assistant names the failure
# in the same turn's user-facing text. The detector must NOT flag
# this. Lock the contrast: a worker that names the
# compound-chain Permission-denied failure in plain text and then
# recovers is clean; a worker that only emits a thinking-only
# recovery toolCall is filed.
write_session "compound-ls-permission-denied-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_check2","name":"bash","arguments":{"command":"systemctl show restic-r2-backup.timer --property=NextElapseUSec,LastTriggerUSec,ActiveState 2>/dev/null; echo \"====\"; ls /var/cache/restic-live/.backup-artifact 2>&1; stat -c '%y %s' /var/cache/restic-live/.backup-artifact 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_check2","toolName":"bash","isError":true,"content":[{"type":"text","text":"LastTriggerUSec=Thu 2026-08-27 04:39:10 IST\nActiveState=active\n====\nls: cannot access '/var/cache/restic-live/.backup-artifact': Permission denied\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the compound-chain call failed with exit 1 (ls Permission denied on /var/cache/restic-live/.backup-artifact — the artifact is owned by root, not by the systemd user; the bash exit is 1 because stat at the end of the chain also failed with silenced Permission-denied stderr). Falling back to sudo for the next probe."},{"type":"toolCall","id":"call_sudo","name":"bash","arguments":{"command":"sudo -n ls -la /var/cache/restic-live/ 2>&1 | head"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged compound ls Permission denied should be clean (got $count) $report"
ok "compound ls Permission denied plus later user-facing flag is clean"
rm -f "$sessions/compound-ls-permission-denied-flagged.jsonl"

# --- 3. cross-check: single-command ls Permission denied is also flagged ---
# The live #794 / 4b-perm shape is `ls -l /etc/shadow` alone, exit 2.
# Different exit code, no compound chain, no silenced stat tail —
# but the SAME `Permission denied` real-error class. The detector
# flags both shapes. Pin the contrast so a future refactor that
# drops compound-chain handling (and only flags single-command ls)
# OR that drops `Permission denied` from REAL_ERR_RE (silencing both
# #1061 AND #794) is caught.
write_session "single-ls-permission-denied" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_shadow","name":"bash","arguments":{"command":"ls -l /etc/shadow"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_shadow","toolName":"bash","isError":true,"content":[{"type":"text","text":"ls: cannot open directory '/etc/shadow': Permission denied\n\nCommand exited with code 2"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "single-command ls Permission denied exit 2 walked past should be a finding (got $count) $report"
ok "single-command ls Permission denied exit 2 (live #794 contrast) is flagged"
rm -f "$sessions/single-ls-permission-denied.jsonl"

# --- 4. cross-check: ls no-match probe is exempt (live #794) ----------------
# Same ls command, different error class: `ls <nonexistent>` exits 2
# with the canonical `ls: cannot access '<path>': No such file or
# directory` line. The detector's `_ls_canonical_probe` returns True
# for that shape (live #794 exemption). Pin the contrast so a future
# refactor that broadens the ls exemption to `Permission denied`
# (silencing #1061 / #794) OR that drops the canonical no-match
# probe (silencing every ls no-match probe) is caught.
write_session "ls-nomatch-exempt-vs-1061" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_nomatch","name":"bash","arguments":{"command":"ls /var/cache/restic-live/.nonexistent-artifact 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_nomatch","toolName":"bash","isError":true,"content":[{"type":"text","text":"ls: cannot access '/var/cache/restic-live/.nonexistent-artifact': No such file or directory\n\nCommand exited with code 2"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"No such file. Moving on."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "ls no-match probe should stay exempt (got $count) $report"
ok "ls no-match probe (live #794) is exempt (contrast: live #1061 Permission-denied is NOT)"
rm -f "$sessions/ls-nomatch-exempt-vs-1061.jsonl"

# --- 5. lib/failed-command-flagged.py cites fleet-ops#1061 (detector-side lock: case list moved to lib, fleet-ops#3246) -------------------
# The prompt is the standing-rule contract for the next worker; dropping
# the #1061 citation is a regression even if the drill still passes.
worker="$repo_root/prompts/worker.md"
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1061' "$lib" \
  || fail "lib/failed-command-flagged.py must cite fleet-ops#1061 (detector-side lock for the live compound-ls Permission-denied shape)"
grep -q "Permission denied" "$lib" \
  || fail "lib/failed-command-flagged.py must name 'Permission denied' so workers flag the live #1061 wording"
grep -q "compound" "$lib" \
  || fail "lib/failed-command-flagged.py must name the 'compound' bash chain shape so workers flag the live #1061"
ok "lib/failed-command-flagged.py cites fleet-ops#1061 and the live compound-ls Permission-denied wording"

# --- 6. lib/failed-command-flagged.py docstring cites fleet-ops#1061 -------
# (detector-side lock). The docstring is the standing-rule contract
# for the next detector maintainer; dropping the #1061 citation is a
# regression even if the drill still passes.
grep -q 'fleet-ops#1061' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1061 (detector-side lock)"
grep -q "Permission denied" "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name 'Permission denied'"
grep -q 'compound' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the 'compound' bash chain shape"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1061 and the compound-ls Permission-denied shape"

# --- 7. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) -------
grep -Fq 'bash "$here/fleet-failed-command-compound-ls-permission-denied.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-compound-ls-permission-denied: live #1061 drills"