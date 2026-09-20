# Hand-placed drop-in observe-close for #6575 — fleet-idea-intake.service.d/zz-gate-retry.conf

Issue #6575 (filed by fleet-blind-audit, 2026-09-13T22:07:44Z) flagged
`~/.config/systemd/user/fleet-idea-intake.service.d/zz-gate-retry.conf` as a
non-symlink drop-in with no repo source, severity high: "absorb into the
repo + MANIFEST, or delete if superseded; route to senior conference when
the override is new machinery."

The drop-in and the unit it overrode are both already gone from this host.
This report is the resolution record; no new code is needed.

## Provenance

- `fleet-idea-intake.service` was hand-placed control-plane for the retired
  idea-intake lane. Its drop-in `override.conf` re-pointed ExecStart through
  the `fleet-gate` wrapper at `agent-state/idea-intake/run-intake.py`,
  `run-bootstrap.py` and `agent-state/campaigns/campaignlib.py` (sealed
  packet 2026-08-11). `zz-gate-retry.conf` was a `gate-retry` marker next to
  it, beside `zz-gate-retry.conf.bak-time-audit-20260812`.
- The unit was never repo-sourced: `git log --all -- '*fleet-idea-intake*'`
  over the full mirror history returns zero path hits.
- fleet-ops#4435 → PR #4438 (merge commit
  `188d97dc9cfd124b5d6c0bb79402c7d042cd592e`, merged 2026-09-08) had already
  added orphaned-dir removal for `fleet-idea-intake.service.d` to
  `install.sh`/`fleet-ops-deploy`; the blind audit still found
  `zz-gate-retry.conf` present on 2026-09-13.
- The user journal carries no `removed orphaned
  fleet-idea-intake.service.d` line since 2026-09-13, so the deletion did
  not come through the install.sh path. It was most plausibly removed
  during the 2026-09-18 sweep or by one of this issue's earlier claims
  that died before opening a PR; the deletion event itself is not
  journaled. The file is gone now and cannot be restored by any live
  mechanism: no unit exists to override and the copy machinery is deleted.

## Why neither acceptance branch needs new work

- "Absorb into the repo + MANIFEST" is moot twice over: there is no
  `fleet-idea-intake` unit left for an override to configure, and MANIFEST
  itself was deleted in `72b38e85` (cut of the copy-then-detect-drift
  deploy cluster, merged 2026-09-18). Live unit paths are symlinks into
  the repo; nothing is copied and nothing tracks copies.
- "Delete if superseded" is already the live state, verified below. The
  override's entire payload is dead: `agent-state/idea-intake/`,
  `agent-state/gate/` and `agent-state/campaigns/` no longer exist.
- Not new machinery, so no senior conference: it was residue of a retired
  lane.

## Verification (2026-09-20 ~03:00 UTC, worktree at e5463d725)

- `systemctl --user cat fleet-idea-intake.service` → "No files found for
  fleet-idea-intake.service."; `systemctl --user show` → empty
  FragmentPath and DropInPaths, ActiveState=inactive.
- `ls ~/.config/systemd/user/fleet-idea-intake.service.d/` → ENOENT;
  `find ~/.config/systemd -iname '*idea-intake*' -o -iname '*zz-gate*'` →
  zero hits (no `.conf`, no `.bak`, no dir residue).
- `systemctl --user list-unit-files | grep -i idea` → no unit files;
  `list-timers` shows no idea-intake or blind-audit timer.
- `git merge-base --is-ancestor 72b38e8578… origin/main` passes — the
  deploy-cluster cut that deleted `install.sh`, `MANIFEST`,
  `bin/fleet-ops-deploy`, `bin/fleet-deploy-check` and
  `bin/fleet-ops-drift.py` is on main.
- `grep -rn 'zz-gate-retry\|fleet-idea-intake'` over the origin/main
  checkout hits only untracked `.fleet/` bench fixtures — no live code,
  test, or config reference.
- `grep -rln 'blind-audit' systemd/ bin/ lib/ config/ .github/` → no hits;
  the organ that filed this class was retired in the 2026-09-18 sweep.

## Leftovers, deliberately untouched

Five other non-symlink drop-in `.conf` files remain under
`~/.config/systemd/user/*.d/` — `fleet-work.slice.d/override.conf`,
`fleet-litellm-proxy.service.d/30-jev-passthrough.conf`,
`pi-intake@0509.service.d/timeout.conf`,
`gpg-agent.service.d/20-oom-omit.conf` and
`pi-scout-repair@.service.d/20-lane-slow-timeout.conf`. Same audit class,
different units; outside this issue's named target. With fleet-blind-audit
retired, no live detector will re-file them.

## Disposition

Resolved-by-deletion, matched to the 2026-09-18 deploy-cluster cut
(`72b38e85`) and the retired idea-intake lane. The finding cannot re-open:
no unit, no override, no ExecStart targets, and no copier that could
restore them. This report supplies the acceptance evidence; no new
detector, unit, configuration, or runtime code is required.
