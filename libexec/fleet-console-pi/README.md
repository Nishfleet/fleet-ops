# fleet-console-pi — the nish.sh/fleet console generator

The live-truth console at `https://nish.sh/fleet` (Cloudflare Access-gated).

## Change path (fleet-ops#5469)

**This directory is the canonical, reviewable source.** Changes land by the
normal fleet-ops PR flow — there is no separate console repo to push to.

Deploy is automatic, no hand step:

1. A PR merges to `main`; the deploy-clone
   (`/home/nish/workspaces/tooling/fleet-ops-deploy-clone`) converges to
   `origin/main`.
2. `~/.local/libexec/fleet-console-pi/` holds symlinks into that checkout
   (`generate.py`, `push.sh`, `shell.html`, `verify.py`); `data.json` and the
   `.pushed-*.sha` stamps are runtime state next to the symlinks.
3. The existing 12-min `fleet-console-pi.timer` runs
   `fleet-console-pi.service` → `push.sh` → `generate.py` + `verify.py` →
   `wrangler kv key put` of `fleet` (data.json) and `shell` (shell.html)
   into namespace `e39df754bd1f4085a50818e992ad4050`, which the
   `fleet-console` Worker serves at nish.sh/fleet.

Manual deploy (only when the timer must not be waited on):

```bash
/home/nish/.local/libexec/fleet-console-pi/push.sh
```

Proof a change is live: `wrangler kv key get shell --namespace-id
e39df754bd1f4085a50818e992ad4050 --remote` (or `fleet` for data.json) — the
KV bytes ARE what the Worker serves. A bare `curl https://nish.sh/fleet`
returns the Cloudflare Access login page, not the console.

## The orphaned checkout — do not edit it

`/home/nish/workspaces/tooling/fleet-console-pi/` is a **stale, remote-less
git repo** — an early copy that predates the move into fleet-ops. Nothing
deploys from it; its `fleet-console-pi.service` file is not the installed
unit. Two workers (fleet-ops#5466, #5469) mistook it for the live source.
Edit THIS directory, never that one.
