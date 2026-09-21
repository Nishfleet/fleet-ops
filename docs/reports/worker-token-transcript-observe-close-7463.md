# Observe-close for #7463 — worker tokens in the pi-issue-7438 transcript: access, lifetime, and the gate that already blocks it

fleet-ops#7463 (filed 2026-09-17T15:27:33Z by `app/nishfleet-worker`) recorded
that the live `GH_TOKEN` of unit `pi-issue-fleet-ops-7438` appeared in that
unit's own tool output. The issue asks for three things: a read on access to
the captured run output and whether early revocation through the authorized
credential owner is needed, a fix to the existing token-check guidance so a
presence test cannot print the value, and no credentials copied into the issue
or its comments. This record is the assessment and the guidance-fix evidence;
the mechanical half this PR adds is one drill pinning the incident's exact
shape. Nothing credential-shaped was rotated, moved, or committed while
producing it. Credential actions belong to the token's owner (the canonical
reserved-classes list puts security and destructive steps with Nish).

## What leaked, and how

The unit left 8 sessions (2026-09-17T14:54Z – 2026-09-18T09:57Z). Token-shaped
values appear inside tool results of exactly 3 of them — 4 toolResult
messages total, every one the presence check printing more than emptiness.
Two shapes:

1. **The `:-` expansion — twice, including the session the issue names.** The
   unit's opening bash call (2026-09-17 first session) sent
   `echo "token: ${GH_TOKEN:+set}${GH_TOKEN:-empty}" | sed 's/.*/&/'` — the
   `:-` branch substitutes the value into the pipe. A repeat the next morning
   (2026-09-18T09:57 session) sent the cleaned-up variant
   `echo "token: ${GH_TOKEN:+set}${GH_TOKEN:-EMPTY}"`. Both are byte-for-byte
   the shape of the fleet-ops#7072 leak that #7381 was filed for, which the
   7438 worker had not seen yet: the leak predates the gate that landed
   2026-09-21 by four days.
2. **Bare echo of the whole variable.** The 2026-09-18T07:53 session ran
   `echo "GH_TOKEN=$GH_TOKEN"` — the value printed without even the `:-`
   indirection. The same call set also ran `gh auth status`.

Evidence (structures and counts only; the values are not reproduced here or
anywhere in this record or the PR):
`~/.pi/agent/sessions/pi-issue-fleet-ops-7438/2026-09-17T14-54-43-279Z_*.jsonl`
initial tool response, `2026-09-18T07-53-30-028Z_*.jsonl`, and
`2026-09-18T09-57-06-671Z_*.jsonl`. The other 5 sessions ran no presence
check and leaked nothing. A `:+`-only expansion prints `set` — constant
output, no value — and leaks nothing; the `:-` term is the leak. That is
exactly the distinction #7381's `secret_print` rule and drills encode, and the
7438 payload combined `:+` with a `:-` term.

## Token lifetime

Each leaked value is a nishfleet-worker App installation token — an ES256 JWT,
`iss=github`. Decoded `iat`/`exp` (claims only; the unit mints a fresh token
at its session's start, and each matches its session's first timestamp):

| session | `iat` | `exp` | lifetime |
|---|---|---|---|
| 2026-09-17T14:54:43Z | 14:54:43Z | 15:54:43Z | 3600 s |
| 2026-09-18T07:53:28Z | 07:53:28Z | 08:53:28Z | 3600 s |
| 2026-09-18T09:57:04Z | 09:57:04Z | 10:57:04Z | 3600 s |

At the issue's filing time (15:27:33Z) the first token had about 27 minutes of
life left — the only window in which revocation could have changed anything.
As observed now, all three are dead for well over three days: there is
nothing live to revoke, and no revocation or rotation was performed. The token's grant is
the fleet's standard one (Contents/PRs/Issues write, Metadata read, no
Workflows, no Administration) and it stays that way in AGENTS.md; the App's
private key was never in play — only the derived ≤1h installation tokens.

