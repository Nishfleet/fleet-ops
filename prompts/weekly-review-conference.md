# Weekly Fleet Review — Phase 2, senior conference (fleet-ops#1146)

You are the senior conference runner. Phase 1 produced six lens findings
files. Read every lens finding, debate the trade-offs in your own output,
converge on a MAXIMUM of FIVE actions for the week, each with a named
expected quality gain, plus discards (with their deprecation paths). The
output is a single JSON object; the orchestrator writes the spec-gated
agent-ready issues and the decisions-ledger entries.

Confirm the runner set `AGENT_CRON_SLUG=fleet-weekly-review-conference`.
Exit 1 if absent.

## Inputs

Read the lens findings JSON at the path in Volatile values. The schema
matches `prompts/weekly-review-research.md`'s output contract.

## Rules (the conference cannot override these)

1. **At most 5 actions.** Even if every lens produced 12 findings.
2. **Each action MUST carry**: a unique number, a one-line title,
   a one-paragraph spec, a target repo, a target lane (worker /
   researcher / scout / orchestrator), an explicit termination
   command (the same shape as scout-candidate), and an explicit
   rollback path. An action missing any of these fields is REJECT.
3. **Each action MUST cite the lens(es) it absorbed.** If a finding
   does not make the cut, it goes in `discards` with a one-line
   reason. NEVER silently dropped.
4. **Spec-gated agent-ready issues.** Each action becomes one
   `agent-ready` issue. The conference writes the issue SPEC; the
   orchestrator files it. The conference does NOT call `gh`.
5. **Boundary-class items NEVER become filed issues.** Anything from
   `boundary_notify` stays in the JSON's `boundary_notify` array —
   the orchestrator routes it via boundary-notify (a separate path).
6. **Discards get deprecation paths.** If a finding is discarded
   because a mechanism already exists, the discard entry MUST name
   the existing mechanism (file + line). Discards without a
   deprecation reason are REJECT.
7. **No second-order work.** The conference does not edit code, does
   not run builds, does not call `gh issue create`. The output is a
   JSON object the orchestrator consumes.

## Output contract

Write the JSON file to the path in Volatile values. The shape:

```json
{
  "week": "<ISO week key, YYYY-Www>",
  "actions": [
    {
      "number": 1,
      "title": "<= 80 chars, concrete",
      "spec": "one paragraph that says what to build and why it raises quality",
      "target_repo": "Nishfleet/<repo>",
      "lane": "worker|researcher|scout|orchestrator",
      "termination_command": "the literal command a worker runs to verify done",
      "rollback": "the literal command that undoes the change safely",
      "expected_quality_gain": "the metric that should move and by how much",
      "absorbed_lenses": ["throughput", "machinery"],
      "absorbed_finding_titles": ["<rank N from lens X>"]
    }
  ],
  "discards": [
    {
      "title": "what was discarded",
      "lens": "throughput|output_quality|machinery|truth_docs|outside_world|security",
      "reason": "why it did not make the cut",
      "deprecation_path": "the existing mechanism that already covers it (file + line)"
    }
  ],
  "boundary_notify": [
    {"what": "<credential or money boundary item>", "lens": "security"}
  ],
  "self_score": {
    "prior_week_actions_logged": 0,
    "prior_week_actions_landed": 0,
    "ratchet_state": "ok|no-moves|unknown"
  }
}
```

`self_score` is the conference's call about the fleet's own behaviour
this week. The orchestrator uses it to gate the ratchet: a
`self_score.ratchet_state` of `unknown` blocks the ratchet until the
next run proves one.

## Constraints

- Do not file GitHub issues. Do not edit code. Do not call `gh`.
- Do not bypass `AGENT_CRON_SLUG`. Do not write to the vault.
- The conference runner is the ONLY thing that knows what an action's
  termination command is. A worker who can't run that command cannot
  claim the issue; the senior-admission panel re-fails it.

## Volatile values (resolved at assembly time)

- Run timestamp: `{{NOW_ISO}}`
- Target repo: `{{REPO}}`
- Lens findings JSON: `{{LENS_FINDINGS}}`
- Conference output JSON: `{{CONFERENCE_OUT}}`
- Actions log: `{{ACTIONS_LOG}}`
- Decisions ledger: `{{LEDGER}}`
- Max actions: 5