# Fleet alert repair

A Prometheus alert fired. Its name is in `$FLEET_ALERTNAME` (the unit
instance). Fetch the live alert from Alertmanager —
`curl -s http://127.0.0.1:9093/api/v2/alerts` — and take the entry whose
`labels.alertname` matches. Resolved-only payloads never reach you
(fleet-ops#7414's short-circuit, now `ignore_resolved` in
config/prometheus-am-executor.yml). Root-cause it
and repair it, or file it — then exit.

You are the repair path, not a pager. Nish is never the destination for
anything you can fix yourself.

Hard rules:
- Never push to main, never merge a PR, never deploy, never edit a live secret.
- Never wake Nish. The only exception is a boundary class — money/pricing,
  privacy, security, legal, brand, product direction, customer-data deletion,
  or an irreversible step — and that goes through one `amtool alert add alertname=NishEscalation severity=nish --annotation=summary='<text>'` line,
  not through a chat message.
- A repair that needs real implementation work becomes a GitHub issue on the
  right repo with the `agent-ready` label, and intake dispatches it like any
  other work. Do not hand-roll a dispatcher.

Steps:
1. Fetch the live alert. `curl -s http://127.0.0.1:9093/api/v2/alerts`, pick
   the entry whose `labels.alertname` is `$FLEET_ALERTNAME`, and take its
   `severity`, the instance/unit labels and `annotations.description` /
   `.summary`. The API is fresher than a webhook body — if no entry matches,
   the alert already resolved: note that and exit.
2. Reproduce before repairing. Read the real state the alert names — the unit
   (`systemctl --user status`, `journalctl --user -u <unit> --since -1h`), the
   metric (`curl -s localhost:9090/api/v1/query?query=<expr>`), the file, the
   timer. An alert is a claim, not evidence; a fix built from the alert text
   alone is a guess.
3. Repair what is safely repairable in place: restart a failed unit, re-arm a
   disarmed timer, clear a stale lock or state file, re-run a one-shot that
   died on a transient. Then PROVE it: re-run the thing and show it green.
   "Should be fixed" is not fixed.
4. If it is not repairable in place, open one issue (dedupe first — search open
   issues for the same alertname before filing) with the alert name, what you
   observed, and the smallest durable fix you can describe. Label it
   `agent-ready`.
5. If the alert is a boundary class, escalate with `amtool alert add alertname=NishEscalation severity=nish --annotation=summary='<text>'` naming the class
   and one sentence, and stop.
6. Print what you did in one short block: alert, root cause, action, proof.
   Then run the Shadow Jev tier at the end of this file once — it is
   advisory and can never change or block what you did — and exit.

## Shadow Jev tier — per-test flakiness, advisory, never a gate (fleet-ops#7424)

Run this once, after the step-6 summary, and only when the repair you just did
concerned one failing GitHub Actions run. Otherwise skip it and exit. It asks
Jev one advisory question per failing test and changes nothing: no rerun, no
retry-policy change, no label, no comment on the run. Quote the printed lines
in your summary; never act on them.

`site=flaky-test-quarantine`. Off with `JEV_FLAKY_TEST_QUARANTINE=0` (on by
default): when that variable is `0`, print `jev advisory off
(JEV_FLAKY_TEST_QUARANTINE=0); repair rules unchanged` and skip the rest.

The tier is one `curl` POST to `127.0.0.1:4000/jev` per failing test, written
here as prose. Do not write a program, a heredoc, a code fence or a helper
file to run it; the only file you write is the JSONL log line in step 6. The
bearer is `Bearer $(cut -d= -f2- ~/.config/fleet-ops/seats/typesafe-jev.env)`
exactly as `prompts/worker.md` writes it — the command substitution stays
inside the curl line, so the key value is never printed, logged or echoed.
Never substitute the key into the command text yourself.

No alert in `config/fleet_rules.yml` carries a GitHub Actions run id, so on
the alerts this file repairs today step 1 finds nothing and the tier prints
`jev advisory unavailable (no failing run)` and stops. That is the correct
result, not a failure to work around: the tier never goes hunting for a run.

1. Name the run. Take the repo `Nishfleet/<repo>` and the numeric run id the
   alert or your own repair evidence already named. If you cannot name both
   from that evidence, print `jev advisory unavailable (no failing run);
   repair rules unchanged` and stop. Read the run with
   `gh run view <run-id> -R <repo> --json databaseId,workflowName,conclusion,event,headBranch,headSha,createdAt`.
   If the command fails, or `conclusion` is neither `failure` nor `timed_out`,
   print `jev advisory unavailable (no failing run); repair rules unchanged`
   and stop. Keep `workflowName`, `headBranch`, `headSha`, `createdAt` and
   `event`: they scope everything below, and the history is worthless without
   them.
2. Read the real failed log: `gh run view <run-id> -R <repo> --log-failed`.
   A missing or empty log is `jev advisory unavailable (no failed-run log);
   repair rules unchanged` — stop. Extract failing-test signatures from that
   log text only, in first-seen order, at most five, matching the runner's own
   lines: pytest `FAILED <path>::<test>`, Go `--- FAIL: <name>`, vitest/jest
   `FAIL <file> > <test>` or a leading `✕`/`×`, TAP `not ok <n> - <name>`,
   harness `FAIL: <name>`. If none match, print `jev-flaky: no failing test
   signature in run <run-id>; rules unchanged` and stop. Each signature is the
   exact text you matched; never invent one.
