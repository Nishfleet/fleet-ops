## What & why

`poolside/laguna-s-2.1-free` (commandcode, free-class) was wired at cap=1 in
prior PRs. #638 and #743 were stale duplicate canary tickets whose wiring PRs
landed first; #853 is the **original** canary ticket that filed when the slug
was unwired. It stayed open because the in-flight observe-to-close path
churned (manual worker test runs auto-closed it, Reopen comments restored it)
and then the mass-close guard reopened it — no merged PR referenced #853.

The slug is already wired and proven. This PR adds a dated #853 close-path
note to `_comment_laguna` in `config/seat-caps.json` so the merged-PR-close
retires the original ticket. No code/machinery change — paper only.

## Verification (Execution IS the review)

Deliverable run = the free-roster canary + a live spawn through pi, both
re-run after the edit.

```
$ bin/fleet-free-roster-canary
[2026-08-29T17:54:38Z] [fleet-free-roster-canary] LOUD [FREE-ROSTER-OK] gates clean; no unwired free slug and no stale wired free slug on free-class providers
$ echo $?
0

$ pi --print --provider commandcode --model poolside/laguna-s-2.1-free <<'EOF'
You have a bash tool. Compute 6*7 and reply with exactly: ANSWER=<n>
EOF
PACKET-VERDICT tools=0 class=no-tools
6*7=42
$ echo $?
0
```

Zero spend: no `~/.local/state/prepaid-usage/commandcode.json` meter file
exists; the slug's models.json cost column is `no`. Seat-health:
`provider=commandcode model=poolside/laguna-s-2.1-free http=200 class=healthy
observed=2026-08-29T17:53:13.799Z`.

Repo tests (run after the edit, all green):
- `bash tests/seat-caps-citation.test.sh` — OK (JSON parses, cap=0 reasons dated+measured, citation pinned)
- `bash tests/fleet-free-roster-canary.test.sh` — OK (scenario11: production seat-caps passes both gates; all 19 scenarios green)

run-proof: transcript `bin/fleet-free-roster-canary` -> `[FREE-ROSTER-OK] gates clean` exit 0 at 2026-08-29T17:54:38Z; live spawn `pi --print --provider commandcode --model poolside/laguna-s-2.1-free` -> `6*7=42` exit 0.

Closes #853