## Where the captured output went

- **Local transcript.** The session files are mode 0664, owner/group `nish`,
  under `~/.pi/agent/sessions/`. They are not committed to any repo tree and
  no organ in this repo ships them off-host (the only references are the
  systemd `--session-dir` flags that write them).
- **Readable by every seat.** Any process running as `nish` — which includes
  every fleet worker — can read them. The blast radius of a transcript leak
  is "the whole fleet can read it", not "only the unit".
- **The model route.** A tool result is replayed to the model to continue the
  agent loop, so each leaked value also left the host along that seat's
  LiteLLM route and was seen by whatever provider served the turn. This
  channel is what the print IS — the value entered the model's input — and
  the same 3600-second expiry bounds it: expired tokens cannot act, and the
  provider-side retention holds only a value that is already dead.
- **No post-hoc scrub.** Nothing redacts a transcript after the fact, so the
  dead values persist in the local files. The durable control is preventive —
  stopping the print before it lands.

## The guidance fix, and the gate that carries it

The issue's second ask — fix the existing token-check guidance — is satisfied
on `origin/main`, ahead of this record:

- `AGENTS.md`, the context file every worker loads once per run, now reads the
  ONLY presence check as `test -n "$GH_TOKEN"` with constant output, bans the
  `${GH_TOKEN:-...}`/`${GH_TOKEN:+...}` expansion idioms and the
  `printenv`/`env`/`set`/`declare -p` dumps, and names the gh
  auth-status/auth-token subcommands as token-printing.
- `template/extensions/permission-gate.ts` carries the mechanical half: the
  `secret_print` expansion rule landed via PR #8092 (merge
  `a3adf870277feafe50f8f9f029a9381750ca7bc8`, 2026-09-21T19:53:46Z; ancestor
  of `origin/main`), and the auth-output rule via PR #8129 (merge
  `fad3cd5c0523edaae7f7b76a7e69fb4c168e7961`, 2026-09-21T21:53:06Z; ancestor
  of `origin/main`).

Both of this issue's shapes are blocked by the live runtime gate today —
verified by calling `secretPrintBlock()` against the **installed** seat copy
(not the template): all three leaked commands above return
`secret_print cmd=echo`, and the bare-variable shape too. The `gh auth status`
call in the same 07:53 call set is blocked by the #8129 half in the repo, but
the installed copy does not carry that half yet — the two fork files are one
of the four hand-refreshed copy classes in this repo's README, and the #8129
refresh has not been run. The drift is what this repo's own
`tests/pi-extensions-forks-live.test.sh` exists to catch (it is red at the
time of writing), and it is filed separately rather than silently
hot-refreshed here — the gate change is merged and reviewed, the refresh is a
one `install -D -m 0644` line, and it deserves a tracked record instead of an
untracked host edit (the copy-class precedent is #7810).

This PR adds the exact 2026-09-17 shape — trailing `sed`, lowercase branch,
and the allowed `[ -n "$GH_TOKEN" ]` check in the same call — as a drill in
`tests/permission-gate-worker-toolchain.test.sh`, next to the cleaned-up #7381
drill, so the incident's real shape is pinned by a repo test and a future
gate edit that drops the block fails the test rather than re-opening the
leak.

## Read

Nothing structural remains for #7463: the leaked values are dead by
mechanism, the guidance workers load is fixed, the gate that blocks the exact
shapes is installed and verified live against the installed file, and the
test the incident shape fails-on-drop is part of the suite through this PR's
drill. The one open thread is the copy-class refresh of the #8129 half,
tracked separately (see above) — it does not affect this issue's vector,
which the installed gate blocks. The 2026-09-17 shape is the third report of
one class — #7072/#7381 and #7440/#7448 are the first two, both closed with
the same mechanism this record verifies — and #7463 is closed here as the
observe-close record of that class's final instance, not a new mechanism.

No credential value appears in this record, in the issue, or in the PR text;
only decode timestamps and counts do.