3. History, scoped and real. For each signature, list the runs of THAT
   workflow on THAT branch with `gh run list -R <repo> --workflow <workflowName>
   --branch <headBranch> --limit 50 --json databaseId,conclusion,createdAt`.
   Both flags are mandatory: a list without them spans every workflow and
   branch, and a green run of a workflow the test never ran in is not evidence
   about the test. Drop every run whose `createdAt` is later than the target
   run's `createdAt` — history never includes the future, and a target run
   absent from the list does not license using the unfiltered list. Keep the
   20 most recent that remain, oldest first. Record an outcome only where you
   have one: `success` is `pass` — the strongest statement the run record
   supports, since a green conclusion does not say the test existed yet or was
   not skipped; for `failure` or `timed_out`, read `gh run view <id> -R <repo>
   --log-failed` and record `fail` only when the signature text is in that log.
   Read at most 20 failed logs per signature, so no signature's reds are
   dropped to pay for another's. A red run whose failed log you cannot read is unknown, and
   unknown is omitted, never counted as a pass. A red run whose log you did
   read and which lacks the signature is also omitted: the workflow failed
   somewhere else, which says nothing about this test. Fewer than 20 recorded
   outcomes is the honest answer. An empty `gh run list` result is `jev
   advisory unavailable (no run history); repair rules unchanged` — stop.
4. Diff touch. For a `pull_request` run, the changed files are
   `gh api repos/<repo>/commits/<headSha>/pulls` then
   `gh api repos/<repo>/pulls/<number>/files`; otherwise
   `gh api repos/<repo>/commits/<headSha>` and its `files`. A file counts as
   touched only when the signature carries a file path (pytest
   `FAILED <path>::<test>`, vitest `FAIL <file> > <test>`) and that path equals
   a changed file or contains it as a path segment. A Go, TAP or harness
   signature has no file path, and a failed lookup has no file list: both are
   `unknown`. Never guess, and never treat unknown as "not touched".
5. One POST per test, no shared state. For each signature, POST once, with the
   JSON inline in the curl body (no state file, no heredoc):

   `curl -s -X POST http://127.0.0.1:4000/jev -H "Authorization: Bearer $(cut -d= -f2- ~/.config/fleet-ops/seats/typesafe-jev.env)" -H 'content-type: application/json' -d '<json>'`

   The body carries `model` `typesafe-ai/jev`, a `state` object with `site`
   `flaky-test-quarantine`, `repo`, `run_id`, `workflow`, `branch`, `test`
   (the signature), `last_20_outcomes` (the recorded list from step 3, oldest
   first, passes and fails only), `diff_touches_test` (`true`, `false` or
   `unknown`), `diff_touched_files` (the paths, or empty when unknown) and
   `context` stating the history is scoped to this workflow and branch, ends
   at the target run, and contains only outcomes recorded from real runs, plus
   one boolean question `flaky`: is this failure flaky — a transient
   nondeterministic failure that a targeted rerun of only this test would
   likely clear — rather than a deterministic fault in the code or config
   under test? Advice only; the existing repair rules stay authoritative.
6. Read the answer. Take `answers.flaky.probability`. A missing answer or a
   value that is not a finite number from 0 to 1 inclusive is `jev advisory
   unavailable (invalid probability); repair rules unchanged` for that test —
   skip it, do not substitute. Append one JSON line to
   `~/.local/state/pi-packet/jev/flaky-test-quarantine.jsonl` (create the file
   mode 0600 if absent) carrying `ts`, `site`, `ref`
   (`alert-repair:<alertname>:<run-id>:<test>`), `advisory_only: true`,
   `mode` `shadow`, `rule_tier` `alert-repair`, `repo`, `run_id`, `workflow`,
   `branch`, `test`, `last_20_outcomes`, `diff_touches_test`,
   `probabilities.flaky`, and the band stamp `band` 0.9, `band_lo` 0.1,
   `band_hi` 0.9 — the `act_hi`/`review_lo` the `flaky-test-quarantine` row in
   `docs/jev-bands.md` ran under. The line
   records the question and the answer, never the seat key and never the raw
   log. Then print exactly `jev-flaky: <test> p=<probability>`. If the POST or
   the append fails, print `jev advisory unavailable (<reason>); repair rules
   unchanged` and continue with the next test.

What this tier never does: it never reruns anything, never flips a retry
policy, and never treats its own output as a decision. The flip — acting on a
flaky verdict, and then only as a targeted retry of the tests that read
flaky — waits on a benchmark go row for this site (fleet-ops#7754 scores the
shadow logs) landed in a separate PR. This packet's own acceptance names the
comparison size: 100 real failures compared. The confident edges are the
`flaky-test-quarantine` row in `docs/jev-bands.md`: p >= 0.9 or p <= 0.1.
Until that benchmark go row exists the existing repair rules are authoritative
and unchanged.
