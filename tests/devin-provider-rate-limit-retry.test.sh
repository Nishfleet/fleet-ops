#!/usr/bin/env bash
# tests/devin-provider-rate-limit-retry.test.sh
#
# A Devin "Reached overall message rate limit ... reset in N minutes" is a
# pause, not a worker death. The provider waits out the advertised reset and
# re-runs the same packet in the same pi session, bounded by pi-issue-run's
# hang watchdog (PI_HANG_TIMEOUT_S, exported for the extension).
#
# Population that motivated this (archived worker stderr, 2026-09-10/11):
# 457 runs died, 114 on this exact message, 144 Devin deaths after >5 min of
# real work; 1 run ended clean. Nish 2026-09-11: no duct tape — class fix.
#
# 1. Pure-logic unit checks on rate-limit.ts (node --experimental-strip-types).
# 2. Lock: index.ts routes non-zero exits through the planner; the spawnSync
#    timeout literal the provider-timeout suite greps is still present exactly
#    once and nothing later in the file can shadow it.
# 3. Lock: bin/pi-issue-run exports PI_HANG_TIMEOUT_S; MANIFEST installs rate-limit.ts.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
rl="$repo_root/template/extensions/devin-provider/rate-limit.ts"
idx="$repo_root/template/extensions/devin-provider/index.ts"
[[ -f "$rl" ]] || fail "missing $rl"
command -v node >/dev/null || fail "node missing"

# --- 1. unit checks ---------------------------------------------------------
node --experimental-strip-types --no-warnings - "$rl" <<'JS'
const path = process.argv[2];
const m = await import(path);
const assert = (c, msg) => { if (!c) { console.error("FAIL: " + msg); process.exit(1); } };
const devin = 'Devin exited with code 1: Error: Agent error: Reached overall message rate limit. Please try again later. Your limit will reset in 9 minutes. (trace ID: e679cec3aabf3ffb31833070bf418d42): {';
assert(m.isDevinRateLimit(devin), "devin phrasing recognised");
assert(!m.isDevinRateLimit("Error: D1 unavailable"), "unrelated error not a rate limit");
assert(m.parseDevinResetSeconds(devin) === 540, "9 minutes -> 540s");
assert(m.parseDevinResetSeconds("limit will reset in 30 seconds") === 30, "30 seconds -> 30");
assert(m.parseDevinResetSeconds("resets in 2 hours") === 7200, "2 hours -> 7200");
assert(m.parseDevinResetSeconds("retry-after: 480") === 480, "retry-after -> 480");
assert(m.parseDevinResetSeconds("no window here") === null, "no window -> null");
const base = { maxAttempts: 3, watchdogS: 2520, minWaitS: 30, maxWaitS: 1200, minRunS: 600, attemptTimeoutMsDefault: 2400000 };
// the real 2026-09-11 case: died at 759s with "reset in 9 minutes"
let p = m.planDevinRetry({ ...base, attempt: 1, elapsedS: 759, resetS: 540 });
assert(p.retry === true, "first hit at 759s resumes");
assert(p.waitS === 555, "waits reset + 15s slack (got " + p.waitS + ")");
assert(p.attemptTimeoutMs === (2520 - 759 - 555 - 60) * 1000, "resumed attempt bounded by remaining watchdog budget (got " + p.attemptTimeoutMs + ")");
p = m.planDevinRetry({ ...base, attempt: 3, elapsedS: 100, resetS: 60 });
assert(p.retry === false && /exhausted/.test(p.reason), "attempt cap respected");
p = m.planDevinRetry({ ...base, attempt: 1, elapsedS: 2000, resetS: 540 });
assert(p.retry === false && /watchdog budget/.test(p.reason), "no resume when the watchdog would kill it mid-run");
p = m.planDevinRetry({ ...base, attempt: 1, elapsedS: 10, resetS: null });
assert(p.retry === true && p.waitS === 45, "no advertised window -> minWait + slack (got " + p.waitS + ")");
p = m.planDevinRetry({ ...base, attempt: 1, elapsedS: 10, resetS: 7200 });
assert(p.retry === false, "a 2h window is not waited inside a 42-min session");
p = m.planDevinRetry({ ...base, attempt: 1, elapsedS: 10, resetS: 1500 });
assert(p.retry === false && /exceeds max wait/.test(p.reason), "a 25-min window is not retried under a 20-min cap");
p = m.planDevinRetry({ ...base, attempt: 1, elapsedS: 10, resetS: 1100 });
assert(p.retry === true && p.waitS === 1115, "an 18-min window waits reset + slack (got " + p.waitS + ")");
console.log("OK: rate-limit.ts unit checks (11)");
JS

# --- 2. provider wiring locks ----------------------------------------------
grep -q 'from "./rate-limit.ts"' "$idx" || fail "index.ts does not import ./rate-limit.ts"
grep -q 'planDevinRetry(' "$idx" || fail "index.ts never calls planDevinRetry"
grep -q 'isDevinRateLimit(failureText)' "$idx" || fail "index.ts does not classify the failure text"
grep -q 'RESUME_NOTE + prompt' "$idx" || fail "resumed attempt must carry the RESUME NOTE"
grep -q 'envInt("PI_HANG_TIMEOUT_S", 2520)' "$idx" || fail "watchdog bound must come from PI_HANG_TIMEOUT_S with the 2520 default"
n=$(grep -cE 'timeout: *2400000' "$idx" || true)
[[ "$n" == "1" ]] || fail "expected exactly one 'timeout: 2400000' literal for provider-timeout.test.sh, found $n"
last=$(grep -oE 'timeout: *[0-9]+' "$idx" | tail -n1 | grep -oE '[0-9]+')
[[ "$last" == "2400000" ]] || fail "the last numeric 'timeout:' in index.ts must be 2400000 (provider-timeout greps the last one), got $last"
ok "index.ts wiring + timeout literal locks"

# --- 3. runner + manifest locks ----------------------------------------------
grep -qE '^export PI_HANG_TIMEOUT_S$' "$repo_root/bin/pi-issue-run" || fail "bin/pi-issue-run must export PI_HANG_TIMEOUT_S for the extension"
grep -Fxq 'template/extensions/devin-provider/rate-limit.ts /home/nish/.pi/agent/extensions/devin-provider/rate-limit.ts' "$repo_root/MANIFEST" || fail "MANIFEST missing rate-limit.ts install line"
ok "pi-issue-run export + MANIFEST line"
echo "PASS: devin-provider-rate-limit-retry"
