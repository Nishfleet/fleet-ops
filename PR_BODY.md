## What

The parked reusable gate-integrity workflow shipped a pre-extracted
attestations array to the decision script. The pre-extraction was a
whole-body exact match: the comment's entire body had to equal
`gate-integrity-attest: <40-hex>`. Multi-line attest comments — the
real-world shape, where the marker line is followed by `verifier-attest:`
and review prose (0509#1273) — were silently dropped, so the decision
script saw an empty `attestations` array and reported "no current
gate-integrity-attest: <head sha> comment from a repository admin"
against a comment whose first line matched the head sha exactly. This
blocked every 0509 merge for hours.

PR #877 taught the decision script to do line-anchored extraction when
the caller ships raw `comments`, but the workflow never sent `comments`
in the first place — so the fix landed in the wrong place to take
effect. This PR closes the loop on the parked reusable's side: it now
ships raw `comments` and runs the same line-anchored scan in its
permission-prefetch loop, so collaborator-permission lookups stay
bounded to the set of users whose comments contain a qualifying marker
line. The security property is preserved — a prose sentence that merely
mentions the marker still does not attest, because the line must be the
marker and nothing else.

## Why this PR and not 0509

The bug exists in two places:

1. **The parked reusable** (`docs/pending-gate-integrity/reusable-gate-integrity.yml`)
   on `Nishfleet/fleet-ops` — fixed here.
2. **0509's own `gate-integrity.yml`** — the inline workflow that
   pre-dates the reusable and is not under fleet-ops scope. Filed as
   a follow-up issue (Nishfleet/0509 — see the issue tracker).

## Changes

**`docs/pending-gate-integrity/reusable-gate-integrity.yml`** — the
Python step no longer pre-extracts attestations; it ships raw `comments`
plus a `permissions` dict bounded to users whose comments contain a
qualifying marker line. The decision script's
`extract_attestations_from_comments` (PR #877) does the line-anchored
extraction.

**`docs/pending-gate-integrity/README.md`** — documents the new
attestation contract and points at the 0509 follow-up.

**`tests/gate-integrity-reusable-828.test.sh`** (new) — 10 fixtures
locking the contract end-to-end:

- `p1273_multiline` — the exact 0509#1273 repro body, now PASSes.
- `embedded_line` / `trailing_line` — marker line in the middle / at
  the end of a longer review comment.
- `prose_mention` — prose merely mentioning the marker does NOT attest.
- `stale_sha` — multi-line attest with a stale sha is rejected.
- `nonadmin` — multi-line attest by a non-admin is rejected.
- `crlf_body` — CR characters in the body do not break extraction.
- `no_whole_body_filter` — parked reusable must not contain the
  whole-body att-est test filter (greps the workflow source).
- `reusable_ships_raw_comments` — parked reusable must include
  `comments` in the bundle and must not pre-extract `attestations`
  arrays (greps the workflow source).

**`tests/seat-lib.test.sh`** — wires the new test through the existing
P14 seat-lib host because workers cannot add a P14 line in
`.github/workflows/ci.yml`.

## Inline workflow callers (NOT in scope)

0509's own `.github/workflows/gate-integrity.yml` has the same whole-body
filter and needs a matching fix in 0509's repo. The fix in 0509 is a
plain swap of the `select($b | test("^marker: ...$"))` filter for a
line-anchored scan against the comment body — the decision script's
`extract_attestations_from_comments` is the template. Filed separately;
not this issue's scope.

## Verification

```
$ bash tests/gate-integrity-reusable-828.test.sh
ok   p1273_multiline
ok   embedded_line
ok   trailing_line
ok   prose_mention
ok   stale_sha
ok   nonadmin
ok   crlf_body
ok   no_whole_body_filter
ok   reusable_ships_raw_comments
ok   ci_host (ci.yml listed=0, seat-lib hosted=1)

10 passed, 0 failed

$ bash tests/gate-integrity.test.sh
... 80 passed, 0 failed

$ bash tests/gate-integrity-reusable.test.sh
... OK: reusable gate-integrity workflow is shape-locked

$ bash tests/seat-lib.test.sh
... exit 0

$ bin/fleet-no-agent-names-check --commit-range HEAD~0..HEAD
OK: no agent attribution detected

$ bin/fleet-wipe-lessons-check scan --root /home/nish/workspaces/agent-worktrees/issue-fleet-ops-828
fleet-wipe-lessons-check: scan clean under /home/nish/workspaces/agent-worktrees/issue-fleet-ops-828

$ sgscan HEAD
No diff against origin/HEAD — scanning the working tree…
No new security findings.
```

run-proof: `bash tests/gate-integrity-reusable-828.test.sh` exits 0 with `10 passed, 0 failed` (fenced output above).

Closes #828
