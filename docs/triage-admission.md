## Triage admission (needs-triage)

An open issue labelled `needs-triage` in an enrolled **product** repo
(`repos` with `product: true` in `config/intake-repos.json`) gets a Jev verdict
instead of waiting for a person to add `agent-ready`. The `admit` job in
`.github/workflows/agent-dispatch.yml` runs on the hourly sweep, on the
`needs-triage` label event and on `workflow_dispatch` (`task=admit`, optionally
`issue=<N>`). It asks the router `/jev` the same way `agent.yml` does: "Admit
this issue for an automated worker now?", with the title, body and labels as
state.

- p >= 0.9: `agent-ready` added, `needs-triage` removed.
- otherwise: `needs-orchestrator` added, `needs-triage` removed, for a person to decide.

Only the issue author `nish3451` is admitted. The newest `needs-triage` label
event must also come from `nish3451`. Non-owner issues are skipped with a notice
and left as `needs-triage` (no Jev call). A daily cap (`vars.ADMIT_DAILY_MAX`,
default 10) counts `triage-admit: admitted` comments since IST midnight and
stops early when reached. The job runs only when
`(inputs.agent_mode || vars.AGENT_MODE) == 'live'`. Issue title and body are
wrapped in `<ISSUE_TEXT>` fences so the model treats them as data, never as
instructions.

Every issue gets one comment with p, the model and the run link. An issue whose
title, body or labels touch secrets, money or payments, or customer-data
deletion, or that carries `blocked-on: nish-decision`, `nish-reserved` or
`needs-nish-decision`, never reaches Jev and never gets `agent-ready`: it goes to
`needs-orchestrator`. `Nishfleet/fleet-ops` is never acted on (fo#8304). If Jev
gives no answer the label stays and the next sweep retries. The labels are
written with the worker App token, so the `agent-ready` and `needs-orchestrator`
events start the next job.

**Switch it off:** set the repo variable `ADMIT_TRIAGE` to `off` on the calling
repo (`gh variable set ADMIT_TRIAGE --body off -R Nishfleet/<repo>`).
**Delete it:** remove the `admit` job, `tests/test_triage_admit.py`, its step in
`ci.yml`, and this section. CI runs the job's real scripts against a fake `gh`
and a fake router (`tests/test_triage_admit.py`).

