#!/usr/bin/env bash
# tests/pi-issue-start-packet-regen.test.sh
#
# fleet-ops#1451: pi-issue-start is the dispatch path for re-dispatch onto a
# surviving claim branch (intake re-claim that lost the race, or
# fleet-heartbeat-red-pr-repair on a RED PR with a dead worker). The reaper
# archives the .in packet when it releases a claim, but a re-dispatch does
# NOT go through intake's packet-write step — so a raw `systemctl start`
# hits a missing StandardInput=file and fails 208/STDIN (systemd opens stdin
# BEFORE ExecStartPre, so ExecStart cannot self-heal).
#
# This proves pi-issue-start regenerates the .in from the worker prompt +
# TARGET line before starting, with the keystone marker when the issue is a
# keystone, and that an existing packet is left untouched.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-issue-start"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t pi-issue-start-regen.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"

ISSUES_DIR="$scratch/issues"
mkdir -p "$ISSUES_DIR"
export PI_ISSUES_DIR="$ISSUES_DIR"

# Worker prompt stub: a real prompt is large; we only need the content to be
# reproducible and to verify it lands verbatim in the regenerated packet.
WORKER_PROMPT="$scratch/worker.md"
printf '# Pi fleet issue worker\n\nDo the work.\n' > "$WORKER_PROMPT"
export WORKER_PROMPT

# Fake systemctl: records calls, reports inactive / MainPID=0 so the wrapper
# proceeds to the start path.
stub_bin="$scratch/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
shift  # --user
printf '%s\n' "$*" >>"$FAKE_DIR/systemctl-calls"
case "$1" in
  is-active) echo inactive; exit 0 ;;
  show) echo 0; exit 0 ;;
  start) echo started; exit 0 ;;
  *) echo "unexpected systemctl: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$stub_bin/systemctl"
export FAKE_DIR="$scratch"
export SYSTEMCTL="$stub_bin/systemctl"

# Fake gh: emits a JSON blob the wrapper greps for "keystone". Default to a
# non-keystone issue; the keystone case overrides GH below.
cat >"$stub_bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$GH_OUT"
exit 0
FAKE
chmod +x "$stub_bin/gh"
export GH="$stub_bin/gh"
export PATH="$stub_bin:$PATH"
GH_OUT='{"title":"normal issue","body":"nothing special","labels":[]}'

# --- case 1: missing .in is regenerated, non-keystone, then start fires ---
: >"$scratch/systemctl-calls"
inst="fleet-ops-1149"
pkt="$ISSUES_DIR/${inst}.in"
[[ -e "$pkt" ]] && fail "precondition: $pkt should not exist yet"
out="$(GH_OUT="$GH_OUT" "$bin" "$inst")"
printf '%s\n' "$out" | grep -q 'REGENERATED missing packet' || fail "missing packet must be regenerated, got: $out"
[[ -f "$pkt" ]] || fail "packet file was not created at $pkt"
# Content: worker prompt + blank + TARGET line, no keystone marker.
head -1 "$pkt" | grep -q '^# Pi fleet issue worker' || fail "packet must start with worker prompt, got: $(head -1 "$pkt")"
grep -q '^difficulty: keystone' "$pkt" && fail "non-keystone issue must NOT carry the keystone marker"
tail -1 "$pkt" | grep -q "^TARGET: repo Nishfleet/fleet-ops issue 1149 unit pi-issue-fleet-ops-1149$" \
  || fail "packet must end with the TARGET line, got: $(tail -1 "$pkt")"
grep -q '^start ' "$scratch/systemctl-calls" || fail "must call systemctl start after regen, called=$(cat "$scratch/systemctl-calls")"
ok "missing non-keystone .in regenerated, then start fired"

