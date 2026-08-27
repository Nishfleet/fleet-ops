#!/usr/bin/env bash
# tests/fleet-failed-command-flagged.test.sh
#
# fleet-ops#535: session-close lint for "a failed command is ALWAYS flagged".
# Offline. Live gh is stubbed. Proves:
#   1. Clean assistant text / successful toolResult -> exit 0, FAILED-COMMAND-OK.
#   2. isError + no later flag -> exit 1.
#   3. isError plus later "the call failed" -> exit 0.
#   3d. SPAWN_BLOCKED (command never ran; live #648 git_stash_forbidden) -> exit 0.
#   4. grep/rg exit 1 (POSIX no-match) -> exit 0.
#   5. Origin case: 404 Not Found walked past -> exit 1.
#   6. Timeout unflagged -> exit 1.
#   6d. Bash [N/M] progress + timeout, flag only in toolCall comment (live #686) -> exit 1.
#   6e. Bash [N/M] progress + timeout, real user-facing flag -> exit 0.
#   6f. Live #821: read of source with 'Command timed out' regex text -> exit 0.
#   6g. Live #821: bash grep with 'Command timed out' in doc body -> exit 0.
#   6h. Live #848: bash `git log` whose stdout contains 'Command timed
#       out' as commit body text (isError=false) -> exit 0. The 6f/6g
#       tests cover `read` and `bash grep`; this one covers a successful
#       git log whose multi-commit body embeds the literal string.
#   7. Auto-file with signal key, deduped on a second run.
#   7b. Origin #650: cp /tmp/install.sh cannot-stat walked past -> exit 1.
#   7c. Same snippet plus a later flag -> exit 0.
#   8. Missing helper fails loud.
#   9. Contracts: heartbeat wiring, MANIFEST, nested CI host, matrix enforced.
#   4d. git log|rev-parse|show|diff|cat-file <bad-ref> exit 128 with
#       `2>/dev/null` is a deliberate existence probe, not a swallowed
#       command failure (live #822). Canonical "fatal: ambiguous
#       argument" / "fatal: bad revision" lines are probes; other
#       `fatal:` lines (not a git repository, unable to access,
#       repository not found, bad object, Permission denied, etc.) are
#       real failures and must still be flagged.
#  10. Observe-to-close: a green tick comments resolved-at on an aged-out
#      signal; a later tick with that marker closes; a still-dirty slug is
#      neither commented nor closed (fleet-ops#650).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-failed-command-flagged"
lib="$repo_root/lib/failed-command-flagged.py"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions/ws"
mkdir -p "$sessions"

gh_store="$scratch/gh-issues"
mkdir -p "$gh_store"
cat >"$scratch/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
store="${GH_MOCK_STORE:?}"
cmd="$1"; shift
case "$cmd" in
  issue)
    sub="$1"; shift
    case "$sub" in
      create)
        title=""; body=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --title) title="$2"; shift 2 ;;
            --body) body="$2"; shift 2 ;;
            --repo|-R) shift 2 ;;
            *) shift ;;
          esac
        done
        n=$(find "$store" -maxdepth 1 -name 'issue-*.body' | wc -l)
        f="$store/issue-$((n+1)).body"
        printf '%s\n' "$title" > "$f"
        printf '%s\n' "$body" >> "$f"
        echo "https://github.com/Nishfleet/fleet-ops/issues/9999"
        ;;
      comment)
        num=""; body=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --body) body="$2"; shift 2 ;;
            --repo|-R) shift 2 ;;
            *)
              if [ -z "$num" ]; then num="$1"; fi
              shift
              ;;
          esac
        done
        printf '%s\n' "$body" >"$store/issue-${num}.comments"
        printf '%s\n' "$num" >>"$store/commented"
        echo "https://github.com/Nishfleet/fleet-ops/issues/${num}#issuecomment-1"
        ;;
      list)
        state_filter="open"
        search_query=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --state) state_filter="$2"; shift 2 ;;
            --search) search_query="$2"; shift 2 ;;
            --limit|--json|--repo|-R) shift 2 ;;
            *) shift ;;
          esac
        done
        # Strip surrounding quotes from the search phrase.
        search_query="${search_query#\"}"
        search_query="${search_query%\"}"
        printf '[\n'
        first=1
        for f in "$store"/issue-*.body; do
          [ -f "$f" ] || continue
          num=$(basename "$f" .body)
          num=${num#issue-}
          is_closed=""
          [ -f "$store/issue-${num}.closed" ] && is_closed="1"
          if [ "$state_filter" = "open" ] && [ -n "$is_closed" ]; then
            continue
          fi
          if [ "$state_filter" = "closed" ] && [ -z "$is_closed" ]; then
            continue
          fi
          body=$(tail -n +2 "$f")
          comments_file="$store/issue-${num}.comments"
          if [ -f "$comments_file" ]; then
            comments_json=$(python3 -c 'import json,sys;print(json.dumps([{"body": sys.stdin.read()}]))' <"$comments_file")
            all_text="$body $(cat "$comments_file")"
          else
            comments_json='[]'
            all_text="$body"
          fi
          if [ -n "$search_query" ] && ! printf '%s' "$all_text" | grep -Fq -- "$search_query"; then
            continue
          fi
          if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
          if [ -n "$is_closed" ]; then
            issue_state="CLOSED"
          else
            issue_state="OPEN"
          fi
          printf '{"number":%s,"state":"%s","title":"","body":%s,"comments":%s}' \
            "$num" "$issue_state" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")" "$comments_json"
        done
        printf '\n]\n'
        ;;
      close)
        num=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --reason|--comment|--repo|-R) shift 2 ;;
            *)
              if [ -z "$num" ]; then num="$1"; fi
              shift
              ;;
          esac
        done
        [ -n "$num" ] || exit 1
        : > "$store/issue-${num}.closed"
        printf '%s\n' "$num" >>"$store/closed"
        echo "Closed issue #$num"
        ;;
      reopen)
        num=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --repo|-R) shift 2 ;;
            *)
              if [ -z "$num" ]; then num="$1"; fi
              shift
              ;;
          esac
        done
        [ -n "$num" ] || exit 1
        rm -f "$store/issue-${num}.closed"
        printf '%s\n' "$num" >>"$store/reopened"
        echo "Reopened issue #$num"
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$scratch/gh"

