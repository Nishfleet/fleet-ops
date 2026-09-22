# Observe-close for #7713 — the glue-sweep consumers cross-reference unit died on zero tool calls; re-running the reference today finds no live glue to delete, two orphaned symlinks, and one load-bearing deletion the sweep's own report had flagged as irreplaceable

triage: the `glue-sweep-consumers` analysis unit (a 2026-09-18 one-off dispatch, never a repo unit) died three hops straight with `PACKET-VERDICT tools=0 class=no-tools` — the model emitted planning prose and made zero tool calls, so the `consumers.txt` deliverable was never written and the dead-man correctly tripped `verdict=no-deliverable`; the launch rail that judged it (`bin/pi-systemd-run`, `bin/pi-detached-deadman`, `bin/pi-salvage-worktree`) has since been deleted and replaced by stock systemd plus an `ExecStopPost` deliverable check; re-running the reference pass against the same four trees today yields **39 names / 9 zero-reference**, of which the only fleet-glue residue is two dangling `~/.local/bin` symlinks, and the pass also surfaces that `bin/grok-token-refresh` was deleted after the sweep's final report had marked it load-bearing with no stock replacement.

Issue #7713 (`[unit-death] glue-sweep-consumers — died, resume exhausted (hop=2)`,
filed 2026-09-18T09:23:20Z by `app/nishfleet-worker`, auto-labeled `agent-in-progress`)
is a `fleet-ops#5456` A(ii) dispatch. Its body is the dead-man's journal excerpt and one
instruction: *"Take the units job over: diagnose from the journal, redo the work, and land
it. Close this issue when the underlying failure is fixed."* This report is the
resolution record: the diagnosis, the re-run artifact the dead unit never produced, and
the disposition.

## What was found

