# Observe-close for #7448 — worker token in the pi-issue-7440 transcript: access, lifetime, and the two gate halves

fleet-ops#7448 (filed 2026-09-17T15:23:09Z by `app/nishfleet-worker`) recorded
that the live `GH_TOKEN` of unit `pi-issue-fleet-ops-7440` had appeared in that
unit's own tool output. The issue asks for two things: a security read on
transcript access and token lifetime, and a prevention so a presence check
cannot print the credential again. This record is the assessment; the code half
is this same PR.

Nothing credential-shaped was rotated, moved, or committed while producing this
record. Credential actions belong to the token's owner (the canonical
reserved-classes list puts security and destructive steps with Nish).

## What leaked, and how

Both leaks came from the same improvised presence check in one session, and
both were the check printing more than emptiness:

1. An expansion whose payload was
   `token: ${GH_TOKEN:+set}${GH_TOKEN:-EMPTY}` — the `:-` branch yields the
   value. This is byte-for-byte the shape of the fleet-ops#7072 leak that
   #7381 was filed for.
2. The auth-status subcommand of `gh`, piped through `head`. On this host
   (gh 2.93.0) an env-var account prints the installation token in full except
   a trailing mask; `hosts.yml` accounts print `gho_****`, so the leak is
   specific to the token-in-environment deployment the fleet uses.

Evidence: `~/.pi/agent/sessions/pi-issue-fleet-ops-7440/2026-09-17T14-55-02-677Z_fleet-ops-7440-1789656902338290361.jsonl`.
The unit's second session
(`2026-09-17T17-27-15-296Z_…`) used the `:+` shape, which prints `set`/`yes`
rather than the value, and leaked nothing. The `:-` versus `:+` distinction is
exactly what #7381's `secret_print` rule and drills encode.

## Token lifetime

The leaked value was a nishfleet-worker App installation token — an ES256 JWT,
`iss=github`. Its `iat`/`exp` claims are 2026-09-17T14:55:02Z and
2026-09-17T15:55:02Z: a 3600-second lifetime, expiring about 32 minutes after
the leak and long before this assessment. No rotation is warranted; there is
nothing live to revoke. The token's grant is the fleet's standard one
(Contents/PRs/Issues write, Metadata read, no Workflows, no Administration) and
it stays that way in AGENTS.md.

## Transcript access

- **Local only.** The session files are mode 0664, owner/group `nish`, under
  `~/.pi/agent/sessions/`. They are not committed to any repo tree and no
  organ in this repo ships them off-host.
- **Readable by every seat.** Any process running as `nish` on this host can
  read them, which includes every fleet worker. The blast radius of a leak into
  a transcript is therefore "the whole fleet can read it", not "only the unit".
- **No post-hoc scrub.** Nothing redacts a transcript after the fact, so a
  printed credential persists in the local file. The durable control is
  preventive — stopping the print before it lands — which is what the two gate
  halves do.

## The two gate halves, and where each lives

| half | leak vector | gate | landed |
|---|---|---|---|
| expansion | `:-` branch / `printenv` / env dumps / `set -x` / unquoted heredoc | `secret_print` in `template/extensions/permission-gate.ts` | PR #8092, merge `a3adf870277feafe50f8f9f029a9381750ca7bc8` (ancestor of `origin/main`) |
| auth output | auth-status and auth-token subcommands of `gh` | `secret_print cmd=gh-auth-*` (same file), the committed-surface step in `.github/workflows/ci.yml`, the AGENTS.md clause, drills in `tests/permission-gate-worker-toolchain.test.sh` | this PR |

The split matters: #7381 closed the expansion class on 2026-09-21, but #7448's
prevention clause also names the auth-status output, and #8092 does not cover
it. This record and this PR are the second half.

## Read

The unfixed part is not a mechanism that can be fixed: a value already written
into a local transcript cannot be un-written, and the token that leaked is
already dead. What can be closed is the vector — the auth-status half of the
prevention clause is now blocked at the runtime gate (every seat), scanned on
the committed surfaces an agent reads or runs, and written into the AGENTS.md
invariant workers load once per run. The drills in
`tests/permission-gate-worker-toolchain.test.sh` pin the block and the
allow-cases (prose mentions, `auth logout`, `auth login --with-token`), so a
future edit that widens the gate into false positives, or drops it, fails a
repo test rather than silently re-opening the leak.
