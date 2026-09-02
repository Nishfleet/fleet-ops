## Why

Issue #2742 listed two seats as `seat_dead=true` with `failure_mode=credentials_bad` and asked to re-auth them or drop them from the seat map:

- `commandcode/minimax/minimax-m3-free` HTTP 403
- `opencode/hy3-free` HTTP 401

Both rows were already retired (`cap=0`, `intentional_cap_zero=corpse`) by #2700/#2708 and #2667/#2741. Live probing found no dead credential. Each provider key is alive. The slugs are gone. This PR stamps the current-date re-verification, adds the missing hy3-free production lock (19b only pinned the commandcode sibling), and closes the duplicate.

## Scope

- `config/seat-caps.json` `providers.commandcode._comment_minimax_m3_free` and `providers.opencode._hy3free`: 2026-09-02 re-verification paragraphs for fleet-ops#2742. No cap change, no model change, no billing sibling.
- `config/entitled-seats.json` commandcode note: the minimax-m3-free allowlist row is marked RETIRED corpse.
- `tests/fleet-free-roster-canary.test.sh` scenario19c: production lock that the opencode `hy3-free` row stays present, capped 0, `intentional_cap_zero=corpse`, with `_hy3free` dated and citing `fleet-ops#2667`. A later PR that removes the row or re-raises the cap without a passing re-audition fails here.

## Blast Radius

Caps stay 0. `pick_seat` already excludes both as `cap=0:model` (intentional corpse). The lock only stops a later PR from re-wiring a dead slug. No organ, timer, or workflow change.

## Verification

Live probes 2026-09-02T17:14Z (this worker):

```
$ pi --print --provider commandcode --model minimax/minimax-m3-free 'reply PONG'
403: {"message":"The free MiniMax M3 and M2.7 models have been retired. Run /model and pick MiniMax M3 or MiniMax M2.7 to keep going.","type":"permission_error","code":"FORBIDDEN"}
PACKET-VERDICT tools=0 class=no-tools
rc=1

$ pi --print --provider commandcode --model poolside/laguna-s-2.1-free 'reply PONG'
PONG
rc=0

$ pi --print --provider opencode --model hy3-free 'reply PONG'
401: {"type":"ModelError","message":"Model hy3-free is not supported"}
PACKET-VERDICT tools=0 class=no-tools
rc=1

$ pi --print --provider opencode --model nemotron-3-ultra-free 'reply PONG'
429: {"type":"FreeUsageLimitError","message":"Rate limit exceeded. Please try again later."}
rc=1

$ pi --print --provider opencode --model mimo-v2.5-free 'reply PONG'
429: {"type":"FreeUsageLimitError","message":"Error from provider (Console): Rate limit exceeded. Please try again later."}
rc=1

$ pi --print --provider opencode --model ling-3.0-flash-fin-free 'reply PONG'
PONG
rc=0
```

Router skip (same worktree, live caps):

```
$ pick_seat "" "" 0
ollama	deepseek-v4-flash:0731
pick_seat: excluded 24 seats (cap=0: 10; dead: 1; not-in-allowlist: 13) [cap0-intentional: 5; cap0-stale: 4] [...,commandcode/minimax/minimax-m3-free,...]
```

Neither corpse was selected. Caps: `SEAT_MODEL_CAP[commandcode/minimax/minimax-m3-free]=0` icz=corpse; `SEAT_MODEL_CAP[opencode/hy3-free]=0` icz=corpse.

Repo tests:

```
$ python3 -c "import json; json.load(open('config/seat-caps.json')); json.load(open('config/entitled-seats.json')); print('JSON valid')"
JSON valid

$ bash tests/fleet-free-roster-canary.test.sh
OK: scenario19b: production seat-caps keep commandcode minimax/minimax-m3-free retired at cap=0 corpse with dated reason and no billing sibling
OK: scenario19c: production seat-caps keep opencode hy3-free retired at cap=0 corpse with dated reason and no billing sibling
OK: fleet-free-roster-canary: ollama carve-out, penny-for-speed, freshness, stale, cap, dedup, prod clean, deepseek-v4-flash-free bench lock, observe-to-close

$ bash tests/seat-caps-citation.test.sh
OK: seat-caps-citation: orcarouter citation pinned, order clean, JSON parses, cap=0 reasons across the fleet are dated + measured, model cap=0 reasons pinned

$ bash tests/entitled-wired-canary.test.sh
OK: entitled-wired-canary: missing row, undated cap=0, class mismatch, empty-models, dedup, production clean

$ bash tests/seat-health-seat-dead.test.sh
OK: fleet-ops#2145/#2327/#2415 closure: corpses ... are seat_dead=true ...

$ bash tests/credential-expiry-canary.test.sh
OK: credential-expiry-canary (fleet-ops#938 + #2134 pre-expiry probe)

$ bash tests/fleet-seat-comeback-release.test.sh
ALL OK: active come-back release path ...

$ bash tests/seat-lib-aimd.test.sh
All AIMD invariants passed.
```

run-proof: live transcript — `pi --print --provider commandcode --model minimax/minimax-m3-free 'reply PONG'` returns 403 FORBIDDEN at 2026-09-02T17:14:47Z; control `poolside/laguna-s-2.1-free` returns PONG. `pi --print --provider opencode --model hy3-free 'reply PONG'` returns 401 ModelError at 2026-09-02T17:14:47Z; control `ling-3.0-flash-fin-free` returns PONG in the same window (nemotron-3-ultra-free and mimo-v2.5-free hit a provider-wide 429 FreeUsageLimitError, not an auth fault). Caps stay 0 corpse. Regression guard is scenario19b (commandcode) + scenario19c (opencode hy3-free).

SKIP, reported so it cannot drift: `crgate` could not run on this host — `CodeRabbit is not signed in on this machine` (`coderabbit auth login` is interactive). `sgscan --base origin/main` ran clean (No new security findings). Greptile and autoreview still gate this PR.

PRE-EXISTING, filed as a new issue, not fixed here:

- #2865 — `bin/fleet-seat-comeback-release --help` and `bin/fleet-seat-live-validate --help` ignore the flag and run the live organ.

Also already open, not this issue:

- #2739 — `seat-health.ts` maps a "model not supported" 401/403 to `credentials_bad`.
- #2734, #2809 — stale duplicates of the same two corpses.

loose-ends-canary: pr:nishfleet/fleet-ops#2866 stale-worker-pr

Closes #2742
