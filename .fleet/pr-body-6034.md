## What

Both `pi-intake-repair@{0509,fleet-ops}` lanes — the OnFailure-triggered repair
agents that un-wedge the product intake — now die at `TimeoutStartSec=1800`
while still working: the evening 2026-09-12 pair logged
`SPAWN_BLOCKED reason=home_wide_filesystem_sweep` in the same second (both
lanes; that is the repo-owned home-wide sweep guard, fleet-ops#4896 — 282 GB
home), worked 18–30m, and the fleet-ops run was killed at the 1800s cap *after
doing its work*: at 19:23:20 systemd printed "start operation timed out.
Terminating." and the session's `PACKET-VERDICT tools=53 class=worked` in the
SAME second (the verdict prints during the SIGTERM unwind — the work completed,
the Result was still 'timeout'). `StartLimitIntervalSec=21600` /
`StartLimitBurst=2` then latched both units failed, and the ~61s retrigger
loop burned an escalation trip every minute until 20:08:27.

Journal verdict: the runs are **slow-working, not stuck** — tools accumulated
10→43→53 across the day, the morning runs (08:25Z/08:30Z) *finished* at
29m13s/24m44s inside the cap, and post-reset runs finished 18m22s/20m17s. So
the lever is budget, not hang-hunting: this PR raises the start timeout to
2700s (50% headroom over the measured 30m worst) and makes near-timeout runs
visible at a glance by restamping the verdict with its wall-clock cost.

Acceptance-by-acceptance evidence (phase 1, captured before any unit edit):
`.fleet/evidence-6034.md`.

## What changes

- `systemd/pi-intake-repair@.service`: exactly one line, `TimeoutStartSec=1800`
  → `2700`. `StartLimitIntervalSec=21600` and `StartLimitBurst=2` stay
  byte-identical (fleet-ops#5036: raising the burst re-wedges). No
  OnFailure/timer/ExecStart/credential edits, nothing under `.github/**`.
- `bin/pi-intake-repair-run` (accept 3, the prevention mechanism — not a new
  checker): the verdict you already get in the journal now carries its
  wall-clock cost and its budget:

  ```
  PACKET-VERDICT tools=53 class=worked elapsed=1798s budget=2700s
  ```

  Mechanics: pi's stdout still streams through unbuffered (`tee` capture), so a
  timeout kill loses nothing; the wrapper takes the LAST `PACKET-VERDICT` line
  and appends `elapsed=<SECONDS>s` plus `budget=<TimeoutStartUSec>s` read from
  the LIVE unit via the install.sh-precedented `SYSTEMCTL` override
  (fleet-ops#290); an unparseable/absent budget omits the field (never
  fabricated); exit semantics unchanged — the wrapper exits with pi's rc, and a
  no-verdict run prints exactly what it prints today.

## Accept

1. Root cause before any unit edit — LIVE: `.fleet/evidence-6034.md`
   (summarized in What): slow-working, not stuck; the SPAWN_BLOCKED
   same-second pair is the repo-owned spawn guard costing time, not wedging;
   the verdict/TERM same second is the benign unwind print. No re-scope.
2. Exactly one unit change — verified by the new test: `TimeoutStartSec=2700`
   present, `1800` absent, `StartLimitIntervalSec=21600`/`StartLimitBurst=2`
   byte-identical; `git diff --name-status origin/main...HEAD` = 2×A (`.fleet/`)
   + 3×M, zero `.github/**`.
3. Prevention mechanism (fleet-ops#366) — this PR: `bin/pi-intake-repair-run`
   emits the augmented verdict line (`elapsed=Ns budget=Ns`); no new checker,
   no new machinery.
4. Land via the repo — this PR; both artifacts
   (`systemd/pi-intake-repair@.service`, `bin/pi-intake-repair-run`) are
   MANIFEST-installed, so the existing deploy path (merge-to-live on the
   fleet-deploy-check timer) is the install — no hand-edit of the installed
   unit. Termination + next-timer-run + 6h StartLimit window are post-merge
   observe-to-close (see loose-ends).

Termination: `XDG_RUNTIME_DIR=/run/user/$(id -u) bash -c 'grep -q
"TimeoutStartSec=2700" /home/nish/.config/systemd/user/pi-intake-repair@.service
&& test -z "$(systemctl --user list-units --state=failed --no-legend --no-pager
pi-intake-repair@0509.service pi-intake-repair@fleet-ops.service)"'` — the unit
grep flips true when the MANIFEST-symlinked clone pulls this; the failed-units
half clears on the next post-merge runs.

## Verification

```
$ bash tests/pi-intake-repair-run.test.sh
OK: intake-repair wrapper runs pi with the rotated provider/model and exits cleanly
OK: no healthy seat -> intake-repair wrapper exits 1 (fail loud)
OK: PACKET-VERDICT restamped with elapsed=<secs>s budget=2700s (45min from the live unit)
OK: wrapper exits with pi's rc (3) and still stamps elapsed/budget
OK: unparseable budget -> augmented line omits budget= silently
OK: pi-intake-repair@.service does not hard-code provider/model
OK: pi-intake-repair@.service: TimeoutStartSec=2700 with StartLimitIntervalSec=21600 + StartLimitBurst=2 untouched
OK: MANIFEST installs pi-intake-repair-run
OK: escalation canary sanctions pi-intake-repair-run
OK: systemd-analyze verify accepts pi-intake-repair@.service
OK: pi-intake-repair seat rotation: wrapper picks seat, runs pi, and fails loud when walled
```

exit 0, first run (2026-09-13). Neighborhood: `sgscan` → "No new security
findings." (exit 0). `crgate` → exit 3, "CodeRabbit is not signed in on this
machine" (known, #6332 precedent; remote review of this PR still applies).

run-proof: no new unit/timer/workflow in this diff (`git diff --name-status
origin/main...HEAD`: 2A under `.fleet/`, 3M — `systemd/pi-intake-repair@.service`
modified, not added; nothing under `.github/**`), so `prove-one-run-check`
passes on the machinery rule; the 11-OK test run above is the receipt. The
machinery that will observe the post-merge proof is all pre-existing:
fleet-deploy-check (install), the escalation chain (OnFailure), the issue's own
termination grep — zero new.

organ-heartbeat: `bin/fleet-organ-heartbeat-check gate --name-status` →
`SKIP: no fleet organ touched in the diff` (exit 0).

net-positive-because: +351/−6 — machinery +211/−6, net +205 (1 unit line;
+87/−5 wrapper = the mechanism; +123/0 test = its guard), +140
`.fleet/plan|evidence` = the manager-contract paper. No new machinery, no new
checker, no gate-owned file touched.

loose-ends: post-merge-observe (accept-4's next-timer-triggered-run class=worked,
6h no-new-start-limit, and 24h recurrence watch are physically time-gated until
the 2700s unit installs via the MANIFEST path after this PR lands — the issue's
own observe-to-close), crgate-local-not-signed-in (crgate exit 3: "CodeRabbit is
not signed in on this machine"; no stored API key — remote review of this PR
still applies).

Closes #6034