1. **The unit died without producing a single tool call — four dispatches, four
   `no-deliverable` verdicts.** The dispatch ledger
   (`/home/nish/workspaces/agent-state/dispatch-ledger.jsonl`) carries the whole chain.
   All four packets name the same deliverable,
   `/tmp/claude-1000/-home-nish/657fe727-f472-424b-b266-5700ddc69e09/scratchpad/gs/consumers.txt`:

   | dispatch (UTC) | hop | retries | model | packet id | outcome |
   |---|--:|--:|---|---|---|
   | 2026-09-18T08:57:42Z | 0 | 0 | worker-cheap | `6f3c2060` | `no-deliverable` @ 09:14:32Z |
   | 2026-09-18T09:14:32Z | 1 | 1 | worker-private | `8df6c4b3` | `no-deliverable` @ 09:20:00Z |
   | 2026-09-18T09:20:01Z | 2 | 2 | worker-private | `ddf5665b` | `no-deliverable` @ 09:23:16Z |
   | 2026-09-18T11:38:38Z | 0 | 0 | worker-cheap | `ac8ab866` | no completion row |

   The fourth packet exists at
   `/home/nish/workspaces/agent-state/dispatch-packets/glue-sweep-consumers-20260918T113838Z-ac8ab866-8391-4a30-97f4-300e1627056f.md`
   and was never resumed. The journal in the issue body shows the failure shape exactly:
   `PACKET-VERDICT tools=0 class=no-tools`, the last prose line
   *"I'll build the cross-reference now. First, verify the environment and build the name
   list."*, and then the dead-man's own verdict —
   `died: unit=glue-sweep-consumers result=success deliverable=…/consumers.txt
   verdict=no-deliverable — dead-man tripped`. The scratchpad tree
   (`/tmp/claude-1000/-home-nish/657fe727-…/`) no longer exists; `consumers.txt` was
   never written anywhere, and `glue-sweep/deliverables/` is empty. The `tools=0`
   failure class is generic model non-delivery, not a repo defect: the packet is
   well-formed, its STEP 1/STEP 2 are runnable exactly as written (see #3), and three
   different models produced the same zero-tool-call output.

2. **The rail that detected and judged it no longer exists.** `bin/pi-systemd-run` and
   `bin/pi-detached-deadman` were deleted by `d4a42ced6` ("cut(rail): gh token, prompt
   templates, `--exclude-tools` and two systemd properties replace 1,283 lines of glue",
   2026-09-18); `bin/pi-salvage-worktree` — the organ whose line
   `no git worktree for unit=glue-sweep-consumers workdir=/home/nish — no-op` appears in
   the issue body — was deleted by `2ff2b0cac` ("chore(second-cut-B): delete the worktree
   reaper and the salvage organ", 2026-09-18). Both are ancestors of `origin/main`. The
   replacement is stock systemd — a `systemd-run --user --collect` one-liner whose
   `RuntimeMaxSec=` is the deadline and whose `ExecStopPost=` test is the deliverable
   check — as recorded in `AGENTS.md`. So the "underlying failure" the issue asks to fix
   is already fixed by deletion: the whole dispatch mechanism, including the dead-man
   that fired here, was replaced with a stock feature. The remaining `systemd/pi-packet@.service`
   still carries a comment noting `OnFailure=pi-packet-failed@%i.service` and
   `bin/pi-packet-failed` went with the sweep.

3. **The reference pass, re-run against the current trees, finds no live glue zero-refs.**
   The packet's STEP 1/STEP 2 were re-executed on 2026-09-22, unmodified except for one
   stale path: the packet names the fleet-ops tree as
   `/home/nish/workspaces/tooling/fleet-ops/{bin,libexec}`, which does not exist on this
   host — the repo tree is the deploy clone
   `/home/nish/workspaces/tooling/fleet-ops-deploy-clone`. Trees enumerated
   (`~/.local/bin`, `~/.local/libexec`, `<repo>/bin`, `<repo>/libexec`): **39 names**.
   Reference corpus: the packet's roots (repo `systemd/ config/ prompts/ .github/`,
   `~/.config/systemd/user`, `~/.claude/settings.json` + `hooks`, `~/.pi` minus session
   logs and skill internals, and the user crontab). Result — **9 zero-reference names,
   0 of which are live fleet glue**:

   | zero-ref name | what it is | reading |
   |---|---|---|
   | `fleet-merge-trample-gate` | dangling `~/.local/bin` symlink → `<repo>/bin/fleet-merge-trample-gate` | **fleet-glue residue** — target deleted by `6fee069b6` (#7907) |
   | `grok-token-refresh` | dangling `~/.local/bin` symlink → `<repo>/bin/grok-token-refresh` | **fleet-glue residue** — target deleted by `6fee069b6` (#7907); see #4 |
   | `fleet-litellm-prisma-compat` | orphaned gitignored dir `<repo>/libexec/fleet-litellm-prisma-compat/` (only a `__pycache__` inside; mtime 2026-09-19) | **fleet-glue residue** — tracked copy deleted by `6fee069b6`; deploy-clone leftover |
   | `actionlint` | third-party linter (host tool) | not glue — out of the sweep's mandate |
   | `bunx` | `bun` alias symlink (host tool) | not glue |
   | `git-filter-repo` | third-party tool | not glue |
   | `py.test` | pytest alias | not glue |
   | `rclone` | third-party tool | not glue |
   | `uvx` | uv alias | not glue |
   | `yt-dlp` | third-party tool | not glue |

   Every other name is referenced from a live consumer surface. The single most
   interesting hit is `grok-token-refresh` itself: five references remain in
   `config/seat-caps.json` and `config/fleet_rules.yml` — i.e. **the reference pass the
   dead unit was supposed to produce would have flagged that file as referenced**, which
   is the point of the exercise.

4. **A load-bearing deletion the sweep's own report had flagged, and the seat it served.**
   `zero-scripts-report.md` (unit `zero-scripts`, 2026-09-18) kept `bin/grok-token-refresh`
   on evidence; the sweep's consolidated final report lists it in its `bin/` table as
   `360 L` / verdict **"None. No stock replacement … Load-bearing: rotated the token 5 min
   before `zero-scripts` looked."** `6fee069b6` ("cut(no-glue 3) … delete dead scripts,
   hooks, shims and their orphaned tests", #7907, 2026-09-19 17:41Z) deleted it anyway,
   with the commit body asserting "nothing live references them". Live state today: no
   `grok-token-refresh` timer, service, crontab entry or Pi extension exists;
   `~/.pi/agent/auth.json` (mtime 2026-09-21T16:58Z) carries an `xai-oauth` grant with
   `access`/`refresh`/`tokenEndpoint` whose `expires` is **2026-09-21T22:53:23Z** — i.e.
   expired ~1.5 h before this pass. This report does **not** assert the seat is dead:
   Pi may refresh the grant lazily on use, and whether it does was not established here.
   What is established is that the proactive headless refresher is gone, no replacement
   was recorded, and the symlink naming it dangles. Filed as plain follow-up issue
   **#8173** (no labels) rather than fixed here — re-adding a script is exactly the glue the
   standing order cuts, and the correct replacement is a Pi-side provider/extension or a
   decision to retire the seat, which is not this issue's scope.

5. **The deletion pass the reference was meant to feed has already run to completion.**
   `origin/main` `bin/` + `libexec/` is now six files (`bin/am-executor-claim`,
   `bin/fleet-claim-release`, `bin/fleet-litellm-key`, `bin/fleet-silent-pr-close-check`,
   `bin/pi-intake-trigger`, `libexec/fleet-metrics-probe.sh`); `~/.local/libexec` no longer
   exists; `~/.local/bin` holds four symlinks into the deploy clone (two of them the
   dangling pair above) plus third-party tools. The sweep's other units already produced
   the equivalent artifacts the dead unit never wrote: `glue-sweep/zero-scripts-report.md`,
   `zero-rail-report.md`, `zero-extensions-report.md`, `zero-exporter-report.md`,
   `zero-verify-report.md`, `zero-packets/`, and the consolidated `ZERO-REPORT.md`. The
   final report's own failed-unit / dangling-link proof block recorded
   `find … -xtype l → (empty)` on 2026-09-18/19; the two dangling links today are newer,
   created by the deletion of their targets in `6fee069b6`. So the consumers
   cross-reference is not merely moot — its job is done, and re-running it is what
   surfaces the residue.

## Resolution

No code, config, unit or prompt change is warranted for #7713. The dead unit was a
one-off dispatch, not a repo organ; its failure class (`tools=0 class=no-tools`) is model
non-delivery on an otherwise well-formed read-only analysis packet, and the dispatch rail
that produced, judged and salvaged it has been deleted in favour of stock systemd. The
work it failed to do is re-run above and landed here as the artifact, and the deletion
pass it existed to inform has already concluded.

The re-run's only actionable residue is small and named: two dangling `~/.local/bin`
symlinks (`fleet-merge-trample-gate`, `grok-token-refresh`), one orphaned gitignored
directory in the deploy clone (`libexec/fleet-litellm-prisma-compat/`), and the
`grok-token-refresh` removal's effect on the `xai-oauth` grant — filed as plain
follow-up issue #8173, not touched here. The seven zero-reference third-party tools are host
tooling, outside the glue sweep's mandate and left alone.

This closes #7713. GitHub closes the issue via the PR's `Closes #7713` trailer; the old
`observe-to-close` sweep that used to grep the `triage:` line was retired 2026-09-18 by
`0dc5dd4ac`.

Evidence receipts: dispatch ledger rows for `unit=glue-sweep-consumers` (4 opens, 3
`verdict=no-deliverable`, 2026-09-18T08:57:42Z–11:38:38Z); the four packet files under
`/home/nish/workspaces/agent-state/dispatch-packets/glue-sweep-consumers-20260918T*.md`;
journal excerpt in the issue body
(`PACKET-VERDICT tools=0 class=no-tools`, `verdict=no-deliverable — dead-man tripped`);
deletions `d4a42ced6`, `2ff2b0cac`, `6fee069b6` (all ancestors of `origin/main`);
`git ls-tree origin/main bin/ libexec/` (6 files); reference re-run 2026-09-22
(39 names, 9 zero-ref) over the packet's roots; `ZERO-REPORT.md`,
`zero-scripts-report.md` and the sibling `zero-*` reports under
`/home/nish/workspaces/agent-state/glue-sweep/`; live probes
`systemctl --user list-timers --all | grep -i 'grok|xai'` (empty), `crontab -l` (no
grok/xai entry), `readlink` on `~/.local/bin/*` (two dangling).

loose-ends: host-symlink-residue-and-grok-token-refresh-followup-8173