# --- case 2: missing .in is regenerated WITH keystone marker ---
rm -f "$pkt"
: >"$scratch/systemctl-calls"
GH_OUT='{"title":"[keystone] big one","body":"critical","labels":[{"name":"keystone"}]}'
out="$(GH_OUT="$GH_OUT" "$bin" "$inst")"
printf '%s\n' "$out" | grep -q 'REGENERATED missing packet' || fail "keystone packet must be regenerated, got: $out"
[[ -f "$pkt" ]] || fail "keystone packet file was not created"
head -1 "$pkt" | grep -q '^difficulty: keystone$' || fail "keystone issue must carry the marker as line 1, got: $(head -1 "$pkt")"
grep -q '^TARGET: repo Nishfleet/fleet-ops issue 1149 unit pi-issue-fleet-ops-1149$' "$pkt" \
  || fail "keystone packet must still carry the TARGET line"
ok "missing keystone .in regenerated with marker, then start fired"

# --- case 3: existing .in is left untouched (no regen, no gh call) ---
rm -f "$pkt"
printf 'PRE-EXISTING PACKET CONTENT\n' > "$pkt"
pre_mtime="$(stat -c %Y "$pkt")"
: >"$scratch/systemctl-calls"
out="$(GH_OUT='{"title":"SHOULD-NOT-BE-READ","body":"x","labels":[]}' "$bin" "$inst")"
printf '%s\n' "$out" | grep -q 'REGENERATED' && fail "existing packet must NOT be regenerated, got: $out"
# Content unchanged.
[[ "$(cat "$pkt")" == "PRE-EXISTING PACKET CONTENT" ]] || fail "existing packet content was modified: $(cat "$pkt")"
grep -q '^start ' "$scratch/systemctl-calls" || fail "existing packet must still trigger start"
ok "existing .in left untouched, start fired"

# --- case 4: gh failure is non-fatal — packet written without marker ---
rm -f "$pkt"
: >"$scratch/systemctl-calls"
# gh that always exits non-zero
cat >"$stub_bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "gh: GraphQL rate limit" >&2
exit 1
FAKE
chmod +x "$stub_bin/gh"
out="$("$bin" "$inst" 2>"$scratch/err")" || fail "gh failure must NOT abort regen, exit=$?"
printf '%s\n' "$out" | grep -q 'REGENERATED missing packet' || fail "packet must be regenerated even when gh fails, got: $out"
[[ -f "$pkt" ]] || fail "packet must exist even when gh fails"
grep -q '^difficulty: keystone' "$pkt" && fail "gh-failed regen must not carry a stale keystone marker"
tail -1 "$pkt" | grep -q "^TARGET: repo Nishfleet/fleet-ops issue 1149 unit pi-issue-fleet-ops-1149$" \
  || fail "gh-failed regen must still carry the TARGET line"
ok "gh failure is non-fatal: packet regenerated without marker"

# --- case 5: unparseable instance aborts with exit 1, no packet, no start ---
rm -f "$ISSUES_DIR/garbage.in"
: >"$scratch/systemctl-calls"
if out="$("$bin" "garbage" 2>"$scratch/err")"; then
  fail "unparseable instance must exit non-zero, got: $out"
fi
grep -qi 'cannot parse' "$scratch/err" || fail "unparseable instance must log cannot-parse, got: $(cat "$scratch/err")"
[[ -e "$ISSUES_DIR/garbage.in" ]] && fail "unparseable instance must NOT write a packet"
grep -q '^start ' "$scratch/systemctl-calls" && fail "unparseable instance must NOT call start"
ok "unparseable instance aborts cleanly, no packet, no start"

# --- case 6: missing worker prompt aborts with exit 1 ---
rm -f "$pkt"
: >"$scratch/systemctl-calls"
export WORKER_PROMPT="$scratch/does-not-exist.md"
if out="$("$bin" "$inst" 2>"$scratch/err")"; then
  fail "missing worker prompt must exit non-zero, got: $out"
fi
grep -qi 'worker prompt not found' "$scratch/err" || fail "must log missing worker prompt, got: $(cat "$scratch/err")"
[[ -e "$pkt" ]] && fail "missing worker prompt must NOT write a packet"
grep -q '^start ' "$scratch/systemctl-calls" && fail "missing worker prompt must NOT call start"
ok "missing worker prompt aborts cleanly, no packet, no start"

echo "all pi-issue-start-packet-regen cases passed"
