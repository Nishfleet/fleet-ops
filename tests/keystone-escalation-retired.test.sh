#!/usr/bin/env bash
# tests/keystone-escalation-retired.test.sh
#
# fleet-ops#6073: the vestigial #1133 keystone-escalation branch.
#
# #6032 had already deleted the analogous special case from bin/pi-issue-run.
# bin/pi-packet-run (~line 100) and bin/agent-cron-run (~line 181) still
# carried the remainder: a `difficulty: keystone` branch that, when the seat
# picker returned empty, kept the tried-seats file (pi-issue-run reset it) and
# exited 1 on the theory that OnFailure would summon a senior conference. The
# issue's ask was the #6032 shape: delete the special cases, delete the ignored
# `$tried_file` second argument at the pi-packet-run `litellm_seat` call site,
# and pin the replacement behaviour with a test.
#
# The 2026-09-18 rail collapse answered the deletion half the hard way: the
# wrapper layer itself went away, taking the branch and the call site with it.
#   - bin/pi-packet-run + bin/pi-issue-run deleted in ca33faa96 ("the unit IS
#     the worker"), where seat rotation became the LiteLLM proxy group.
#   - bin/agent-cron-run deleted in 72b38e857 (deploy-cluster cut).
#   - lib/litellm-seat.sh (the picker that owned the ignored argument) deleted
#     in the same glue sweep, so `litellm_seat` and its second argument no
#     longer exist to call.
# What was never done is the issue's second half: a test that PINS that state,
# so the branch cannot quietly return. Deleting code does not prevent its
# re-introduction; that is exactly the #6032 drift this issue was filed about.
# This file is that pin.
#
# SCOPE — deliberately narrow, and why.
#   This test pins the PRE-COLLAPSE ARTIFACTS: the wrappers, the seat-availability
#   branch shape, the ignored `$tried_file` argument and the tried-seats
#   bookkeeping. It does NOT rule that keystone escalation may never exist.
#   Whether a keystone two-strike escalation should exist on the CURRENT rail
#   (pi-issue@.service + the LiteLLM proxy, with no wrapper and no seat picker)
#   is fleet-ops#6105's rail-design call — that issue is `priority`, still open,
#   and its target (bin/pi-issue-run, tests/keystone-routing.test.sh,
#   lib/litellm-seat.sh) is likewise deleted. So this file bans the retired
#   shape only where it can still take its old form: a revived carrier wrapper,
#   a two-argument seat call, and tried-seats file handling. A rail-native
#   escalation built on the proxy is free to land; it will not trip this test.
#
# The lock has three parts:
#   A. the three carrier wrappers stay absent, and the retired seat picker has
#      no definition — so the branch and its call site have nowhere to live;
#   B. no live surface reintroduces the ignored two-argument seat call or the
#      tried-seats bookkeeping the branch keyed off;
#   C. the mechanisms that actually hold a walled worker down on the new rail
#      stay intact — the proxy's worker-group fallbacks (a walled worker group
#      fails LOUDLY; it must never silently fall through to the prose-only
#      senior bridge, which returns tools=0 and exits 0 — the 2026-09-18
#      outage) and systemd's own retry + OnFailure summon.
# Plus a fixture section that proves the detector goes RED on the real
# pre-deletion bytes, so part B has teeth rather than being a vacuous grep.
#
# Hosted by the P14 glob host (tests/p14-test-listing-gate.test.sh, #5889), so
# a worker App token needs no workflow edit to run it.
#
# Hermetic: reads tracked files + python3/yaml; the one history read is guarded
# with a named SKIP. No network, no systemd, no gh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
skip() { echo "SKIP: $*"; }

# ---------------------------------------------------------------------------
# The retired drift shape. ERE, matched against live code surfaces only.
#
#   litellm_seat X Y      a two-token call = the ignored second argument
#   tried_file/tried_seats the rotation state the branch chose to keep
#
# Written without a bracket class on purpose: this file is NOT in the scan set
# (the scan is bin/ lib/ libexec/ .github/scripts/), and
# tests/pick-seat-freeze.test.sh's frozen signature — pick_sea[t], seat-li[b],
# ram_governor_ca[p], active_ram_charg[e], ram_gb_per_worke[r] — shares no term
# with any literal below, so this file cannot newly match that freeze. The
# `litellm_seat` literal is the retired picker name; a scan of this file would
# only self-match, and this file is excluded by name in the scan helper.
SHAPE='litellm_seat[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]|tried_file|tried_seats'

