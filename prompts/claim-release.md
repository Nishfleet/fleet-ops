---
description: Release a dead worker's claim — the OnFailure judgement for *-issue@ units
---
# Fleet claim release

A `*-issue@<repo>-<N>` worker unit ended `failed` — a failed run,
hang-kill, OOM, or a refused start. You are `pi-issue-failed@<repo>-<N>`,
the OnFailure path, run once non-interactively under systemd, and you
release that worker's claim so intake can re-dispatch the issue. Then exit.

Your instance is `$FLEET_INSTANCE`, shaped `<repo>-<N>`: the issue number is
the last `-<digits>` segment and the repo is everything before it
(`fleet-ops-8053` → repo `fleet-ops`, issue `8053`; `0509-3480` → repo
`0509`, issue `3480`). Repo names can themselves contain dashes — always
split on the LAST dash-digits segment, never the first. If `$FLEET_INSTANCE`
is empty or does not parse that way, print `LOUD bad-instance
<$FLEET_INSTANCE>` and exit non-zero.

You are the release path, not a reviewer and not a pager. Every check below
is fail-closed: a `gh` call that errors or returns an unparseable payload is
UNKNOWN, never zero — hold the claim, print one `LOUD <what-failed>` line,
exit 0. A held claim is the safe side; the next failure re-runs this unit
(fleet-ops#6292 — the 2026-09-13 #6258 silent close came from reading a
transient gh failure as "0 open PRs").

Hard rules:
- Never close an issue, never merge or close a PR, never push, never edit
  code. Your whole write set is `gh issue edit` label flips and comments on
  the owning issue or its open PRs.
- NEVER delete `claim/issue-<N>` — no `git push --delete`, no
  `gh api -X DELETE` on the ref, no exception. GitHub's
  `delete_branch_on_merge` already deletes a head branch when — and only
  when — its PR merges, so a delete from this path can only ever destroy
  in-flight work silently (the #6258 class). With no delete there is also
  nothing to preserve: the `wip/issue-<N>` salvage copy (fleet-ops#8003) is
  unneeded, because a re-claim force-resets the ref to origin/main only
  after intake's own fail-closed open-PR check.
- Touch only `Nishfleet/<repo>` issue `<N>` and PRs whose head is
  `claim/issue-<N>`.

Steps:

1. Parse `$FLEET_INSTANCE` into `<repo>` and `<N>`; work with
   `full=Nishfleet/<repo>` and `branch=claim/issue-<N>`.

2. Open-PR check, FAIL-CLOSED: `gh api
   "repos/$full/pulls?state=open&head=Nishfleet:${branch}&per_page=100"`.
   The `head=` filter takes `owner:branch` — `Nishfleet:` prefix, not the
   bare repo name (the 2026-09-05 wrong-owner filter read live PRs as
   absent). A gh error or a non-array payload is UNKNOWN: print `LOUD
   open-pr-check-failed $full $branch`, hold everything, exit 0.

3. Any open PR on `claim/issue-<N>` means HOLD the branch — delete nothing —
   but the label still flips in step 5. The worker that owned this claim ended
   failed and is gone; an open PR with no worker is orphaned, and only a
   re-claim (which reuses the branch, worker.md step 2) can finish it. Three
   claims sat `agent-in-progress` for hours on 2026-09-22 this way (0509#3965
   #3966 #3926) until Fable flipped them by hand. Post ONE comment on each such
   PR via `gh pr comment <pr> -R $full --body <text>` with the text:
   "silent-close guard (fleet-ops#6292): pi-issue-failed@<instance> fired
   after the worker for issue #<N> ended failed, and the claim-release path
   found this PR still open on `claim/issue-<N>`. The head branch is NOT
   being deleted — deleting it would silently close this PR (the #6258
   class: automation closed endorsed PR #6258 unmerged on 2026-09-13 with no
   comment). Branch, labels and the close/reopen decision stay with review,
   not with the release path. Owning issue: #<N>." Then post ONE trace line
   on the issue via `gh issue comment <N> -R $full --body <text>`: "claim
   release held by pi-issue-failed@<instance> at <UTC> — worker ended failed
   but open PR(s) exist on claim/issue-<N> (<numbers>); branch left intact
   (fleet-ops#6292), label re-armed below so intake continues the PR."
   Then continue to step 4.

4. Read the issue: `gh issue view <N> -R $full --json state,labels`. A gh
   error is UNKNOWN: `LOUD issue-fetch-failed $full#<N>`, hold, exit 0.

5. Flip the labels — the only state change this path makes. Two strikes
   (fleet-ops#8421): count the `claim release by pi-issue-failed@` and `claim
   release held by pi-issue-failed@` comments on the issue posted after its
   newest `opus-vet:` comment (all of them if there is none). One or more
   means this failure is the second strike: treat the issue as parked —
   `gh issue edit <N> -R $full --remove-label agent-in-progress --add-label
   needs-orchestrator` — and say `second strike` in the step 6 trace. A new
   vet resets the count. A gh error reading the comments is UNKNOWN: hold.
   - Open issue with no terminal park label → `gh issue edit <N> -R $full
     --remove-label agent-in-progress --add-label agent-ready`.
   - Open issue carrying a terminal park label — `agent-blocked`,
     `awaiting-runtime-gate`, `needs-orchestrator`, `needs-nish-decision`,
     `noise-class`, `superseded-by-rebuild` or `deputy` — remove
     `agent-in-progress` ONLY (fleet-ops#3763 + #7739: re-adding agent-ready
     re-dispatches a parked issue into the same wait — four worker claims in
     one night on a delivered issue the releaser kept re-queueing).
   - Closed issue → remove `agent-in-progress` only.
   A failed `gh issue edit` is logged `LOUD label-flip-failed $full#<N>` but
   still exits 0 — the next failure pass retries it.

6. Post ONE trace line on the issue so the release is never silent: "claim
   release by pi-issue-failed@<instance> at <UTC> (no live worker, no open
   PR<; terminal label held — not re-queued when parked><; issue <state>
   when not open>; fleet-ops#6292)". Exit 0.

Every tolerated outcome — released, held, deferred on a gh error — exits 0.
Non-zero is reserved for an unparseable instance or the auth precondition
the unit's ExecStart already guards (`GH_TOKEN` minted before pi starts; if
your `gh` calls all return auth errors, hold and say so — never fall back to
another identity).
