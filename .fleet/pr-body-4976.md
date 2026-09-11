## Summary

On the success path of `bin/pi-issue-run`, the debug-playbook gate did a bare `exit 1` on a block, ignoring the shipped-PR bypass from fleet-ops#4903 (which lives only inside the `rc != 0` failure branch). A session with ≥2 real failed toolResults whose PR was already open/armed got recorded as `rc=1` `debug-playbook-gate-block` — 4949/4946 re-claimed their already-delivered issues ~4 minutes after their PRs were armed, via `Restart=on-failure` + `OnFailure`.

Fix: inside the gate-block branch on the success path, check `has_session_pr_url` on the session/out/err files, then (fallback) an open PR on `claim/issue-<N>` for the packet repo. If shipped: log LOUD, set `_exit_reason=debug-playbook-gate-block-pr-shipped`, exit 0. Otherwise the original `exit 1` behavior is unchanged.

The gate is NOT weakened: the gate's own LOUD line + auto-file to heartbeat triage (`fleet-debug-playbook` `loud` → `$TRIAGE`) still fires before the bypass, and `bin/fleet-heartbeat-tier1` step 18 re-runs `fleet-debug-playbook` every tick — observe-to-close is untouched. The exit code only decides whether systemd re-spawns a unit whose deliverable already exists.

Verification (real runs):
```
$ bash tests/pi-issue-run-debug-playbook-gate.test.sh
OK: pi-issue-run blocks a missing-playbook session from exiting 0   (case 1 — bad session, no PR → rc=1, unchanged)
OK: pi-issue-run lets a clean session close                          (case 2 — unchanged)
OK: pi-issue-run exits 0 on a blocked gate when the session shipped a PR   (new case 3 — rc=0, `debug-playbook-gate-block-pr-shipped` in stderr, `DEBUG-PLAYBOOK-GATE-BLOCK` still LOUD on stderr AND in FLEET_HEARTBEAT_TRIAGE)
OK: pi-issue-run debug-playbook gate (fleet-ops#2005, fleet-ops#4976)
```
```
$ bash -n bin/pi-issue-run → syntax OK
$ sgscan → No new security findings.
```

Metric: a worker unit whose session already produced an open/auto-merge-armed PR exits 0 through the debug-playbook gate instead of rc=1 + Restart=on-failure re-dispatch. ✓ (new test case 3 asserts rc=0 and the pr-shipped reason; case 1 asserts rc=1 stays for the no-PR case.)

run-proof: single unit `pi-issue-fleet-ops-4976`; test `tests/pi-issue-run-debug-playbook-gate.test.sh` (bash, no CI unit) ran to green, 3/3 cases; sgscan clean.

net-positive-because: the bypass adds ~25 lines of shipped-PR detection inside the existing gate-block branch plus 21 test lines — the alternative (logging-only) would not stop the Restart re-dispatch that costs a full packet per occurrence.

loose-ends: none — bypass covers both session-URL and open-claim-PR detection; triage LOUD-filing asserted in test.

Test plan: `bash tests/pi-issue-run-debug-playbook-gate.test.sh`

Closes #4976
