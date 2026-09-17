# Refresh repair mechanism match for #6929

Issue #6929 asks to file or match a mechanism for a historical manual repair.
Its cited outcome was recorded at 2026-09-02T20:49:37Z and names
[PR #2938](https://github.com/Nishfleet/fleet-ops/pull/2938).
That PR closed #2923 and merged at 2026-09-02T20:50:45Z.

## Existing repair and prevention

The TTL fix in #2890 had not reached the live install because the deploy
checkout was dirty and off main. PR #2938 preserved the metrics hot-patch
as tracked code with a regression test, allowing the normal deploy path to
resume. This was an install-drift incident, not a request for credentials.

The current mechanisms cover both parts of the incident:

- `tests/grok-token-refresh.test.sh`, scenario 26, pins the default TTL to
  18000 seconds and asserts that a token with four hours left is refreshed.
- `bin/fleet-deploy-check` detects dirty and off-main checkouts. Its existing
  test covers dirty tracked and untracked files, same-SHA off-main recovery,
  and the drift gauge and alert. `bin/fleet-ops-drift.py` checks install drift.

## Verification on 2026-09-17

Tested base: `24fa42c743b3557dba77d75ee8c87d5c26992e61`.

`git merge-base --is-ancestor` returned exit 0 for the #2938 merge commit,
`0cf6c96841e85692a1c9c9c90bfa1afdb5909d5e`, against `origin/main`.
This proves the historical fix is already on main; this report is not a deploy.

The real `grok-token-refresh.service` run at 2026-09-17T18:38:05Z logged
`TTL_S=18000`, followed by a successful refresh with `expires_in=21600s`.
It finished successfully at 18:38:21Z. The user timer was active and waiting
when checked. No service restart or credential change was performed for this
investigation. This proves refresh execution, not a downstream model request.

Both existing suites returned exit 0:

```sh
bash tests/grok-token-refresh.test.sh
bash tests/fleet-deploy-check.test.sh
```

The first passed scenarios 1 through 27, including scenario 26. The second
passed dirty-checkout, off-main same-SHA recovery, drift-gauge and alert checks.
These suites use scratch state; the live run above is the runtime evidence.

## Disposition

Match #6929 to #2923 / PR #2938 and the existing refresh and deploy checks.
No new script, detector, timer, credential change, or deployment is needed.
This report adds the missing audit link, not another repair mechanism.
