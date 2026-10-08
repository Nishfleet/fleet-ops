# Held-PR approver loop retired

**Date:** 2026-10-08
**Issue:** fleet-ops#9459

## What happened

From 2026-10-07 18:07 IST to 2026-10-08 11:52 IST the remote-control Claude
session (`vps-rc`, session `a11f73e7`) ran a "held-PR approver loop". It
started three Sonnet subagents (`agent-a642a41c238e3286b`,
`agent-a42ca99d0a5e9f7e3`, `agent-a45a259e7497fcf88`) that polled the held
PRs every 20 minutes for six hours. The three runs cost about $25 of the
day's $109 Claude Max usage (dedup by `message.id`). Polling breaks the
standing rule "event-driven over scheduled".

## The event-driven replacement (already on main)

`agent-dispatch.yml`'s `hold-risky` job holds a PR whose changed paths or
added diff lines match `config/risky-paths.json`, then calls `agent.yml`'s
reusable `review` job through `review-risky`. The review job reads the held
head's diff through the API, asks a no-tools model for findings and Jev for
approve or block (p >= 0.9), and posts the approval as `github-actions[bot]`,
an identity no PR author uses. A held head is therefore decided by a GitHub
event (`pull_request_target` / `auto_merge_enabled` / `synchronize`), on a
non-Claude seat (pi via LiteLLM), with no session polling.

- `review-risky` added: #9311 (`811d144f`, 2026-10-07 15:48:13Z).
- #9428 ("review-risky fails on every held PR") fixed by #9430 (`32b835e0`,
  2026-10-08 00:09:50Z) and #9422 (`8df90dce`, 2026-10-08 03:34:51Z), which
  set `FLEET_TASK_ID` for the review job.
- `ci.yml`'s `coordinator-approval` job fails a risky head in the merge queue
  with no approval (`ci.yml:994`), the stock-GitHub backstop.

## Proof: a real held PR went held -> approved -> merged with no Claude session

| Step | Time (UTC) | Evidence |
|---|---|---|
| `review-risky / review` | 2026-10-08T16:01:41Z | run `37805367880`, job `113408212775`, success (started 16:00:41Z) |
| approval comment | 2026-10-08T16:01:34Z | `github-actions[bot]` on #9456: `coordinator-approval: 66c780318c9bb30f00b9896946a76fa3bec26ce1` |
| merged | 2026-10-08T16:07:34Z | #9456, merge commit `738f3fde0b09aefc678ab6224b71a6d6e8812743` |

The same path approved and merged #9452, #9448, #9449 and #9453 on
2026-10-08.

## Retired

The in-session held-PR approver loop is **retired**. Do not restart it. A
held PR's approval decision comes from the `review-risky` event, not from a
polling subagent. A head that predates the reviewer, or whose review job
failed, is re-driven by any new PR event (`synchronize`, `auto_merge_enabled`,
or a `needs-coordinator` label remove-and-re-add) and then flows through the
same `review` job. The coordinator never posts `coordinator-approval` by hand
for an ordinary risky PR; only a PR that edits the guard itself
(`guard` in `config/risky-paths.json`) waits for a person's typed approval.
