# Cloudflare work moves to the cf CLI

Nish's standing rule (2026-09-28) is that Cloudflare work uses the `cf` CLI:
Wrangler is a last-resort fallback, and only after Nish approves that specific
use. The one exception he approved (2026-10-18) is `wrangler d1 export` in the
weekly D1 backups.

This page is the record of where each deploy job stands against that rule, so
the next person does not have to re-derive it. It is a pointer to the tracking
issue for each row, not a second source for the work itself. Swept on 2026-10-29.

## Where each repo stands

"Calls" is what the default branch runs today, not what a pull request
proposes. A repo reads clean only when its own default branch is clean.

| Repo | Deploy job calls on main | State | Tracking |
| --- | --- | --- | --- |
| `Nishfleet/fleet-console-worker` | `npx --yes wrangler@4.120.1 deploy` | the switch to `cf deploy` is written and open as a pull request | Nishfleet/fleet-console-worker#22 |
| `Nishfleet/inish-mail-filter` | nothing, the job is gone | done | Nishfleet/fleet-ops#9896 |
| `Nishfleet/seo-fix-kit` | `wrangler d1 migrations apply`, `wrangler deploy` | blocked | Nishfleet/seo-fix-kit#331 |
| `Nishfleet/mailbox` | `wrangler deploy` | blocked | Nishfleet/mailbox#80 |
| `Nishfleet/0509` | `wrangler d1 time-travel info`, `wrangler d1 migrations apply`, `wrangler deployments status`, `wrangler rollback`, `npm run deploy`, three `wrangler deploy --config` steps | blocked | Nishfleet/0509#5916, Nishfleet/0509#6087 |

`Nishfleet/drive` was already on `cf` before this sweep, so it is not a row.

## Why the three blocked rows cannot switch yet

Each blocker is a build or toolchain fact, not a preference. The issue named
against each row carries the detail.

- **seo-fix-kit** — `cf deploy` builds the Worker with Vite and nothing else,
  so the prerender step the repo's build runs today never runs, and the page
  that ships is the empty app shell instead of the prerendered HTML. The same
  Vite build also writes its output somewhere other than the directory the
  repo's own required check gate reads. Both have to move before the deploy
  job can switch.
- **mailbox** — the Vite plugin `cf` needs to build a Worker is a v2 beta, and
  it requires Vite 7 or 8. This repo is on Vite 6, so `cf deploy` cannot build
  it at all today.
- **0509** — `cf deploy` cannot build this Worker because of the React Router
  manifest path conflict already filed as Nishfleet/0509#6087. Two further
  gaps are recorded as a comment on Nishfleet/0509#5916: `cf` has no command
  that rolls a Worker version back (only Pages), and `cf deploy` has no flag
  that names a second config file, so the three fixture Workers this job
  deploys have no `cf` equivalent either.

## What `cf` covers and what it does not

Checked against `cf` 1.0.0-beta.25 with `cf cli search`.

| Wrangler call in a deploy job | `cf` equivalent | Note |
| --- | --- | --- |
| `wrangler d1 time-travel info` | `cf d1 time-travel get-bookmark` | same bookmark |
| `wrangler d1 migrations apply <name> --remote` | `cf d1 migrations apply` | wire-compatible, but it takes the database id. A name or a binding name is not accepted. |
| `wrangler deployments status --json` | `cf workers deployments list` | |
| `wrangler rollback` | none | `cf pages deployments rollback` is Pages, not Workers. |
| `wrangler deploy` | `cf deploy` | builds through the Vite plugin, so the repo's build has to run through Vite too |
| `wrangler deploy --config <file>` | none | `cf deploy` reads one config and has no flag that names another |

## How to check a repo

Read the deploy job and look for `wrangler`:

    gh api repos/<owner>/<repo>/contents/.github/workflows/deploy-production.yml --jq .content | base64 -d | grep -n wrangler

A repo that answers nothing is done. A repo that answers with a line other than
`wrangler d1 export` is still on Wrangler, and an open pull request does not
change that answer until it merges.

## The guard that already holds new uses

`config/risky-paths.json`'s `prod-deploy` entry already treats a
`wrangler deploy` line as a production-deploy risk, and
`agent-dispatch.yml`'s `hold-risky` job reads that file from fleet-ops main, so
every enrolled repo uses the same copy. A PR that adds a Wrangler deploy line is
held for the coordinator.

What that guard cannot see is a Wrangler call that is already on the default
branch and that no PR touches, and it does not run at all in a repo that is not
enrolled. Sweeping those needs a token that reads another repo's files, which
the token a fleet-ops workflow holds cannot do, so this page is the record
instead until that changes.
