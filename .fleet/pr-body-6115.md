## Summary — the legacy seat canaries are culled from the 5-min heartbeat

tier1 no longer runs the #4264 leftover canaries. Three are deleted
outright; the fourth keeps its slot because #6474 gave it a live job.
Net: 14 files, +102/−1903 (excl. this body, prior convention).

Blocks 15/30/37: gone.

- 15 (entitled-vs-wired, #387): the verdict moved into the litellm health
  canary. The yaml model_list IS the entitlement; a census counting FEWER
  deployments than the yaml configures now exits 1
  (health-census-shortfall). This is the issue's "fold into the census"
  rewrite, shipped as the census assertion. The cull's guard-map residue
  goes with it: config/asset-guard-map.json's pi-seat/pi-provider
  guard+proof pointers now name the census
  (libexec/fleet-litellm-health-canary.py) instead of the deleted bin;
  the dated #1380/#1450 notes in seat-caps/entitled-seats keep their
  history untouched.
- 30 (SuperGrok live-validate, #917): /health census is the authority.
  The 683-line bin and its 577-line test are deleted. The dead-deployment
  verdict stays with the health canary's #6054 drill (its own 18c: a
  continuously-unhealthy deployment exits 1).
- 37 (AIMD leftover meter, #424): the mechanism died with #5993. The
  9-line #4263 tombstone, its test, and its row are deleted. The issue's
  acceptance grep is 0: `grep -r fleet-aimd-meter-canary -- bin lib
  systemd` → no hits.

Block 38: kept, deliberately. #6474 (merged 2026-09-13T18:20Z, after this
issue's 2026-09-12 verdicts) rewrote the 9-line prepaid residue into the
Cursor $400 Included-API-bucket reader and made it the ONLY writer of
prepaid-spend.prom — which config/fleet_rules.yml's pacing rules
(fleet_cursor_prepaid_remaining_usd, FleetCursorPrepaidBurnPacingLow)
read. LiteLLM_BudgetTable does not see that $400 bucket; #6474's own
header proves it (spend/pool read 0.000000 while $235.704 of $400.00 sat
there). Deleting the slot would re-freeze the $400 pacing — the #6114 bug
again. So the tier1 invocation comes back trimmed to what #6114's reader
needs (require_manifest_helper + HELPER-MISSING per #485), and the legacy
#531 duties (provider gates, expiry-waste detector, PREPAID-UTIL
heartbeat lines) stay retired — they were already gone from the bin.

MANIFEST: the entitled/aimd/seat-live rows go, with their prose; the
prepaid row and the #4621 comment stay true. The required-bins gate
follows: entitled leaves the #175/#485 required[] and the helper-wiring
map, and the prepaid reader JOINS that map (the #485 fail-loud contract
covers it for the first time). The stale #917 cross-references (MANIFEST
#41 block, grok-token-refresh, the #41 test-host comment) now name the
litellm health canary as the dead-case catch.

Verification:

- bash tests/fleet-litellm-organ.test.sh — ALL OK, including the new 18d
  (census-shortfall: exit 1, "health-census-shortfall" named on stderr,
  prom+state written before the exit) beside #6474's 18c hold-clock; the
  #6115 scenario renames 18c→18d so the ids stay unique after the
  #6474 auto-merge.
- bash tests/manifest-required-bins.test.sh — 4 OK (required rows;
  helper wiring, now including the prepaid reader; fail-loud semantics
  0/1/2).
- bash tests/manifest-shape.test.sh — 8 OK.
- bash tests/escalation-coverage-canary.test.sh — rc=0, 300 OK: the
  prepaid #6114 reader, grok-token-refresh (edited #41 prose), and the
  restore/resilience drills all pass inside the trimmed harness.
- CI's exact shellcheck gate (0.11.0, all of bin/ + install.sh +
  gate-integrity.sh): CLEAN. One load-bearing detail: "$400" in a
  double-quoted log line is $4 + "00", and tier1 runs set -euo pipefail,
  so the no-arg unit died with "$4: unbound variable" — proven, then
  fixed as \$400.
- sgscan --base origin/main: no new findings.
- gitleaks, CI's exit-2 contract, 83e0d110e..HEAD: no leaks, rc=0.

run-proof: timer fleet-litellm-health-canary.timer — 60s cycle, last run
under a minute old, journal line "proxy_up=1 status=200 census=9
expected=9 groups=4 pg_up=1 redis_up=1": the organ that inherits the #387
verdict is alive and already publishing the expected-count the shortfall
verdict compares against. This branch's 18d scenario runs the same binary
end-to-end (real prom+state writes, exit 1) — the verdict is proven, the
organ proves the cadence.

run-proof: service fleet-heartbeat.service — its last tier1-complete
journal line today reads entitled_canary_rc=0 seat_live_validate_rc=0
aimd_canary_rc=0 prepaid_util_canary_rc=0 (pre-merge: all four legacy
rcs present and green). Post-merge the 15/30/37 vars leave that line and
only prepaid_util_canary_rc remains — the issue's "journal shows blocks
15/30/37/38 absent" lands at the next deploy+tick, not in this PR.

organ-heartbeat: libexec/fleet-litellm-health-canary.py —
bin/fleet-organ-heartbeat-check: "OK: organ litellm-health-canary ->
FleetLitellmHealthCanaryAbsent absent(fleet_litellm_proxy_last_green_seconds)"
and "all 27 registered organs have an absent() heartbeat rule" (RC=0).

loose-ends: the uninstalled copies of the three retired bins
(~/.local/bin/fleet-aimd-meter-canary, fleet-entitled-wired-canary,
fleet-seat-live-validate) linger until the next install pass — inert, no
caller after this PR. And the tier1-complete line losing its three
legacy rcs: observable at the next 5-min tick after deploy.

Relates to #4130. Closes #6115
