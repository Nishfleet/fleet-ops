Wire the #1263 TTL layer into the live `memoryctl context` path so every assembled packet goes through recall.

`memoryctl-recall` (PR #1317) TTL-checks notes when assembling from a notes directory. Live agents never ran that layer: the standing rule still called raw `memoryctl context`, so expired claims reached preambles as if fresh.

## What changed

- `memoryctl-recall context` — new context mode on the existing binary (no new organ): runs `memoryctl context` with the same flags (`--agent/--query/--repo/--scope/--limit/--max-chars/--kb`, `--vault` forwarded) and wires the packet through the same TTL engine.
  - Every packet prints `[recall: N loaded, M UNVERIFIED]` before the first section.
  - Expired section bodies are rewritten `UNVERIFIED: <body>` plus their literal `check-command` — printed, never executed (same contract as directory mode, locked by the existing no-exec drill).
  - Sections whose source path does not resolve to a vault file (KB surfaces/records) pass through untouched and are not counted.
  - `memoryctl` vault-gate failures (stale curator, pending approvals, secrets) propagate with the same exit code and stderr — nothing is swallowed.
- Standing rule (`lib/standing-rules/canonical.md`): live agents now run `/home/nish/.local/bin/memoryctl-recall context --agent {{SURFACE_AGENT}} ...`. Propagation to `~/.claude/CLAUDE.md` / `~/.codex/AGENTS.md` is the existing `standing-rules-render.path` unit (vault symlink → canonical, fires on merge).
- Lock test extended (`tests/memoryctl-ttl-provenance.test.sh`): hermetic stub `memoryctl` prints a canned packet; asserts the receipt, the UNVERIFIED rewrite, the literal check-command, no-execution, KB passthrough, and vault-gate propagation.

## Verification

```
$ bash tests/memoryctl-ttl-provenance.test.sh
OK: ... (directory mode, unchanged) ...
OK: context-mode receipt is [recall: 3 loaded, 2 UNVERIFIED]
OK: context-mode keeps the memoryctl packet header intact
OK: context-mode fresh note keeps the original body
OK: context-mode rewrites expired bodies and prints the check-command
OK: context-mode prints check-commands without executing them
OK: context-mode passes non-vault sections through untouched
OK: context-mode propagates memoryctl vault-gate failures
ALL OK: TTL applied exactly when (now - observed) > ttl; receipt matches
rc=0

$ bash tests/standing-rules-drift.test.sh
ALL OK: 8/8 assertions passed
rc=0

$ bash tests/p14-test-listing-gate.test.sh
OK: p14-test-listing-gate.test.sh: P14 test list is closed
rc=0

$ bash tests/ci-standards-audit.test.sh
ALL PASS; rc=0 (hosts the TTL drill; runs 300+ hosted tests green)

$ python3 bin/memoryctl-recall.py context --agent fleet2-vps --query "fleet heartbeat timers and seats" --repo /home/nish --limit 10
rc=0
# Task Memory Packet
...
Treat these as leads. Re-verify drift-prone facts against the live repo or runtime.

[recall: 10 loaded, 0 UNVERIFIED]

## _system/shared-memory/agent-contract.md
...
```

run-proof: transcript above — live `memoryctl-recall context` against the real vault + real `memoryctl` exits 0 and every packet carries the `[recall: N loaded, M UNVERIFIED]` receipt. (A live vault-gate state on first attempt — curator-health stale, memoryctl exit 2 — was propagated verbatim by the wrapper, then the curator timer was re-armed and the run went green; the recurring timer fault is filed as a new issue.)

sgscan: no new findings. shellcheck on the test: only SC2015 info (the `|| fail` intent is fail-on-any-missing, matching file style). No `.github/workflows/**` touched.

Gate note — `fleet-token-efficiency-check` rule 6 (markdown `{{}}` before 70% mark) REJECTs `lib/standing-rules/canonical.md`. This is pre-existing on main (first `{{SURFACE_PREIMPLEMENT_PHRASE}}` sits at line 48/105 there too): the file is a living template whose tokens must stay inline where the renderer substitutes them (`{{SURFACE_AGENT}}` inside the command string), so "move placeholders to the end" is not satisfiable without breaking the standing-rules templating. This diff adds zero new `{{` placeholders and no new assemblers.

Closes #1320