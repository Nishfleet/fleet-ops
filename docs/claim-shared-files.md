## Claim shared files before editing (interactive sessions)

Queued work has an atomic lock — the `claim/issue-N` branch. Interactive
sessions claim the same way, with stock git only: push a
`claim/adhoc-<scope>` branch from `main` before touching a shared file.
A pushed branch is the fleet-visible occupied sign, and a create-only push
collides atomically for a second claimant. Convention: **use the shared
file path as the scope** so two agents on the same file pick the same
branch name. `git ls-remote origin 'refs/heads/claim/*'` plus `gh pr list`
is the pre-flight conflict check; delete the branch when done.
`bin/fleet-claim`, the helper that wrapped this, was deleted in the glue
sweep — the stock push is the whole mechanism.

Stale interactive **sessions** are no longer reaped by a bespoke timer:
`interactive-session-reap` was deleted on 2026-09-18 after 113 consecutive
hourly runs that each reaped nothing. `systemd-oomd` is the native reaper
under real memory pressure. sshd, tailscaled, and the runner services are out
of scope: they do not live in `session-*.scope`. `claim/issue-*` and
`claim/adhoc-*` branches are released by the agent that claimed them.

