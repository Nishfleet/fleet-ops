#!/usr/bin/env bash
# tests/lane-fault-requeue-rail.test.sh
#
# fleet-ops#5741: pin the CURRENT rail's transient-overload lane-fault
# requeue path, and ban the retired #5963-era shape from quietly returning.
#
# The seam: an auditor hand-requeued a `pi-issue@fleet-ops-2073` worker that
# died on a transient 503 `overloaded_error` — diagnose the lane fault, bench
# the seat, hand-add an `after:`-gated row to the READY-WORK.md paper ledger.
# Mechanism #5743 / PR #5963 first automated that inside
# bin/pi-issue-failed-reap (a bench-aware `until:` line appended to the
# reclaim-cooldown marker) plus lib/pi-intake-tick.sh (the reader that honoured
# it). The 2026-09-18 rail collapse (ca33faa96, "the unit IS the worker")
# deleted both carriers — deliberately, because the capability moved into
# three stock layers:
#
#   bench   -> the LiteLLM router: cooldown_time/allowed_fails in
#              config/litellm-proxy.yaml keep a failed deployment out of the
#              group until the bench expires. That IS the `after:` gate,
#              enforced at dispatch time on the seat instead of on paper.
#   release -> systemd: Restart= retries in-unit; on exhaustion
#              OnFailure=pi-issue-failed@ drops the claim branch and flips the
#              label back to agent-ready.
#   requeue -> prompts/intake.md on the pi-intake@.timer cadence (plus the
#              worker's own ExecStopPost refill) re-claims agent-ready issues
#              and starts a fresh worker unit.
#
# This file pins that state so neither half drifts:
#   A. the retired carriers stay absent;
#   B. no live code surface reintroduces the retired marker/ledger grammar;
#   C. the current-rail links above stay intact —
#      C1. pi-issue@.service retries with backoff and summons the release
#          unit on exhaustion,
#      C2. pi-issue-failed@.service still performs the two release calls,
#      C3. the router bench knobs are still configured,
#      C4. prompts/intake.md still carries the agent-ready re-dispatch path;
#   D. fixture teeth: the section-B scan goes RED on the real retired bytes.
#
# SCOPE: this pins the requeue rail, not a verdict on whether a future
# per-issue `until:` gate should exist — that is a rail-design call of the
# fleet-ops#6105 class. A rail-native mechanism on the proxy/systemd layers
# lands free of this test; what is banned is resurrecting the deleted carrier
# files or their marker grammar inside live code surfaces.
#
# Hermetic: tracked files + a scratch fixture tree only. No gh, no systemd,
# no network, no writes outside the scratch dir.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# ---------------------------------------------------------------------------
# The retired #5963 shape, matched against live code surfaces only. The same
# literals survive in systemd/*.service comments as tombstone documentation,
# so systemd/ is deliberately NOT in the scan set.
SHAPE='pi-issue-failed-reap|pi-intake-tick|reclaim.cooldown|TRANSIENT-OVERLOAD-REQUEUE|skipped-reclaim-cooldown|bench_until'

