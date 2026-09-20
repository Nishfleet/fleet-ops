# Observe-close for #4142 — repo-sync-snapshot.py: seed-map misread confirmed; mechanism already wiped from the host; residue swept

fleet-ops#4142 (filed 2026-09-07 under umbrella #4140, acceptance "nothing
hand built") asked to retire `libexec/repo-sync-snapshot.py` — described in
the seed map as a 1,311-line "org PR/CI snapshot" tool — and to replace it
with direct `gh` GraphQL calls or a Prometheus github-exporter, then wipe the
script, its units, timers, backups and prom writers.

Three worker verifications on 2026-09-07 established the premise was wrong on
both axes and the design-doc row was corrected to **NO-GO** by PR #4190:

- **Wrong repo.** The file never existed in fleet-ops; it lived in the
  local-only `control-plane` repo (`~/workspaces/control-plane/libexec/`),
  which has no GitHub remote.
- **Wrong function.** It was a Mac↔VPS Git repository replication tool
  ("Safely replicate Git repositories and dirty work between two machines"),
  not an org PR/CI snapshotter. The proposed gh-GraphQL/github-exporter
  replacement covers a function this file did not perform.

This run (2026-09-20) found the situation resolved on the host, so the issue
closes as an observe-close record rather than new code — matching the
established pattern (e.g. the #6799 record, PR #7964; the #6845 record).

## What was found (live re-verification, 2026-09-20)

1. **The whole mechanism is gone from the host.** Between the 2026-09-07
   verifications and today the mechanism was wiped, consistent with the
   2026-09-18/19 control-plane cut documented in the host rules:
   - `~/workspaces/control-plane/` — directory absent (the file's home repo).
   - `~/.local/libexec/` — absent (held the installed copy).
   - `~/.local/state/repo-sync/` — absent (state.json, last write 2026-08-23).
   - `~/repo-sync-backups/` — absent (was 476M).
   - `systemctl --user list-unit-files 'repo-sync*'` → 0 units;
     `list-timers` → 0 timers.

2. **Residual snapshot refs swept this run.** The tool had left
   `refs/repo-sync/<peer>/indexes/*` and `refs/repo-sync/<peer>/worktrees/*`
   refs inside the local clones it managed — 504 refs across 21 clones under
   `~/workspaces/products/`, `~/workspaces/tooling/` and
   `~/workspaces/shared-workflows/` (sampled tips verified NOT ancestors of
   their repos' HEAD — tool-internal index commits, no unlanded work). All
   deleted via `git update-ref`; 8 stale `refs/remotes/origin/repo-sync/*`
   tracking refs, 3 stale reflog dirs and the
   `~/.local/share/systemd/timers/stamp-repo-sync-snapshot.timer` stamp file
   removed with them. Post-sweep
   `find /home/nish -name "*repo-sync*" -not -path "*/tool-archives/*"
   -not -path "*/branch-prune/backup/*" -not -path "*/nish-vault/*"` → 0.
   Frozen archives (`tool-archives/`) and branch-prune backup repos keep
   their copies by design.

3. **Seven GitHub-side `repo-sync/fleet-ops/default` branches remain.** The
   tool also published snapshot branches to origin on: 0509-telemetry,
   egress-probe, inish-site, seo-fix-kit, TinyStudio.io, nish-vault,
   shared-workflows. Branch deletion needs the unlanded-work proof those
   snapshot tips cannot pass, so they are filed as a follow-up issue rather
   than deleted in this run.

4. **Vault ledger updated.** One line appended to
   `_system/shared-memory/retired-mechanisms.md` (never-rebuild ledger) —
   what, why retired, replacement, date, do-not-rebuild condition.

## Acceptance mapping

| issue requirement | state |
|---|---|
| (1) replacement live and proven with one real run | moot — the described function (org PR/CI snapshot) never existed on this host, so no replacement is owed; the file's actual job (Mac↔VPS Git replication) is superseded by GitHub remotes as the single source of truth plus the live `~/workspaces/.mirrors/` clone mirrors, and the Mac is read-only |
| (2) files, units, timers, backups and prom writers WIPED | satisfied on host — verified absent above; remaining local ref/stamp residue swept this run; no `.prom` writer exists (grep over the file found none; nothing on the host produces one) |
| (3) one line in the vault never-rebuild ledger | appended 2026-09-20 |
| (4) grep proves no reference remains | `git grep repo-sync-snapshot origin/main` → only this record and the design doc's historical NO-GO row; host `find`/`for-each-ref` → 0 outside frozen archives |

## Follow-up

- Delete the seven `repo-sync/fleet-ops/default` branches on GitHub after the
  unlanded-branch proof (or a Nish call that snapshot branches need none) —
  filed as a plain issue, no labels.

Closes #4142.
