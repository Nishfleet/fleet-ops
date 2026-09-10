# Plan — fleet-ops#4773 (re-entrancy: fix the merged #4998 mechanism)

## Context (manager investigation, 2026-09-10)

PR #4998 merged at 15:33Z for this issue but used "Relates to #4773" (not
"Closes"), so the issue stayed open and got re-claimed. The merged code is
the right shape (extends `libexec/alert-repair-dispatch`, no new organ), and
the termination tests pass — BUT the mechanism does NOT fire in production.

Root cause (proven): `prometheus-am-executor` provides `AMX_ALERT_<i>_START`
as a **Unix epoch integer** (e.g. `1789051780`), confirmed by every recent
packet file (`starts_at: 1789051780`). The merged `_slowburn_firing_seconds`
parses it as ISO 8601 (`%Y-%m-%dT%H:%M:%S`) → `ValueError` → returns `None` →
the caller treats unknown as "not past threshold" → `skip-short` every tick.

Live proof: the alert-repair actions.log shows the 15:52:27Z tick ran
"(slowburn file-or-link attempted)" but emitted NO `FILED`/`LINK` line. The
live `FleetSloSeatAvailSlowBurn` alert has been firing since
2026-09-08T09:51:03Z (2+ days) with zero linked critical-path claims — the
exact fault the issue's `metric:` names.

The termination tests passed only because they mock `AMX_ALERT_1_START` as
ISO 8601 (`date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ`), which does NOT
match what AMX sends in production. The test masks the bug.

## Phase 1: fix the timestamp parser + match the test to production

- [x] `libexec/alert-repair-dispatch` `_slowburn_firing_seconds`: accept a
      Unix epoch integer (digits only) as well as ISO 8601. AMX sends epoch
      in production; keep ISO support for robustness. A purely-numeric
      string (optionally with trailing `.fff` or `Z`) is epoch seconds; else
      try ISO 8601. Unknown/unparseable still returns None (fail-safe: never
      file prematurely). Add a clear comment naming the AMX epoch format and
      the packet-file evidence.
- [x] `tests/alert-repair-slo-slowburn-skip.test.sh`: change the `fire_slowburn`
      start values to **epoch integers** (what AMX actually sends), so the
      test reflects production reality and would have caught this bug. Keep
      the (a)/(b)/(c)/(d) cases and their assertions intact. Optionally add
      one extra assertion/case proving an ISO 8601 start ALSO works (backward
      compat), but the primary path must be epoch. The `two_h_ago` /
      `ten_m_ago` helpers should produce epoch seconds (e.g.
      `$(date -u -d '2 hours ago' +%s)`).
- [x] Run the termination commands from the issue body and prove green:
      `bash tests/alert-repair-slo-slowburn-skip.test.sh` and
      `bash tests/alert-repair-claim-mutex.test.sh` (both exit 0).
- [x] Run adjacent organ tests to prove no regression:
      `bash tests/signal-reconcile.test.sh`,
      `python3 -c "import py_compile; py_compile.compile('libexec/alert-repair-dispatch', doraise=True)"`,
      `python3 -c "import yaml; yaml.safe_load(open('config/fleet_rules.yml'))"`.

Do NOT touch the alert-repair skip-list, the mutex, class-park, or any seat
cap. Do NOT add a new organ/timer/service/canary. Do NOT file a live issue
yourself — the manager verifies the mechanism against the live alert after
the fix lands on main.

## Acceptance mapping (from issue body)

1. First checks for existing claim before filing → already in merged code. ✓
2. Routes through existing organs → already in merged code. ✓
3. Does NOT raise the skip-list → unchanged. ✓
4. Notifies am-executor, never pages Nish → already in merged code. ✓
5. Prevention mechanism test proves both directions + idempotence → test
   exists but masked the bug; this phase makes it match production. ✓
6. No money decision → unchanged. ✓

The bug fix is what makes accept-5's prevention mechanism actually prevent.
