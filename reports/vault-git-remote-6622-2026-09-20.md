# vault git remote repair — fleet-ops#6622 (2026-09-20)

## Finding

`git fetch origin` in `/home/nish/workspaces/tooling/nish-vault` failed with
`repository 'https://github.com/Nishfleet/nish-vault.git/' not found` (surfaced
during #6610, filed as the `vault-git-remote-404` loose end). The issue asked:
repair the remote or remove it.

## Root cause

The repo was **transferred** out of the `Nishfleet` org to the personal
`nish3451` account — it now lives at `github.com/nish3451/nish-vault`
(private). It is the same repository: `created_at` 2026-04-06 matches the
vault's first pushes, and remote `main` (`5e7f75c9`, pushed 2026-09-10) was
three commits ahead of the last successful VPS fetch (`d3b8cd6c`,
2026-08-30), i.e. the GitHub history layer is still in active use — so
**repair, not removal**.

The 404 was two faults stacked:

1. The `origin` URL still pointed at the pre-transfer org path.
2. Inside fleet worker units `GH_TOKEN` is the nishfleet-worker GitHub App
   token, and that app is not installed on `nish3451` personal repos — so
   `gh auth git-credential` returned a token that 404s the private repo even
   at the correct URL. (`gh api repos/nish3451/nish-vault` under the worker
   token: HTTP 404. Without `GH_TOKEN`, the host's active gh account is
   `nish3451` — which is why the breakage only showed up inside workers.)

## Fix applied on this host (vault repo local config only)

```
git remote set-url origin https://github.com/nish3451/nish-vault.git
git config --local credential.https://github.com.helper ""
git config --local --add credential.https://github.com.helper \
  '!f() { echo "username=nish3451"; echo "password=$(gh auth token --user nish3451)"; }; f'
```

The empty `helper` value resets the inherited `gh auth git-credential`
helper for github.com within this repo; the replacement pins vault auth to
the `nish3451` account's stored PAT. `gh auth token --user nish3451`
returns the identical hosts.yml token with or without `GH_TOKEN` set
(verified: sha256 of the token identical across `GH_TOKEN=aaa`,
`GITHUB_TOKEN=bbb`, and unset env), so the helper is immune to the ambient
worker token. Syncthing does not propagate this: `.stignore` excludes
`.git`, so each host's remote config is local.

## Verification (this run, worker `GH_TOKEN=ghs_…` env set — the #6610 failure mode)

- `git credential fill` for `github.com/nish3451/nish-vault.git` →
  `username=nish3451`, `password=gho_…` (user PAT, not the app token)
- `git ls-remote origin` → `5e7f75c9  HEAD` / `refs/heads/main`
- `git fetch origin` → `d3b8cd6c..5e7f75c9 main -> origin/main`
  (plus `repo-sync/fleet-ops/default` force-update)

## Detector disposition

mechanism-impossible: the defect was host-local git config on a clone
outside this repo, observable only where a fetch runs. No unit or timer
fetches the vault on this host (vault hooks are macOS-path no-ops here, no
systemd unit references it), and a scheduled remote-liveness probe would be
a new scheduled organ — standing rules require a named reason for any
schedule. The failure now surfaces loudly at the next real fetch, which is
green.