retired_hits() { # $1 = tree root -> matching lines on stdout (empty = clean)
    local root="$1" dirs=() d
    for d in bin lib libexec .github/scripts prompts; do
        [[ -d "$root/$d" ]] && dirs+=("$root/$d")
    done
    (( ${#dirs[@]} > 0 )) || return 0
    grep -rEn "$SHAPE" "${dirs[@]}" 2>/dev/null || true
}

# --- A. the retired carriers stay absent ------------------------------------
for w in bin/pi-issue-failed-reap lib/pi-intake-tick.sh \
         tests/pi-issue-failed-reap-overload-requeue.test.sh; do
    [[ ! -e "$repo_root/$w" ]] \
        || fail "A. $w is back — it carried the retired reclaim-cooldown ledger (deleted in ca33faa96); a re-add is a rail-design decision, not a silent restore"
done
ok "A. the #5963 carriers (pi-issue-failed-reap, pi-intake-tick.sh, their test) are absent"

# --- B. no live surface reintroduces the retired grammar --------------------
hits="$(retired_hits "$repo_root")"
if [[ -n "$hits" ]]; then
    {
        echo "FAIL: B. the retired lane-fault requeue shape is back in live code:"
        printf '%s\n' "$hits"
        echo "The reclaim-cooldown marker grammar (until:/bench_until), the"
        echo "TRANSIENT-OVERLOAD-REQUEUE triage post and the two carrier files"
        echo "went with ca33faa96. On the current rail the router cooldown owns"
        echo "the bench and systemd + intake own release and re-dispatch."
    } >&2
    exit 1
fi
ok "B. no retired requeue grammar in bin/ lib/ libexec/ .github/scripts/ prompts/"

# --- C1. systemd owns retry-then-release ------------------------------------
unit="$repo_root/systemd/pi-issue@.service"
[[ -f "$unit" ]] || fail "C1. $unit missing"
grep -q '^OnFailure=pi-issue-failed@%i\.service$' "$unit" \
    || fail "C1. pi-issue@.service lost OnFailure=pi-issue-failed@%i.service — a dead worker would hold its claim forever"
grep -q '^Restart=on-failure$' "$unit" \
    || fail "C1. pi-issue@.service lost Restart=on-failure — no in-unit retry of a transient lane fault"
grep -q '^StartLimitBurst=' "$unit" \
    || fail "C1. pi-issue@.service lost StartLimitBurst= — the claim loop is unbounded"
grep -q '^TimeoutStartSec=' "$unit" \
    || fail "C1. pi-issue@.service lost TimeoutStartSec= — the hang-kill is gone"
ok "C1. pi-issue@.service retries then summons pi-issue-failed@ on exhaustion"

# --- C2. the release unit still performs the release -------------------------
rel="$repo_root/systemd/pi-issue-failed@.service"
[[ -f "$rel" ]] || fail "C2. $rel missing — OnFailure would summon nothing"
grep -q 'git/refs/heads/claim/issue-' "$rel" \
    || fail "C2. pi-issue-failed@.service no longer deletes the claim branch"
grep -q -- '--add-label agent-ready' "$rel" \
    || fail "C2. pi-issue-failed@.service no longer re-arms agent-ready"
grep -q -- '--remove-label agent-in-progress' "$rel" \
    || fail "C2. pi-issue-failed@.service no longer clears agent-in-progress"
ok "C2. pi-issue-failed@.service drops the claim branch and re-arms agent-ready"

# --- C3. the router owns the bench -------------------------------------------
yaml="$repo_root/config/litellm-proxy.yaml"
[[ -f "$yaml" ]] || fail "C3. $yaml missing"
router_block="$(awk '/^router_settings:/{f=1;next} /^[a-z_]+:/{f=0} f' "$yaml")"
grep -q 'cooldown_time:' <<<"$router_block" \
    || fail "C3. router_settings lost cooldown_time — a dead seat is offered again immediately (the hand bench is gone)"
grep -q 'allowed_fails:' <<<"$router_block" \
    || fail "C3. router_settings lost allowed_fails — the router no longer benches on failure"
grep -q 'worker-cheap.*worker-capable\|worker-capable.*worker-cheap' <<<"$router_block" \
    || fail "C3. the worker-group fallbacks are gone — a benched group cannot fail over"
ok "C3. litellm-proxy.yaml still benches failed deployments (cooldown_time + allowed_fails + group fallback)"

# --- C4. intake owns the re-dispatch -----------------------------------------
intake="$repo_root/prompts/intake.md"
[[ -f "$intake" ]] || fail "C4. $intake missing"
grep -q 'agent-ready' "$intake" \
    || fail "C4. intake.md no longer picks agent-ready issues — released work is never re-claimed"
grep -q -- '--add-label agent-in-progress' "$intake" \
    || fail "C4. intake.md no longer flips agent-ready -> agent-in-progress on claim"
grep -q 'systemctl --user start' "$intake" \
    || fail "C4. intake.md no longer starts a worker unit on claim"
ok "C4. prompts/intake.md still re-claims agent-ready issues and spawns a worker"

# --- D. fixture teeth: the scan goes RED on the real retired bytes -----------
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/lib" "$tmp/prompts"
cat >"$tmp/bin/pi-issue-failed-reap" <<'EOF'
#!/usr/bin/env bash
# retired carrier bytes (shape only): the reclaim-cooldown ledger write
bench_until=$(date -d "+${BENCH_S:-900} seconds" -Is)
printf 'until: %s\n' "$bench_until" >>"$RECLAIM_COOLDOWN_MARKER"
echo "TRANSIENT-OVERLOAD-REQUEUE posted"
EOF
cat >"$tmp/lib/fake.sh" <<'EOF'
skipped-reclaim-cooldown-bench: skip issue until bench expires
EOF
fixture_hits="$(retired_hits "$tmp")"
[[ -n "$fixture_hits" ]] \
    || fail "D. the section-B scan is vacuous — it missed real retired bytes in the fixture tree"
ok "D. detector goes RED on the retired carrier + marker grammar ($(wc -l <<<"$fixture_hits") hit lines)"

echo "all lane-fault requeue rail checks passed"
