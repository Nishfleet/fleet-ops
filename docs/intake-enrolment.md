## Intake enrolment

`config/intake-repos.json` is the **declared set** of repos that run
agent-dispatch. It is the single source of truth for which
repos are enrolled — adding or removing a repo is a PR against that file, not a
`systemctl enable`. This replaces the old imperative enrolment that was
silently reverted without a record (fleet-ops#32). `later-sweep.service` reads
this list too, so the overdue sweep follows enrolment without a second list.
`sweep_only` names repos that are not enrolled but whose agent-ready items
the worker-exit top-up in `agent.yml` still re-sweeps (fleet-ops and drive,
fleet-ops#10638): a retry of items already labelled, never admit or intake.

Each enrolled repo needs three preconditions:

1. A git checkout at `/home/nish/workspaces/products/<name>` — the worker
   creates its worktree from it. Packet clones (when a worker clones instead
   of worktree-add) use `git clone --reference-if-able
/home/nish/workspaces/.mirrors/<name>.git
https://github.com/Nishfleet/<name>.git <dest>` (fleet-ops#1213).
   Mirrors are read-only fetch targets; never push.
2. The six labels listed in `required_labels` in `config/intake-repos.json`
   — `agent-ready`, `agent-in-progress`, `agent-blocked`, `agent-failed`,
   `needs-orchestrator`, `strong-only` — must be present on the repo —
   agent-dispatch fires only on the `agent-ready` label, so on a repo missing
   any required label an issue looks queued and is inert (fleet-ops#25).
3. An `.github/workflows/agent-dispatch.yml` stub whose
   `on.pull_request_target.types` lists all nine events — `dequeued`,
   `auto_merge_disabled`, `closed`, `auto_merge_enabled`, `synchronize`,
   `labeled`, `opened`, `reopened`, `ready_for_review`. `hold-risky` is the
   only door into `review-risky`, a `pull_request_target` trigger fires only
   for the types its own repo's stub lists, and `pull_request_target` reads
   that stub from the base branch — so a short list leaves the repo with no
   review and no coordinator gate on risky PRs (fleet-ops#9722, #9726).
   fleet-ops's own stub is the reference. CI enforces this on every run:
   `ci.yml` reads each enrolled repo's stub from its default branch
   (`tests/intake_stub_check.py`) and fails when a readable repo's list is
   short, or when no enrolled repo's stub could be read at all — a run that
   verified nothing must not report success. The required list and the
   enrolled set both come from fleet-ops's own stub and
   `config/intake-repos.json` at the run's base ref, so a PR cannot loosen
   the rules that judge it, the way `hold-risky` reads its path list from the
   base branch. A repo the CI token cannot read (a private repo, or a
   deleted one) is named as not verified in the run and stays on the enrolment
   review; any other API state, and a transport failure, fails closed.

`excluded` in the file lists repos that are never enrolled (fleet2: no
second dispatcher, ever; archived repos). `deferred` lists repos paused with
the reason and the condition to re-enrol, and `fleet-ops` itself is in it.
Only `repos` is enrolled.

The `bin/intake-reconcile` reconciler and its `intake-reconcile.{path,
service,timer}` units were deleted in the glue sweep — the file itself is
the enrolment mechanism (fleet-ops#32, #25).

