#!/usr/bin/env bash
# tests/worker-prompt-systemd-run.test.sh
#
# fleet-ops#350: prompts/worker.md (the packet every pi-issue@* worker loads)
# never mentioned pi-systemd-run, so `nohup pi ... &` stayed the easy wrong
# path for session-outliving work. README and prompts/heartbeat.md already
# ban nohup and document pi-systemd-run; #54 fixed home/vault/codex routing
# docs but left the worker packet out of scope. This lock closes that gap.
#
# Invariants:
#   1. prompts/worker.md names pi-systemd-run.
#   2. prompts/worker.md carries a copy-paste pi-systemd-run example with a
#      `pi --print --provider` argv (not a Claude argv) — matches heartbeat.md.
#   3. `nohup` in worker.md appears only in a prohibition context (or not at
#      all). A future edit that adds `nohup` as a recommended path goes red.
#   4. worker.md bans a trailing `&` for session-outliving work.
#   5. CI host exists (fleet-ops#82): this file is listed in ci.yml OR
#      invoked from a test that already is (currently pi-issue-start.test.sh).
#      Workers cannot push .github/workflows/**, so the host rides an existing
#      verify-command line — same Nish-scope wiring gap pattern as #134.
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
prompt="$repo_root/prompts/worker.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$prompt" ]] || fail "missing $prompt"

# --- 1. names pi-systemd-run ------------------------------------------------
grep -q 'pi-systemd-run' "$prompt" \
  || fail "worker.md must name pi-systemd-run so nohup is not the path of least resistance (fleet-ops#350)"
ok "names pi-systemd-run"

# --- 2. copy-paste example uses a pi argv, not a Claude argv ----------------
# heartbeat.md's pi-path example is:
#   pi-systemd-run --unit <packet> --stdin <packet>.md -- pi --print --provider <p> --model <m>
# A Claude argv (claude -p --model ...) is the escalation shape, not the
# default worker spawn. The worker packet must show the pi path.
grep -Eq 'pi-systemd-run --unit [^ ]+ --stdin [^ ]+ -- pi --print --provider [^ ]+ --model [^ ]+' "$prompt" \
  || fail "worker.md must carry a pi-systemd-run example with a pi --print --provider --model argv (fleet-ops#350)"
ok "copy-paste example uses a pi --print --provider --model argv"

# --- 3. nohup only in a prohibition context (or not at all) -----------------
# Every line mentioning nohup must also carry a prohibition cue. Accept the
# cues README/heartbeat already use: never, not, dies, forbid, refus, avoid,
# do not, instead. A bare `nohup pi ... &` recommendation fails.
prohibition_re='never|not|dies|forbid|refus|avoid|instead'
violators=0
while IFS= read -r line; do
  if ! printf '%s' "$line" | grep -Eq "$prohibition_re"; then
    echo "non-prohibition nohup line: $line" >&2
    violators=$((violators + 1))
  fi
done < <(grep -n 'nohup' "$prompt" || true)
[[ "$violators" -eq 0 ]] \
  || fail "worker.md has $violators nohup line(s) outside a prohibition context (fleet-ops#350)"
ok "nohup appears only in a prohibition context (or not at all)"

# --- 4. bans a trailing & for session-outliving work -----------------------
# README/heartbeat both pair the nohup ban with a trailing-& ban. The worker
# packet must too — a bare `pi ... &` reaps the same way nohup does.
grep -Eq 'trailing ?`?&|never.*&.*die|&.*die' "$prompt" \
  || fail "worker.md must ban a trailing & for session-outliving work (fleet-ops#350)"
ok "bans a trailing & for session-outliving work"

# --- 5. CI host (fleet-ops#82) ---------------------------------------------
# Workers have no Workflows permission, so this file cannot be added to ci.yml
# verify-command by a worker. It rides an existing CI-listed test instead.
# Currently hosted by pi-issue-start.test.sh (which already hosts
# exec-review-prompt.test.sh and pstack-worker-prompt.test.sh).
ci_yml="$repo_root/.github/workflows/ci.yml"
host="$repo_root/tests/pi-issue-start.test.sh"
listed=0
hosted=0
grep -Fq 'bash tests/worker-prompt-systemd-run.test.sh' "$ci_yml" && listed=1
grep -Fq 'bash "$here/worker-prompt-systemd-run.test.sh"' "$host" && hosted=1
if [[ "$listed" -eq 0 && "$hosted" -eq 0 ]]; then
  fail "worker-prompt-systemd-run.test.sh has no CI host (fleet-ops#82): list it in ci.yml or invoke it from pi-issue-start.test.sh"
fi
ok "CI host exists (ci.yml listed=$listed pi-issue-start hosted=$hosted)"

# Empty-host drill: an empty ci.yml + empty host must miss both, proving the
# check is not trivially true.
empty=$(mktemp -d)
trap 'rm -rf "$empty"' EXIT
: >"$empty/ci.yml"
: >"$empty/host.test.sh"
empty_listed=0
empty_hosted=0
grep -Fq 'bash tests/worker-prompt-systemd-run.test.sh' "$empty/ci.yml" && empty_listed=1
grep -Fq 'bash "$here/worker-prompt-systemd-run.test.sh"' "$empty/host.test.sh" && empty_hosted=1
[[ "$empty_listed" -eq 0 && "$empty_hosted" -eq 0 ]] \
  || fail "empty-host drill must miss both hosts (listed=$empty_listed hosted=$empty_hosted)"
ok "empty-host drill trips (neither host matches empty files)"

echo "OK: worker.md routes session-outliving work through pi-systemd-run"
