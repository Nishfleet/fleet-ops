fix(1464): double-quote receiver prom labels so the alert can clear

Root cause of the FleetGhWebhookReceiverAbsent alert that reopened #1464:
the receiver's heartbeat prom file used Python repr() for label values
(unit='(ignored)'), which is INVALID Prometheus exposition format.
node-exporter's textfile collector silently drops single-quoted label
series, so fleet_gh_webhook_receiver_last_green_seconds never reached
Prometheus, absent() was permanently true, and the alert fired forever
— even though the synthetic canary was hitting the receiver every 5 min
and the channel was provably alive. The canary series (double-quoted)
WAS scraped; only the receiver series was broken by the quote bug.

Three fixes in libexec/gh-webhook-receiver/serve.py:

1. Double-quote all prom label values via a new _prom_quote() helper
   (escapes \, ", \n). This is the root-cause fix — node-exporter now
   scrapes the series and absent() goes false.

2. Bump last_green_seconds on EVERY verified received event, dispatched
   OR ignored — not only on dispatches. The synthetic canary posts to a
   non-enrolled repo (fleet-ops-canary), so its events are 'ignored' by
   the dispatch table. Without this, the receiver heartbeat only goes
   green on a real dispatch, which never happens for the canary, so the
   alert could never clear from the canary alone. dispatch_total stays
   dispatch-only (the existing test pins == 2).

3. Enrollment guard: refuse to dispatch pi-intake@<repo> for a repo not
   in config/intake-repos.json (fleet-ops#32 single source of truth).
   The synthetic canary repo is the canonical non-enrolled case —
   without the guard, every 5-min canary would fire
   pi-intake@fleet-ops-canary.service, spawning wasteful gh calls to a
   non-existent repo plus OnFailure repair units. fleet-deploy-check
   (pipeline-red, workflow_run) is fleet-wide and stays ungated.

Also adds a new regression test
(tests/gh-webhook-receiver-prom-quotes.test.sh) that pins all three
fixes: double-quoted labels, the enrollment guard, and the
ignored-event heartbeat bump via a real HTTP server in DRY mode.

The four pre-existing gh-webhook test files were never registered in
.github/workflows/ci.yml by the prior #1464 PRs, so the root-cause
class had no CI guard. Registering them in CI is filed as #1606
because a workflow edit requires Nish's own scope (the
nishfleet-worker App token lacks Workflows permission). This PR ships
the code fix + the new regression test; #1606 lands the CI
registration so the test runs on every PR.

Verification:
```
bash tests/gh-webhook-receiver-prom-quotes.test.sh   # 5/5 green (new)
bash tests/gh-webhook-receiver-hmac.test.sh          # 10/10 green
bash tests/gh-webhook-canary.test.sh                 # 8/8 green
bash tests/gh-webhook-organ-heartbeat.test.sh        # 4/4 green
bash tests/fleet-intake-reconciler-counter.test.sh   # 10/10 green
python3 -m py_compile libexec/gh-webhook-receiver/serve.py  # OK
```

run-proof: live on netcup-rs2000. Before fix:
`curl -sG http://127.0.0.1:9090/api/v1/query --data-urlencode query=fleet_gh_webhook_receiver_last_green_seconds` returned `result:[]` (series dropped by node-exporter due to single-quoted labels); `FleetGhWebhookReceiverAbsent` was `firing` since 2026-08-28T08:26:23Z. After deploying the fixed serve.py (symlink repointed to the worktree file, receiver restarted) and firing the synthetic canary once: the prom file now carries `fleet_gh_webhook_receiver_last_green_seconds{unit="",event="issues"} <current-ts>` (double-quoted); Prometheus scrapes it (`result` non-empty); the alert expression `absent(...) or (time() - ...) > 3600` evaluates to an empty vector (false); `curl http://127.0.0.1:9090/api/v1/alerts` reports `count=0` for GhWebhook alerts — FleetGhWebhookReceiverAbsent is cleared. The canary timer (5 min) keeps the heartbeat fresh.

Note on live deployment: the installed receiver is a symlink to the deploy-clone, which is the protected main checkout (fleet-ops#477). To prove the fix live without editing the deploy-clone, the symlink was temporarily repointed at this worktree's fixed serve.py. After this PR merges, fleet-ops-deploy will pull origin/main into the deploy-clone and the symlink (which targets the deploy-clone path) will again resolve to the now-fixed canonical file — no manual restore needed beyond the normal deploy flow.

Closes #1464