# keystone_escalation_hits ROOT -> matching lines on stdout (empty = clean).
# Reusable so the fixture section below can prove the teeth on a scratch tree.
keystone_escalation_hits() {
    local root="$1" dirs=() d
    for d in bin lib libexec .github/scripts; do
        [[ -d "$root/$d" ]] && dirs+=("$root/$d")
    done
    (( ${#dirs[@]} > 0 )) || return 0
    grep -rEn "$SHAPE" "${dirs[@]}" 2>/dev/null || true
}

# --- A. the carrier wrappers are gone --------------------------------------
# These three files WERE the branch. While they are absent it cannot exist.
for w in bin/pi-packet-run bin/agent-cron-run bin/pi-issue-run; do
    [[ ! -e "$repo_root/$w" ]] \
        || fail "A. $w is back — it was the carrier of the retired #1133 keystone branch (ca33faa96 / 72b38e857); if a restore is intended, that is fleet-ops#6105's rail-design call, not a silent re-add"
done
ok "A. the three keystone-branch carriers (pi-packet-run, agent-cron-run, pi-issue-run) are absent"

# The picker the call site targeted is gone too, so the ignored second
# argument has nothing left to be passed to. Path split so this file stays
# outside the retired-name scan in tests/pick-seat-freeze.test.sh.
[[ ! -f "$repo_root/lib/litellm""-seat.sh" ]] \
    || fail "A. lib/litellm-seat.sh is back — the deleted picker owned the ignored second argument"
if grep -rEq '(^|[^A-Za-z_])litellm_seat[[:space:]]*\(' \
        "$repo_root/bin" "$repo_root/lib" "$repo_root/libexec" 2>/dev/null; then
    fail "A. a litellm_seat definition is back under bin/ lib/ or libexec/ — the proxy owns seat selection now"
fi
ok "A. lib/litellm-seat.sh absent and no litellm_seat definition remains"

# --- B. no live surface reintroduces the retired drift ---------------------
hits="$(keystone_escalation_hits "$repo_root")"
if [[ -n "$hits" ]]; then
    {
        echo "FAIL: B. the retired #1133 keystone-seat drift is back in live code:"
        printf '%s\n' "$hits"
        echo "The ignored \$tried_file second argument and tried-seats file handling went"
        echo "with bin/pi-packet-run, bin/agent-cron-run and lib/litellm-seat.sh. On the"
        echo "current rail the proxy group fallbacks + systemd OnFailure own that path"
        echo "(fleet-ops#6073)."
    } >&2
    exit 1
fi
ok "B. no two-argument seat call and no tried-seats handling in bin/ lib/ libexec/ .github/scripts/"

# --- C1. the proxy owns the walled-worker behaviour -----------------------
# The walled failure mode the keystone branch used to paper over is now the
# router's: a worker group that is entirely walled must fall back to the OTHER
# worker group, never to a prose-only group. Falling through to `senior` is
# the 2026-09-18 outage (the devin bridge never forwards `tools`, so every
# worker packet scored tools=0 and exited 0 while 100+ issues sat untouched).
# tests/forced-bad-deployment-replay.test.sh pins the full fallback matrix;
# this block re-derives the one property that matters here directly from the
# yaml, so the tombstone stands on its own if that drill ever moves.
command -v python3 >/dev/null 2>&1 || fail "C1. python3 missing"
python3 - "$repo_root/config/litellm-proxy.yaml" <<'PY'
import sys
try:
    import yaml
except ImportError:
    print("FAIL: C1. python3 yaml module missing"); sys.exit(1)

cfg = yaml.safe_load(open(sys.argv[1]))
models = cfg.get("model_list") or []
rs = cfg.get("router_settings") or {}
groups = {d["model_name"] for d in models}
fb = rs.get("fallbacks") or []

bad = []
for g in ("worker-cheap", "worker-capable", "senior"):
    if g not in groups:
        bad.append(f"model group {g} is missing from model_list")

chain = {}
for entry in fb:
    if not isinstance(entry, dict):
        bad.append(f"fallback entry is not a mapping: {entry!r}")
        continue
    for src, hops in entry.items():
        chain.setdefault(src, list(hops))

# every hop must exist: a dead-end fallback is a walled group that dies
# instead of failing over.
for src, hops in chain.items():
    for hop in hops:
        if hop not in groups:
            bad.append(f"fallback {src} -> {hop}: hop is not a defined group")

WORKERS = ("worker-cheap", "worker-capable")
PROSE = ("senior", "judge", "worker-private")

for w in WORKERS:
    hops = chain.get(w)
    if not hops:
        bad.append(f"worker group {w} has no fallback chain — a walled {w} dead-ends")
        continue
    other = [x for x in WORKERS if x != w][0]
    if hops != [other]:
        bad.append(f"worker fallback drift: {w} -> {hops}, want [{other}]")
    for hop in hops:
        if hop in PROSE:
            bad.append(
                f"{w} falls back to prose-only group {hop}: its bridge cannot return "
                f"tool_calls, so a walled worker silently exits 0 (the 2026-09-18 outage)"
            )

if chain.get("senior") != ["worker-capable"]:
    bad.append(f"senior fallback drift: {chain.get('senior')}, want ['worker-capable']")

if bad:
    for b in bad:
        print(f"FAIL: C1. {b}")
    sys.exit(1)

print("OK: C1. worker groups fall back to each other (never to a prose-only group); every fallback hop resolves")
PY

# --- C2. systemd owns retry + the failure summon --------------------------
unit="$repo_root/systemd/pi-issue@.service"
[[ -f "$unit" ]] || fail "C2. missing systemd/pi-issue@.service"
grep -q '^OnFailure=pi-issue-failed@%i\.service$' "$unit" \
    || fail "C2. pi-issue@.service lost its OnFailure= failure summon"
[[ -f "$repo_root/systemd/pi-issue-failed@.service" ]] \
    || fail "C2. the unit systemd summons on failure (pi-issue-failed@.service) does not exist"
ok "C2. a walled/failed worker is summoned: OnFailure=pi-issue-failed@%i.service resolves to a real unit"

# Retry budget is systemd's, not a bash counter — the branch this file pins
# was a hand-rolled stand-in for it.
grep -q '^Restart=on-failure$' "$unit"        || fail "C2. pi-issue@.service lost Restart=on-failure"
grep -q '^RestartSec=' "$unit"                || fail "C2. pi-issue@.service lost RestartSec="
grep -q '^StartLimitIntervalSec=' "$unit"     || fail "C2. pi-issue@.service lost StartLimitIntervalSec="
grep -q '^StartLimitBurst=' "$unit"           || fail "C2. pi-issue@.service lost StartLimitBurst="
ok "C2. the retry loop is systemd's own (Restart=on-failure, RestartSec=, StartLimitIntervalSec=/Burst=)"

# The unit IS the worker: ExecStart names the proxy group directly, so there
# is no wrapper layer left for a keystone branch to hide in.
exec_line="$(grep -m1 '^ExecStart=' "$unit" || true)"
[[ -n "$exec_line" ]] || fail "C2. pi-issue@.service has no ExecStart"
grep -q -- '--provider litellm --model worker-capable' <<<"$exec_line" \
    || fail "C2. pi-issue@.service ExecStart no longer targets the worker-capable proxy group"
if grep -Eq '\.local/bin/(pi-issue-run|pi-packet-run|agent-cron-run)' <<<"$exec_line"; then
    fail "C2. pi-issue@.service ExecStart invokes a retired wrapper again"
fi
ok "C2. ExecStart targets the worker-capable proxy group directly — no wrapper layer to carry a branch"

# --- D. fixtures: the detector has teeth ---------------------------------
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# D1. the real pre-deletion bytes, when history is available. This is the
# honest replay: the detector must fire on the exact code #6073 named.
pre="$(git -C "$repo_root" show 'ca33faa96^:bin/pi-packet-run' 2>/dev/null || true)"
if [[ -z "$pre" ]]; then
    skip "D1. ca33faa96^:bin/pi-packet-run is not in this clone's history (shallow checkout?)"
else
    mkdir -p "$scratch/real/bin"
    printf '%s\n' "$pre" >"$scratch/real/bin/pi-packet-run"
    real_hits="$(keystone_escalation_hits "$scratch/real")"
    [[ -n "$real_hits" ]] \
        || fail "D1. detector did NOT fire on the real pre-deletion bin/pi-packet-run — part B is vacuous"
    grep -q 'litellm_seat' <<<"$real_hits" \
        || fail "D1. detector fired but never named the seat call; got: $real_hits"
    grep -q 'tried_file' <<<"$real_hits" \
        || fail "D1. detector fired but never named the tried-seats handling; got: $real_hits"
    ok "D1. RED on the real pre-deletion bin/pi-packet-run (two-arg seat call + tried-seats both named)"
fi

cron="$(git -C "$repo_root" show '72b38e857^:bin/agent-cron-run' 2>/dev/null || true)"
if [[ -z "$cron" ]]; then
    skip "D1b. 72b38e857^:bin/agent-cron-run is not in this clone's history (shallow checkout?)"
else
    mkdir -p "$scratch/realcron/bin"
    printf '%s\n' "$cron" >"$scratch/realcron/bin/agent-cron-run"
    cron_hits="$(keystone_escalation_hits "$scratch/realcron")"
    [[ -n "$cron_hits" ]] \
        || fail "D1b. detector did NOT fire on the real pre-deletion bin/agent-cron-run"
    ok "D1b. RED on the real pre-deletion bin/agent-cron-run"
fi

# D2. synthetic fixture: the two-argument seat call alone must fire, so the
# ignored-$tried_file half of the issue is covered even where the rest of the
# branch shape is absent (the exact drift #6032 deleted).
mkdir -p "$scratch/twoarg/bin"
cat >"$scratch/twoarg/bin/pi-packet-run" <<'FIXTURE'
#!/usr/bin/env bash
_lit_group="worker-cheap"
seat=$(litellm_seat "$_lit_group" "$tried_file" || true)
FIXTURE
two_hits="$(keystone_escalation_hits "$scratch/twoarg")"
[[ -n "$two_hits" ]] \
    || fail "D2. detector did NOT fire on a two-argument litellm_seat call site"
grep -q 'litellm_seat' <<<"$two_hits" \
    || fail "D2. detector fired but never named the call site; got: $two_hits"
ok "D2. RED on a two-argument litellm_seat call (the ignored \$tried_file argument)"

# D3. GREEN on a clean tree — the detector is not a blanket greps-for-words.
mkdir -p "$scratch/clean/bin" "$scratch/clean/lib" "$scratch/clean/systemd"
cat >"$scratch/clean/bin/clean-thing" <<'FIXTURE'
#!/usr/bin/env bash
# a walled seat is a loud proxy error; systemd retries the unit.
exec pi --print --provider litellm --model worker-capable
FIXTURE
# A rail-native keystone escalation must NOT trip this detector (fleet-ops#6105):
# the proxy/unit layer is free to distinguish difficulties.
cat >"$scratch/clean/lib/keystone-rail-thing.sh" <<'FIXTURE'
#!/usr/bin/env bash
# rail-native escalation: proxy fallback + systemd OnFailure, no wrapper/seat picker.
if [[ "${PI_PACKET_DIFFICULTY:-}" == "keystone" ]]; then
    echo "KEYSTONE ESCALATION: proxy owns the retry" >&2
fi
FIXTURE
clean_hits="$(keystone_escalation_hits "$scratch/clean")"
[[ -z "$clean_hits" ]] \
    || fail "D3. detector false-positived on a clean fixture: $clean_hits"
ok "D3. GREEN on a clean fixture, including a rail-native keystone escalation on the proxy/unit layer"

# D4. the detector fires on the tried-seats bookkeeping alone, independent of
# the marker — so the pin does not depend on one literal.
mkdir -p "$scratch/tried/lib"
cat >"$scratch/tried/lib/thing.sh" <<'FIXTURE'
#!/usr/bin/env bash
tried_file="${tried_seats_path:-/tmp/tried}"
FIXTURE
tried_hits="$(keystone_escalation_hits "$scratch/tried")"
[[ -n "$tried_hits" ]] \
    || fail "D4. detector did NOT fire on tried-seats bookkeeping"
ok "D4. RED on tried-seats file handling alone"

echo
echo "ALL OK: the #6073 keystone-seat drift is retired and pinned"
exit 0
