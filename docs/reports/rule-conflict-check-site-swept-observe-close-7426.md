# Observe-close for #7426 — the vault standing-rule write path was deleted in the sweep; no organ remains to shadow

Issue #7426 (filed 2026-09-17, Jev epic #7370 "further uses" sibling, 1.5/0.9)
asked for a Jev rule-conflict check before any vault standing-rule write: feed
the new rule text plus the existing rules digest to Jev, get back
`contradicts` (bool, which section) and `duplicates` (bool), print the result to
the writing agent and log it, advisory-only and never blocking. Its site was
named as "the vault write path used by agents (memoryctl capture / agent-drop)
and the global-standing-rules.md edit convention". Its termination was "a real
rule write shows the jev conflict line in the log".

By the time this re-claim ran (2026-09-22 IST), the site itself no longer
exists. The two pieces of machinery named in the site were deleted in the
2026-09-18 glue sweep; this report is the resolution record, same convention as
the #7399 observe-close (PR #8108) and the #7403 observe-close (PR #8111).

## What was found

1. **The named writer is deleted.** `efaa7fa57` ("cut(memory-vault): delete the
   memoryctl loop, the vault linters and their units", 2026-09-18 18:02 IST)
   removed `bin/memoryctl-recall.py` (403 lines),
   `bin/memory-ledger-supersede.py` (312), `bin/memory-index-autocompact`
   (214), `lib/vault-conflict-resolver.py` (148) and
   `lib/shared-memory/ttl-policy.md`, with their units and six tests. The
   deletion message records the write path "has not run since 2026-08-10
   (~/.local/state/nish-memory/memoryctl.lock, 39d), though every session
   preamble mandated it". `git merge-base --is-ancestor efaa7fa57 origin/main`
   passes at origin/main `ee10d8ec8`.
2. **The rule renderer/copier is deleted too.** `f8b567588`
   ("cut(rule-enforcement): delete the rule matrix, the rule renderers and the
   timer registry", 2026-09-18 17:44 IST) removed
   `bin/render-standing-rules.py` (353), `bin/render-pi-agents-md.py` (156),
   `config/rule-enforcement.json` (913), `lib/rule-enforcement.py` and
   `systemd/standing-rules-render.{path,service}`. Its message: "the vault
   global-standing-rules.md remains the wording authority, so what is gone is
   the copier, not a rule." The rendered template `docs/standing-rules.md`
   itself was then deleted by `1ae2704cc` (glue sweep #7828, 2026-09-21),
   which is also on origin/main.
3. **Nothing in the repo or on the host writes rules any more.** On
   origin/main `bin/` holds five files (`am-executor-claim`,
   `fleet-claim-release`, `fleet-litellm-key`, `fleet-silent-pr-close-check`,
   `pi-intake-trigger`) and `lib/` does not exist. `git grep` over origin/main
   for `memoryctl`, `render-standing`, `vault-conflict`, `agent-drop` and
   `rule-enforcement`, excluding `docs/reports/` and bench fixtures, hits only
   historical prose in `docs/` and one `config/seat-caps.json` comment. A grep
   over `systemd/` finds no vault/memoryctl/render writer — the only match is a
   comment in `systemd/service.d/20-resume.conf` quoting the standing rules.
   `XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-unit-files` has no
   vault, memory, curator or render unit (only `fleet-gardener`).
4. **The write path is dead on the host, not just absent from the repo.**
   Live check 2026-09-22 ~02:35 IST: `which memoryctl` → exit 1 (absent);
   `/home/nish/.local/bin/memoryctl` → No such file or directory;
   `~/.local/state/nish-memory/memoryctl.lock` mtime 2026-08-10 14:43;
   `/home/nish/workspaces/tooling/memory-compound` (the external repo that
   owned `cmd_capture`, the blocker this issue recorded) no longer exists.
   The vault's `_system/shared-memory/global-standing-rules.md` is still edited
   — mtime 2026-09-21 21:32 — but by a human/agent editing the markdown file
   directly; no tracked organ performs or inspects that write. The vault's
   `agent-drop` inboxes still receive captures (newest 2026-09-21) as plain
   file drops; the curator that placed them went out with `efaa7fa57`
   (`nish-memory-curator.service/.timer` deleted out-of-repo).
5. **The shared-helper constraint is moot.** `bin/jev-eval` — whose absence
   was the other original blocker — was deleted in `47e2421a0` (2026-09-19),
   which registered Jev as the LiteLLM pass-through
   `POST 127.0.0.1:4000/jev` (proxy-owned cap and spend log; live
   unauthenticated POST returns 401). "Reuse the sibling helper, never a second
   client" maps cleanly onto the pass-through, but there is no call site left
   to attach it to.
6. **No benchmark measured this site.** `docs/jev-benchmark-2026-09.md` scores
   epic children 1–9 only, and none passed. Rule-conflict is a "further uses"
   sibling, not a child, so no `contradicts`/`duplicates` question, digest
   shape, or threshold was ever replayed. Inventing thresholds now is exactly
   the unmeasured wiring the epic forbids.
7. **A replacement would be the glue the sweep removed.** Nish 2026-09-19
   (three times, tracked as #7828, merged as #8076) directs that no new
   hand-built script, hook or wrapper be added anywhere. A rule-conflict check
   with no surviving organ to extend would be a new script by construction.

## Reconciled against the packet

- *New rule text + the existing rules digest → `contradicts` (bool, which
  section) + `duplicates` (bool)*: impossible — no vault write path and no
  rules digest reader survive; the matrix and renderers are deleted.
- *Advisory: printed to the writing agent and logged; never blocks*:
  impossible — no writer to print to and no call site to log from. The
  `/jev` pass-through and the `~/.local/state/pi-packet/jev/<site>.jsonl`
  convention both exist, but nothing emits a rule-conflict row.
- *Termination: a real rule write shows the jev conflict line in the log*:
  impossible — no organ performs or observes a rule write; the only rule
  surface is a hand-edited markdown file.

## Residual path

If the fleet wants a Jev rule-conflict check it is a NEW organ — Nish's
explicit yes is required before one is built (no-glue rule) — and it would
first need its own task-specific benchmark over real rule edits. Nothing here
claims that check is wanted; the newest authoritative act on the site is its
deletion.

mechanism: the sweep itself resolved the issue's target — observe-close
record per the fleet's deleted-organ convention (fleet-ops#7399 → #8108,
fleet-ops#7403 → #8111).
