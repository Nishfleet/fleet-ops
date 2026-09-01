## Why

The rulebook-redteam audit (fleet-ops#2577) found the Pi example-extension count
contradicting itself across rule bodies: the vault's `global-standing-rules.md`
said 74 at one heading and 79 at two others, and the rendered surfaces
(`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`) inherited the stale 74 from
`lib/standing-rules/canonical.md` — the true generation source (the vault's
`global-standing-rules.canonical.md` is a symlink to it). A bare number with no
anchor drifted between sections; every "use Pi extensions before writing
orchestration" prompt answered differently depending on the heading.

The vault rule file and both rendered surfaces already carry the consolidated
"79 (verified 2026-09-01: `ls ... | wc -l`)" text on disk. This PR makes the repo
canonical match so a future render cannot revert them, and locks the pin with a
drift-test guard.

## What changed

- `lib/standing-rules/canonical.md` — the `shared-fleet-routing` section now pins
  **79** example extensions with the dated, runnable check command
  (`ls ~/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/ | wc -l`),
  byte-identical to what is already rendered in CLAUDE.md / codex AGENTS.md.
  Live count verified 2026-09-01: 79.
- `tests/standing-rules-drift.test.sh` — assertion 9, the prevention mechanism for
  this finding class: (9a) every "shipped example extensions" line in the canonical
  must carry the dated `| wc -l` check command — a hand-added bare count fails the
  suite; (9b) when the Pi install is present, the pinned number must equal the live
  `ls | wc -l` count — a wrong number fails the suite. Skips the reality leg
  gracefully in CI where no Pi install exists.

## Verification

```
$ python3 bin/render-standing-rules.py --canonical lib/standing-rules/canonical.md --check
OK (checked): 2 target(s), 6 section(s)        # exit 0

$ bash tests/standing-rules-drift.test.sh
... OK 9a / OK 9b (pinned 79 == live 79) ...
ALL OK: 9/9 assertions passed                  # exit 0
```

run-proof: `tests/standing-rules-drift.test.sh` 9/9 green (drift, render, templating, markers, orphans, pi-count pin); generator `--check` against live `~/.claude/CLAUDE.md` + `~/.codex/AGENTS.md` exit 0.

Guard-fires receipts (proved by running the suite against a sandboxed stale
canonical; both legs fail):

```
# stale bare 74, no check command:
FAIL: Pi count line must carry the dated check command (fleet-ops#2577)
# pinned 78 with check command present:
FAIL: canonical pins 78 Pi example extensions but the live count is 79
```

Closes #2577