write_session() {
  local name="$1"
  local jsonl="$2"
  printf '%s\n' "$jsonl" >"$sessions/$name.jsonl"
  touch -d "2026-08-27T00:00:00Z" "$sessions/$name.jsonl"
}

run_bin() {
  local file_issues="${1:-0}"
  set +e
  FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
  FLEET_FAILED_COMMAND_LIB="$lib" \
  FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
  FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
  FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
  FLEET_FAILED_COMMAND_FILE_ISSUES="$file_issues" \
  FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
  GH="$scratch/gh" \
  GH_MOCK_STORE="$gh_store" \
  FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
    "$bin" >/dev/null 2>"$scratch/err.log"
  local rc=$?
  set -e
  echo "$rc"
}

# --- 1. clean session -------------------------------------------------------
write_session "clean" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Ran the canary. It passed."},{"type":"toolCall","id":"call_ok","name":"bash","arguments":{"command":"true"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ok","toolName":"bash","isError":false,"content":[{"type":"text","text":"ok"}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "clean session should exit 0 (got $rc) $(cat "$scratch/err.log")"
grep -q "FAILED-COMMAND-OK" "$scratch/err.log" || fail "clean session missing OK line"
ok "clean session exits 0"

# --- 2. isError, no flag ----------------------------------------------------
write_session "swallowed" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on to the next task."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "swallowed failure should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FAILED-COMMAND-SWALLOWED" "$scratch/err.log" || fail "missing FAILED-COMMAND-SWALLOWED loud line"
ok "isError without a later flag is swallowed"
rm -f "$sessions/swallowed.jsonl"

# --- 3. isError plus later flag ---------------------------------------------
write_session "flagged" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the false call failed with 1, it is now the blocker."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "flagged failure should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "isError plus later flag is clean"
rm -f "$sessions/flagged.jsonl"

# --- 3b. "fails" in later text is also a flag (live BET 9 wording) ----------
write_session "fails-word" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad","name":"bash","arguments":{"command":"node canary.mjs"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad","toolName":"bash","isError":true,"content":[{"type":"text","text":"mobile CTA below fold\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"unit tests pass, but the live run fails — mobile CTA is below the fold."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "'fails' wording should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "later text using 'fails' counts as a flag"
rm -f "$sessions/fails-word.jsonl"

# --- 3c. harness block is not a ran-and-failed command ----------------------
write_session "harness-block" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_rm","name":"bash","arguments":{"command":"rm -rf /"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_rm","toolName":"bash","isError":true,"content":[{"type":"text","text":"Dangerous command blocked (no UI for confirmation)"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Skipping that path."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "harness block should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "harness-blocked command is not a swallowed failure"
rm -f "$sessions/harness-block.jsonl"

# --- 3d. SPAWN_BLOCKED is not a ran-and-failed command (fleet-ops#648) ------
write_session "spawn-block" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_st","name":"bash","arguments":{"command":"git stash list"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_st","toolName":"bash","isError":true,"content":[{"type":"text","text":"SPAWN_BLOCKED reason=git_stash_forbidden. `git stash` is forbidden on this machine: checkouts are shared, so `git stash pop` grabs stash@{0}, which is very often another agent's work. Commit to a branch instead, or clone the repo fresh under /tmp and work there."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"On to the next check."}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "SPAWN_BLOCKED should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "SPAWN_BLOCKED is not a swallowed failure (command never ran)"
rm -f "$sessions/spawn-block.jsonl"

# --- 4. grep exit 1 is POSIX no-match ---------------------------------------
write_session "grep-nomatch" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_g","name":"bash","arguments":{"command":"grep nowhere /etc/hosts"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_g","toolName":"bash","isError":true,"content":[{"type":"text","text":"(no output)\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"No matches. Continuing."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "grep exit 1 should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "grep exit 1 is treated as no-match, not a swallowed failure"
rm -f "$sessions/grep-nomatch.jsonl"

# --- 4b. ls no-match (exit 2) is a probe, not a swallowed failure -----------
write_session "ls-nomatch" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ls","name":"bash","arguments":{"command":"cd /tmp && echo \"---\"; ls nonexistent-glob-* 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ls","toolName":"bash","isError":true,"content":[{"type":"text","text":"---\n\n\nCommand exited with code 2"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"No matching files. Continuing."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "ls no-match exit 2 should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "ls no-match (exit 2) is treated as a probe, not a swallowed failure"
rm -f "$sessions/ls-nomatch.jsonl"

# --- 4b-prime. live #794: ls canonical "cannot access" probe is benign -----
# Real live shape from the session that auto-filed the issue:
#   `ls ... 2>&1; echo "---"; ls app/lib/change-criticality.server.ts 2>&1`
# exits 2 with the canonical GNU `ls: cannot access '...': No such file or
# directory` line plus a successful listing from the earlier ls in the same
# command. The detector must treat this as a deliberate probe, not a
# swallowed failure.
write_session "ls-canonical" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_canon","name":"bash","arguments":{"command":"cd /home/nish/workspaces/products/0509 2>/dev/null && ls app/lib/aggression-score.ts app/lib/digest-rerank.ts app/lib/watch-period-triage.ts app/lib/digest-email.server.ts docs/noise-triage-competitors-2026-08-21.md docs/customer-readiness-remediation.md 2>&1; echo \"---\"; ls app/lib/change-criticality.server.ts 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_canon","toolName":"bash","isError":true,"content":[{"type":"text","text":"app/lib/aggression-score.ts\napp/lib/digest-email.server.ts\napp/lib/digest-rerank.ts\napp/lib/watch-period-triage.ts\ndocs/customer-readiness-remediation.md\ndocs/noise-triage-competitors-2026-08-21.md\n---\nls: cannot access 'app/lib/change-criticality.server.ts': No such file or directory\n\n\nCommand exited with code 2"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"PASS — no duplicate, north-star fit, research-delta well-formed."}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "ls canonical 'cannot access' probe should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "ls canonical 'cannot access' probe (live #794) is treated as a probe"
rm -f "$sessions/ls-canonical.jsonl"

# --- 4b-bsd. live #794 BSD/macOS ls shape is also a probe ------------------
write_session "ls-bsd" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bsd","name":"bash","arguments":{"command":"ls /nonexistent/path"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bsd","toolName":"bash","isError":true,"content":[{"type":"text","text":"ls: /nonexistent/path: No such file or directory\n\nCommand exited with code 2"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"No such file. Continuing."}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "BSD/macOS ls no-match should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "BSD/macOS ls no-match (live #794) is treated as a probe"
rm -f "$sessions/ls-bsd.jsonl"

# --- 4b-perm. real ls error (Permission denied) stays a swallowed failure --
# The canonical no-match exemption must NOT swallow real ls errors. A probe
# that tries to read /etc/shadow and gets "Permission denied" is a real
# failure the assistant did not name, and the detector must still flag it.
write_session "ls-perm" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_perm","name":"bash","arguments":{"command":"ls -l /etc/shadow"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_perm","toolName":"bash","isError":true,"content":[{"type":"text","text":"ls: cannot open directory '/etc/shadow': Permission denied\n\nCommand exited with code 2"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "ls Permission denied should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FAILED-COMMAND-SWALLOWED" "$scratch/err.log" || fail "ls Permission denied must be flagged as swallowed"
ok "ls Permission denied (live #794) is still flagged as swallowed"
rm -f "$sessions/ls-perm.jsonl"

# --- 4c. which no-match (exit 1) is a probe, not a swallowed failure --------
write_session "which-nomatch" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_which","name":"bash","arguments":{"command":"which nonexistent-binary 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_which","name":"bash","isError":true,"content":[{"type":"text","text":"(no output)\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Binary not in PATH. Need to install or use full path."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "which no-match exit 1 should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "which no-match (exit 1) is treated as a probe, not a swallowed failure"
rm -f "$sessions/which-nomatch.jsonl"

# --- 4d. live #822: git log <bad-ref> 2>/dev/null probe, silenced stderr ----
# The session `2026-08-27T02-16-50-035Z_01a04101-7673-7b5e-8dc0-2f96d562b234`
# ran `git log --oneline -10 origin/claim/issue-634 2>/dev/null; echo "---";
# git log --oneline -10 origin/claim/issue-518 2>/dev/null`. The first
# git log succeeded (showing 10 commits), the second failed with exit
# 128 (unknown ref), and the agent's next turn said "The branch is
# empty. Let me create a worktree." without naming the 128. The agent
# silenced stderr on purpose to probe for ref existence. The detector
# must treat exit 128 with no `fatal:` line in the text (silenced
# stderr) as a deliberate probe, not a swallowed failure.
write_session "git-probe-silenced" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_log","name":"bash","arguments":{"command":"git log --oneline -10 origin/claim/issue-634 2>/dev/null; echo \"---\"; git log --oneline -10 origin/claim/issue-518 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_log","name":"bash","isError":true,"content":[{"type":"text","text":"f572426 fix(failed-command): exempt 127 ENOENT downstream of a harness block (#797)\n1a59f2e fix(failed-command): worker prompt requires user-facing failure flag (#789)\na2ab4f8 fix(failed-command): treat ls and which no-match probes as benign (fleet-ops#663) (#788)\n3869f36 fix(prompt-assembly): uncap the decisions ledger and put volatile prompt values last (#795)\n21d184d fix(deploy-check): soft-fail on deploy-blocked so workers don't loop-summon auditor (#780)\n475b2a6 feat(seats): allowlist proven-free opencode mimo-v2.5-free (#779)\naaa3b86 config: bench opencode deepseek-v4-flash-free after failed live spawn (fleet-ops#639) (#775)\n4aee173 fix: strengthen auditor prompt to mandate duplicate/north-star keywords (#773)\nc5c6ec4 fix(failed-command): treat read tool offset beyond end as a negative result (#772)\nee72f89 fix(quality): observe-to-close role-gate findings and pin vault-conflict skip (#771)\n---\n\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"claim/issue-634 only has the main branch commits. The branch is empty. Let me create a worktree."}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "git log bad-ref 2>/dev/null probe (silenced stderr) should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "git log bad-ref 2>/dev/null (live #822, silenced stderr) is treated as a probe"
rm -f "$sessions/git-probe-silenced.jsonl"

# --- 4d-modern. live #822: git rev-parse --verify <bad-ref> canonical fatal -
# Modern git prints `fatal: ambiguous argument '<ref>': ...` on stderr
# (not silenced). When the agent does not silence stderr the canonical
# probe line is visible. The detector must treat that line as a probe.
write_session "git-probe-canonical" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_revparse","name":"bash","arguments":{"command":"git rev-parse --verify origin/claim/issue-518 2>&1; echo done"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_revparse","name":"bash","isError":true,"content":[{"type":"text","text":"fatal: ambiguous argument 'origin/claim/issue-518': unknown revision or path not in the working tree.\ndone\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"origin/claim/issue-518 does not exist on origin. Continuing."}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "git rev-parse 'ambiguous argument' probe should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "git rev-parse 'fatal: ambiguous argument' (live #822) is a probe"
rm -f "$sessions/git-probe-canonical.jsonl"

# --- 4d-old. live #822: older git shape `fatal: bad revision '<ref>'` -------
write_session "git-probe-old" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_show","name":"bash","arguments":{"command":"git show origin/claim/issue-518 2>&1 | head -3"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_show","name":"bash","isError":true,"content":[{"type":"text","text":"fatal: bad revision 'origin/claim/issue-518'\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"No such ref. Continuing."}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "git show 'bad revision' probe should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "git show 'fatal: bad revision' (older git, live #822) is a probe"
rm -f "$sessions/git-probe-old.jsonl"

# --- 4d-not-repo. real failure: not a git repository stays swallowed -------
# The git-probe exemption must NOT swallow real git errors. A `git log`
# in a non-repo directory is a real failure, even if exit code is 128.
write_session "git-not-repo" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_log","name":"bash","arguments":{"command":"cd /tmp/not-a-repo && git log -1 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_log","name":"bash","isError":true,"content":[{"type":"text","text":"fatal: not a git repository (or any of the parent directories): .git\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "git log in non-repo should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FAILED-COMMAND-SWALLOWED" "$scratch/err.log" || fail "git not-a-repo must be flagged as swallowed"
ok "git log in non-repo (live #822) is still flagged as swallowed"
rm -f "$sessions/git-not-repo.jsonl"

# --- 4d-noaccess. real failure: unable to access (auth/network) stays found -
# `fatal: unable to access ... 403 Forbidden` is a real swallowed
# failure, not a ref probe. The detector must keep flagging it.
write_session "git-noaccess" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_log","name":"bash","arguments":{"command":"git log origin/private 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_log","name":"bash","isError":true,"content":[{"type":"text","text":"fatal: unable to access 'https://x.example/private/': 403 Forbidden\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Trying the public mirror."}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "git log 403 forbidden should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FAILED-COMMAND-SWALLOWED" "$scratch/err.log" || fail "git 403 forbidden must be flagged as swallowed"
ok "git log 403 forbidden (live #822) is still flagged as swallowed"
rm -f "$sessions/git-noaccess.jsonl"

# --- 5. origin case: 404 walked past ----------------------------------------
write_session "origin-404" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_gh","name":"bash","arguments":{"command":"gh api -X PATCH /repos/Nishfleet/0509/branches/main/protection"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh","toolName":"bash","isError":true,"content":[{"type":"text","text":"Not Found\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"verify: strict is still true. Next task."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "404 walked past should exit 1 (got $rc) $(cat "$scratch/err.log")"
ok "origin 404 walked past is flagged"
rm -f "$sessions/origin-404.jsonl"

# --- 6. timeout unflagged ---------------------------------------------------
write_session "timeout" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_t","name":"bash","arguments":{"command":"sleep 999"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_t","toolName":"bash","isError":true,"content":[{"type":"text","text":"Command timed out after 180 seconds"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"On to the next check."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "timeout walked past should exit 1 (got $rc) $(cat "$scratch/err.log")"
ok "timeout without a later flag is swallowed"
rm -f "$sessions/timeout.jsonl"

# --- 6b. gh issue create GraphQL transient, retry with no flag --------------
write_session "gh-graphql-retry" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The workers project passes. The node test failure is pre-existing. Let me file it as a new issue, then check sgscan.\n\n"}]}}
{"type":"message","message":{"role":"toolCall","id":"call_gh1","name":"bash","arguments":{"command":"cd /tmp && gh issue create -R Nishfleet/0509 --title \"Pre-existing timeout\" --body \"pre-existing\" 2>&1"}}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh1","toolName":"bash","isError":true,"content":[{"type":"text","text":"GraphQL: Something went wrong while executing your query. Please include 'TOKEN' when reporting this issue.\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"\n\n"},{"type":"toolCall","id":"call_gh2","name":"bash","arguments":{"command":"cd /tmp && gh issue create -R Nishfleet/0509 --title \"Pre-existing timeout\" --body \"pre-existing\" 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh2","toolName":"bash","isError":false,"content":[{"type":"text","text":"https://github.com/Nishfleet/0509/issues/1231"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now let me check sgscan.\n\n"}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "gh GraphQL retry with no flag should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FAILED-COMMAND-SWALLOWED" "$scratch/err.log" || fail "gh GraphQL retry must be flagged as swallowed"
ok "gh issue create GraphQL failure + silent retry is swallowed"
rm -f "$sessions/gh-graphql-retry.jsonl"

# --- 6c. gh issue create GraphQL transient, explicit flag -> clean ----------
write_session "gh-graphql-flagged" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The workers project passes. The node test failure is pre-existing. Let me file it as a new issue, then check sgscan.\n\n"}]}}
{"type":"message","message":{"role":"toolCall","id":"call_gh1","name":"bash","arguments":{"command":"cd /tmp && gh issue create -R Nishfleet/0509 --title \"Pre-existing timeout\" --body \"pre-existing\" 2>&1"}}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh1","toolName":"bash","isError":true,"content":[{"type":"text","text":"GraphQL: Something went wrong while executing your query. Please include 'TOKEN' when reporting this issue.\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the gh issue create call failed with a GraphQL error, retrying.\n\n"},{"type":"toolCall","id":"call_gh2","name":"bash","arguments":{"command":"cd /tmp && gh issue create -R Nishfleet/0509 --title \"Pre-existing timeout\" --body \"pre-existing\" 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh2","toolName":"bash","isError":false,"content":[{"type":"text","text":"https://github.com/Nishfleet/0509/issues/1231"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now let me check sgscan.\n\n"}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "gh GraphQL retry with explicit flag should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "gh issue create GraphQL failure + explicit user-facing flag is clean"
rm -f "$sessions/gh-graphql-flagged.jsonl"

# --- 6d. long-running bash probe with [N/M] progress, timed out, no flag ----
# Live #686 (0509 competitor discovery spike, session 2026-08-26T12-22:28Z):
# the bash command printed [N/M] progress, ran for 17/35 then the
# orchestrator killed it (Command timed out after 1500 seconds). The next
# assistant turn was a toolCall whose COMMAND ARGUMENT included a
# "# Got 17/35 done" comment — but no user-facing text. The detector
# correctly flags this. Lock the shape so a future detector refactor
# cannot accidentally drop the progress-output / partial-completion class.
write_session "bash-progress-timedout" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe","name":"bash","arguments":{"command":"for q in running_shoes wool_shoes sustainable_fashion note_taking_app productivity_app team_wiki smart_ring fitness_tracker sleep_tracker beauty_products indian_cosmetics skincare fitness_apparel athletic_wear gym_clothing crm_software marketing_automation; do\n  curl -sS -A 'Mozilla/5.0' \"https://0509.io/search?q=$q\" > /tmp/probe-$q.html\n  echo \"[$(date +%s)] $q done\"\n  sleep 35\ndone\n# 35 probes × 35s = ~21 min"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe","toolName":"bash","isError":true,"content":[{"type":"text","text":"[1/35] running shoes done\n[2/35] wool shoes done\n[3/35] sustainable fashion done\n[4/35] note taking app done\n[5/35] productivity app done\n[6/35] team wiki done\n[7/35] smart ring done\n[8/35] fitness tracker done\n[9/35] sleep tracker done\n[10/35] beauty products done\n[11/35] indian cosmetics done\n[12/35] skincare done\n[13/35] fitness apparel done\n[14/35] athletic wear done\n[15/35] gym clothing done\n[16/35] crm software done\n[17/35] marketing automation done\n\n\nCommand timed out after 1500 seconds"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_check","name":"bash","arguments":{"command":"# Got 17/35 done. Let me check status and continue\ntail -50 /tmp/probe.log\necho '---'\ndate"}}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "bash progress [N/M] + timeout with no flag should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FAILED-COMMAND-SWALLOWED" "$scratch/err.log" \
  || fail "bash progress + timeout must be flagged as swallowed"
grep -q "running shoes done" "$scratch/err.log" \
  || fail "the [N/M] progress snippet must be in the loud line (live #686 shape)"
ok "bash [N/M] progress + timeout with no user-facing flag is swallowed (fleet-ops#686 shape locked)"
rm -f "$sessions/bash-progress-timedout.jsonl"

# --- 6e. long-running bash probe with [N/M] progress, timeout, with flag ---
# Same shape as 6d, but the next assistant turn has a real user-facing
# text flag ("the probe loop timed out at 17/35, ..."). The detector must
# not flag this. This is the proof the standing rule still works on the
# progress-output class: a worker that names the gap in user-facing text
# passes, a worker that only puts it in a toolCall comment (live #686) is filed.
write_session "bash-progress-flagged" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe2","name":"bash","arguments":{"command":"for q in running_shoes wool_shoes sustainable_fashion note_taking_app; do\n  curl -sS \"https://0509.io/search?q=$q\" > /tmp/probe-$q.html\n  echo \"[$q done]\"\n  sleep 35\ndone"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe2","toolName":"bash","isError":true,"content":[{"type":"text","text":"[1/4] running shoes done\n[2/4] wool shoes done\n[3/4] sustainable fashion done\n[4/4] note taking app done\n\n\nCommand timed out after 1500 seconds"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the probe loop call failed with a timeout at 4/4, the rest is unverified."},{"type":"toolCall","id":"call_resume","name":"bash","arguments":{"command":"tail -50 /tmp/probe.log"}}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "bash progress + timeout with explicit flag should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "bash [N/M] progress + timeout with explicit user-facing flag is clean"
rm -f "$sessions/bash-progress-flagged.jsonl"

# --- 6f. live #821: read of source code with 'Command timed out' as regex text -
# The session was reading lib/failed-command-flagged.py to debug it. The
# file's own TIMEOUT_RE regex definition contains the literal string
# "Command timed out" — but the read succeeded (isError=false, no exit
# code). The detector must not flag this as a swallowed timeout; the text
# is content, not a timeout error.
write_session "read-timeout-source" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_r","name":"read","arguments":{"path":"/home/nish/workspaces/agent-worktrees/issue-fleet-ops-664/lib/failed-command-flagged.py","offset":0,"limit":400}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_r","toolName":"read","isError":false,"content":[{"type":"text","text":"#!/usr/bin/env python3\n\"\"\"Session-close lint for 'a failed command is ALWAYS flagged' (fleet-ops#535).\n\nEXIT_RE = re.compile(r\"Command exited with code (\\d+)\")\nTIMEOUT_RE = re.compile(r\"Command timed out\", re.I)\n# Pipeline stage that is a search/diff whose exit 1 means 'no match'.\nBENIGN_STAGE_RE = re.compile(\n    r\"(?:^|[;&|\\n]|&&|\\|\\|)\\s*(?:sudo\\s+)?\"\n    r\"(?:grep|egrep|fgrep|rg|ripgrep|diff|git\\s+grep|git\\s+diff|which)\\b\",\n    re.I,\n)\n# Real errors that must not hide behind a grep in the same script.\nREAL_ERR_RE = re.compile(\n    r\"(Not Found|Permission denied|HTTP\\s*[45]\\d\\d|error TS\\d+|API rate limit)\",\n    re.I,\n)\n# Unquoted assistant report. Tight on the standing-rule verbs.\nFLAG_RE = re.compile(\n    r\"(failed|fails|failing|failure|\\berror\\b|non-zero|exited with|\"\n    r\"timed out|timeout|blocker|not found|\\b404\\b|\\b50[0-9]\\b|\"\n    r\"unexpected failing command|it is now the blocker)\",\n    re.I,\n)\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Looking at the regex."}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "read with 'Command timed out' as source text should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "live #821: read of source with 'Command timed out' regex text is not a swallowed timeout"
rm -f "$sessions/read-timeout-source.jsonl"

# --- 6g. live #821: bash grep on worker.md with 'Command timed out' in body --
# The session was reading prompts/worker.md to debug the standing rule. The
# file's own standing-rule paragraph contains the literal string
# "Command timed out" — but the bash grep succeeded (isError=false, no
# exit code). The detector must not flag this as a swallowed timeout.
write_session "bash-timeout-doc" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_g","name":"bash","arguments":{"command":"grep -A2 'Any unexpected failing command' /home/nish/workspaces/agent-worktrees/issue-fleet-ops-664/prompts/worker.md 2>&1 | head -5"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_g","toolName":"bash","isError":false,"content":[{"type":"text","text":"- Any unexpected failing command: say so in your output; if it blocks the work, exit nonzero. This covers every toolResult shape: `read` returning ENOENT/EACCES/`Offset N is beyond end of file` (fleet-ops#651, #664), `bash` exit != 0, `Command timed out`, gh 4xx/5xx, etc. The standing rule (fleet-ops#535) is that a failed tool call is ALWAYS named in the very next assistant turn."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Found the rule."}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "bash grep with 'Command timed out' in doc text should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "live #821: bash output with 'Command timed out' as doc text is not a swallowed timeout"
rm -f "$sessions/bash-timeout-doc.jsonl"

# --- 6h. live #848: bash `git log` with 'Command timed out' in commit body --
# The session `2026-08-27T02-17-01-276Z_01a04101-...` ran
#   `git log --no-merges --format="%H%n%B" origin/main..HEAD 2>&1 | head -100`
# and got a multi-commit log back. The body of commit 7d6267d8
# (the prior failed-command fix) mentions `Command timed out` in its
# PR description. Pre-#929, the detector treated any toolResult text
# containing that literal as a swallowed timeout, and the session was
# auto-filed as #848. The fix narrowed `result_failed` so a TIMEOUT_RE
# match only counts when there is a real failure signal. This locks the
# `git log` shape so a future refactor cannot reintroduce the false
# positive on a successful git command whose output happens to mention
# the literal phrase.
write_session "bash-timeout-git-log" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_log","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-652 && git log --no-merges --format=\"%H%n%B\" origin/main..HEAD 2>&1 | head -100"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_log","toolName":"bash","isError":false,"content":[{"type":"text","text":"7d6267d8e4b69a4ead5493afc689703e6f846baf\nfix(failed-command): lock the edit 'Could not find the exact text' shape (fleet-ops#652)\n\nThe session-close lint (fleet-ops#535) auto-filed #652: an `edit` tool\nreturned isError=true with 'Could not find the exact text in <path>. The\nold text must match exactly including all whitespace and newlines.' and\nthe worker walked past it without naming the failure in user-facing\ntext. The worker then read the file to find the right offset and\nsilently retried the edit. The detector is right to flag it: a 'Command\ntimed out' response is a real tool failure, not noise.\n\n\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Confirmed the prior fix is on the branch."}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "bash git log with 'Command timed out' as commit body should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "live #848: bash git log with 'Command timed out' as commit body is not a swallowed timeout"
rm -f "$sessions/bash-timeout-git-log.jsonl"

# --- 6i. live #952: python heredoc script KeyError, only thinking + toolCall in next turn -
# The session 2026-08-26T13-18-31-426Z ran a python heredoc script that crashed
# with `KeyError: 'input_domain'`. The toolResult had isError=true, exit code 1.
# The assistant's next turn was a `thinking` block plus a follow-up toolCall,
# with NO user-facing text naming the failure. The detector must flag this as
# a swallowed failure and not let a `thinking` block or a subsequent toolCall
# count as a flag. This is the exact pattern from fleet-ops#952.
write_session "python-heredoc-keyerror" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_py","name":"bash","arguments":{"command":"python3 << 'EOF'\nimport json\nv1 = json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike/results.json'))\nprint('Sample keys:', list(v1[0].keys()))\nEOF"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_py","toolName":"bash","isError":true,"content":[{"type":"text","text":"Sample keys: ['input_domain', 'brand', 'site_ok', 'site_title', 'site_keywords', 'wiki_brand_page', 'wiki_categories_explored', 'wiki_sibling_count', 'ddg_ia_hit', 'openalex_work_count', 'top8', 'signals_exercised', 'signals_skipped', 'eval']\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The script crashed on the last entry which has null input_domain. Let me fix the lookup."},{"type":"toolCall","id":"call_fix","name":"bash","arguments":{"command":"python3 << 'EOF'\nimport json\nv1 = json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike/results.json'))\nv1_lookup = {r['input_domain']: r for r in v1 if r.get('input_domain')}\nprint('Filtered keys:', list(v1_lookup.keys())[:5])\nEOF"}}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "python heredoc KeyError with only thinking+toolCall should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FAILED-COMMAND-SWALLOWED" "$scratch/err.log" || fail "python heredoc KeyError must be flagged as swallowed"
ok "live #952: python heredoc KeyError with only thinking+toolCall in next turn is flagged"
rm -f "$sessions/python-heredoc-keyerror.jsonl"

# --- 7. auto-file + dedupe --------------------------------------------------
write_session "swallowed" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}'
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err2.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "auto-file run should exit 1 (got $rc) $(cat "$scratch/err2.log")"
grep -q "FILED" "$scratch/err2.log" || { cat "$scratch/err2.log"; fail "auto-file did not file an issue"; }
grep -rq "signal: failed-command-flagged/" "$scratch/gh-issues" || fail "filed issue body missing signal key"
ok "auto-file creates an issue with the signal key"

set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err3.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "second auto-file run should still exit 1 (got $rc)"
grep -q "deduped" "$scratch/err3.log" || fail "second run did not dedupe $(cat "$scratch/err3.log")"
grep -rl "signal: failed-command-flagged/" "$scratch/gh-issues" | wc -l | grep -q "^1$" \
  || fail "signal key filed more than once (dedupe broken)"
ok "auto-file dedupes the signal key on a second run"
rm -f "$sessions/swallowed.jsonl"

# --- 7b. origin #650: cp /tmp/install.sh cannot-stat walked past -------------
write_session "install-cp" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_cp","name":"bash","arguments":{"command":"cp /tmp/install.sh /tmp/agent-cron-seat.6nGbWr/install.sh"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cp","toolName":"bash","isError":true,"content":[{"type":"text","text":"Scratch: /tmp/agent-cron-seat.6nGbWr cp: cannot stat '"'"'/tmp/install.sh'"'"': No such file or directory\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"On to the next check."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "origin #650 cp /tmp/install.sh walked past should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FAILED-COMMAND-SWALLOWED" "$scratch/err.log" || fail "origin #650 missing SWALLOWED loud line"
ok "origin #650: cp /tmp/install.sh cannot-stat walked past is flagged"
rm -f "$sessions/install-cp.jsonl"

# --- 7c. same snippet plus a later flag is clean ----------------------------
write_session "install-cp-flagged" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_cp","name":"bash","arguments":{"command":"cp /tmp/install.sh /tmp/agent-cron-seat.6nGbWr/install.sh"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cp","toolName":"bash","isError":true,"content":[{"type":"text","text":"Scratch: /tmp/agent-cron-seat.6nGbWr cp: cannot stat '"'"'/tmp/install.sh'"'"': No such file or directory\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the cp failed: /tmp/install.sh was not found, it is now the blocker."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "flagged #650 snippet should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "origin #650 snippet plus later flag is clean"
rm -f "$sessions/install-cp-flagged.jsonl"

# --- 10. observe-to-close (fleet-ops#650) -----------------------------------
# Isolate the mock store from the auto-file test's leftover issue-1.body.
rm -f "$gh_store"/issue-* "$gh_store"/commented "$gh_store"/closed
: >"$gh_store/commented"
: >"$gh_store/closed"
slug650="2026-08-26t08-55-06-528z-01a03d47-bc20-7470-8847-4b42403ff341"
printf '%s\n' "fix(failed-command): $slug650" >"$gh_store/issue-650.body"
printf '%s\n' "Do not close until the detector reports this clean.

signal: failed-command-flagged/${slug650}" >>"$gh_store/issue-650.body"

# Green tick (clean session only) comments resolved-at; does not close yet
# (marker must already be present from a prior tick, same as #521).
write_session "clean-observe" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Ran the canary. It passed."},{"type":"toolCall","id":"call_ok","name":"bash","arguments":{"command":"true"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ok","toolName":"bash","isError":false,"content":[{"type":"text","text":"ok"}]}}'
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_CLOSE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-obs.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "observe-to-close green tick should exit 0 (got $rc) $(cat "$scratch/err-obs.log")"
grep -q "OBSERVED-RESOLVED" "$scratch/err-obs.log" || fail "green tick must log OBSERVED-RESOLVED $(cat "$scratch/err-obs.log")"
grep -q '^650$' "$gh_store/commented" || fail "green tick must comment on #650 (commented=$(cat "$gh_store/commented"))"
grep -q "resolved-at: signal: failed-command-flagged/${slug650}" "$gh_store/issue-650.comments" \
  || fail "comment missing resolved-at marker"
if [ -s "$gh_store/closed" ]; then
  fail "same-tick must not close (closed=$(cat "$gh_store/closed"))"
fi
ok "observe-to-close: green tick comments resolved-at, does not close same tick"
rm -f "$sessions/clean-observe.jsonl"

# Later tick: marker already present, slug still absent -> close
: >"$gh_store/commented"
: >"$gh_store/closed"
write_session "clean-observe2" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Still clean."}]}}'
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_CLOSE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-close.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "observe close tick should exit 0 (got $rc) $(cat "$scratch/err-close.log")"
grep -q "OBSERVE-CLOSED" "$scratch/err-close.log" || fail "later tick must log OBSERVE-CLOSED $(cat "$scratch/err-close.log")"
grep -q '^650$' "$gh_store/closed" || fail "later tick must close #650 (closed=$(cat "$gh_store/closed"))"
if [ -s "$gh_store/commented" ]; then
  fail "later tick must not comment again (commented=$(cat "$gh_store/commented"))"
fi
ok "observe-to-close: later tick with resolved-at marker closes"
rm -f "$sessions/clean-observe2.jsonl"

# Still-dirty slug: even with a resolved-at marker, do not close
: >"$gh_store/commented"
: >"$gh_store/closed"
# Re-open for the dirty tick (the previous tick closed it in the mock).
rm -f "$gh_store/issue-650.closed"
write_session "still-dirty" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_cp","name":"bash","arguments":{"command":"cp /tmp/install.sh /tmp/x"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cp","toolName":"bash","isError":true,"content":[{"type":"text","text":"Scratch: /tmp/agent-cron-seat.6nGbWr cp: cannot stat '"'"'/tmp/install.sh'"'"': No such file or directory\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}'
# Force the session slug to match issue 650's signal by using that filename.
mv "$sessions/still-dirty.jsonl" "$sessions/${slug650}.jsonl"
touch -d "2026-08-27T00:00:00Z" "$sessions/${slug650}.jsonl"
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_CLOSE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-dirty.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "still-dirty slug should exit 1 (got $rc) $(cat "$scratch/err-dirty.log")"
if [ -s "$gh_store/closed" ]; then
  fail "still-dirty slug must not close (closed=$(cat "$gh_store/closed"))"
fi
if [ -s "$gh_store/commented" ]; then
  fail "still-dirty slug must not comment resolved-at (commented=$(cat "$gh_store/commented"))"
fi
ok "observe-to-close: still-dirty slug is neither commented nor closed"
rm -f "$sessions/${slug650}.jsonl"

# --- 7d. closed-dedup: do not re-file a worker-PR-closed issue; reopen it (#933)
# Live #933: #765 was closed by a worker PR (#925) while the session was still
# a finding in the 24h window. The detector re-filed #933 because it only
# searched open issues. It must now search all issues and, when it finds a
# closed issue without a resolved-at marker, reopen it instead of filing new.
rm -f "$gh_store"/issue-* "$gh_store/commented" "$gh_store/closed" "$gh_store/reopened"
write_session "closed-dedup" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}'
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-closed-dedup.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "closed-dedup first run should exit 1 (got $rc)"
grep -q "FILED" "$scratch/err-closed-dedup.log" || fail "closed-dedup first run did not file"
issue_count=$(find "$gh_store" -maxdepth 1 -name 'issue-*.body' | wc -l)
[[ "$issue_count" == "1" ]] || fail "closed-dedup first run should create exactly one issue (got $issue_count)"
cnum=$(basename $(ls "$gh_store"/issue-*.body | head -1) .body | sed 's/issue-//')

# Close the issue as if a worker PR had closed it (no resolved-at marker).
GH_MOCK_STORE="$gh_store" "$scratch/gh" issue close "$cnum" >/dev/null

# Same finding in the next tick. The detector must reopen, not file a new issue.
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-closed-dedup2.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "closed-dedup second run should exit 1 (got $rc)"
grep -q "REOPENED" "$scratch/err-closed-dedup2.log" || fail "closed-dedup second run did not reopen the closed issue: $(cat "$scratch/err-closed-dedup2.log")"
issue_count=$(find "$gh_store" -maxdepth 1 -name 'issue-*.body' | wc -l)
[[ "$issue_count" == "1" ]] || fail "closed-dedup second run must not create a new issue (got $issue_count)"
[ -f "$gh_store/issue-${cnum}.closed" ] && fail "closed-dedup reopen must remove the closed marker"
ok "closed-dedup: worker-PR-closed issue is reopened, not duplicated (#933)"
rm -f "$sessions/closed-dedup.jsonl"

# --- 7e. in-flight grace: do not resolve an open issue for a skipped session
# Live #765: a session file was still being written (mtime within grace) when
# the heartbeat ran. The detector skipped it, saw no finding for the slug,
# and posted a resolved-at comment, leading to a premature close and #933.
# With skipped_grace_slugs, observe-to-close must not touch an open issue
# whose session is still within the grace window.
rm -f "$gh_store"/issue-* "$gh_store/commented" "$gh_store/closed" "$gh_store/reopened"
slug_grace="2026-08-27t00-05-00-000z-grace-test"
printf '%s\n' "fix(failed-command): $slug_grace" >"$gh_store/issue-750.body"
printf '\nDo not close until the detector reports this clean.\n\nsignal: failed-command-flagged/%s\n' "$slug_grace" >>"$gh_store/issue-750.body"
write_session "$slug_grace" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}'
touch -d "2026-08-27T00:05:00Z" "$sessions/${slug_grace}.jsonl"
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="10" \
FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_CLOSE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-grace.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "in-flight grace tick should exit 0 (got $rc) $(cat "$scratch/err-grace.log")"
grep -q "skipped due to in-flight grace" "$scratch/err-grace.log" || fail "in-flight grace tick did not skip resolving the open issue: $(cat "$scratch/err-grace.log")"
[ -s "$gh_store/commented" ] && fail "in-flight grace tick must not comment resolved-at"
[ -s "$gh_store/closed" ] && fail "in-flight grace tick must not close the open issue"
# Also lock the skipped_grace_slugs contract in the helper report.
grace_report=$(python3 "$lib" scan --root "$sessions" --window-hours 24 --grace-minutes 10 --now "2026-08-27T00:10:00Z")
[[ $(jq '.skipped_grace' <<<"$grace_report") == "1" ]] || fail "grace report should show skipped_grace=1"
jq -e --arg s "$slug_grace" '.skipped_grace_slugs | contains([$s])' <<<"$grace_report" >/dev/null \
  || fail "grace report should list the skipped slug"
ok "in-flight grace: open issue is not resolved while session is still within grace"
rm -f "$sessions/${slug_grace}.jsonl"

# --- 8. missing helper fails loud -------------------------------------------
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$scratch/no-such.py" \
FLEET_FAILED_COMMAND_FILE_ISSUES=0 \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err4.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "missing helper should exit 1 (got $rc)"
grep -q "FAILED-COMMAND-BROKEN" "$scratch/err4.log" || fail "missing helper must be LOUD"
ok "missing helper fails loud"

# --- 9. contracts -----------------------------------------------------------
grep -q 'fleet-failed-command-flagged' "$tier1" \
  || fail "fleet-heartbeat-tier1 must invoke fleet-failed-command-flagged"
grep -q 'failed_command_rc' "$tier1" \
  || fail "fleet-heartbeat-tier1 must propagate failed_command_rc"
grep -q 'bin/fleet-failed-command-flagged' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-failed-command-flagged"
grep -q 'lib/failed-command-flagged.py' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install lib/failed-command-flagged.py"
grep -Fq 'bash "$here/fleet-failed-command-flagged.test.sh"' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
jq -e '.rules[] | select(.id == "sr-failed-command-flagged" and .status == "enforced")' \
  "$repo_root/config/rule-enforcement.json" >/dev/null \
  || fail "sr-failed-command-flagged must be status=enforced in the matrix"
ok "contracts: heartbeat-tier1, MANIFEST, nested CI host, matrix enforced"

echo "OK: fleet-failed-command-flagged: rc canary, grep/ls/which/git no-match exemption, auto-file dedupe, closed-dedup reopen, in-flight grace guard, observe-to-close"
