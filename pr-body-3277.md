A pi reinstall dropped `~/.pi/agent/extensions/subagent` silently. This PR makes install.sh own that tree again, and makes `pi-transport-check --subagent` fail loud when the load handshake is gone.

## Why

Delegation died after a pi reinstall because the stock subagent files were hand-placed npm symlinks, not MANIFEST dests. The live probe only checked cli.js, so workers started without noticing.

## Scope

- `install.sh` understands `npm-pin:<rel>` and restores stock `agents.ts` plus workflow prompts as symlinks to the installed pi examples dir.
- `template/extensions/subagent/index.ts` is a fleet wrapper: prints `EXTLOAD-OK extension=subagent` then re-exports the stock default. It does not copy the stock tool.
- `template/agents/{planner,reviewer,scout,worker}.md` are the unpinned agent defs (no `model:` frontmatter).
- `bin/pi-transport-check` is the existing live probe, now in git, with `--subagent` for the handshake. Default invocation stays cli.js-only.
- `bin/pi-issue-run` calls `--subagent` at worker start, with capability-detect so a pre-deploy probe is not treated as a cli.js path.

Out of scope: manager loop, stall rule, `phases:` deletion, TasksMax, heavy memory class (sibling issues).

## Tradeoffs

`--subagent` is a separate flag, not part of the default probe. Putting it on the default path would make self-heal run `npm rebuild` and would make seat-lib charge TRANSPORT when only the extension was missing.

architect skipped: depth-1 worker

## Blast Radius

`install.sh`, the pi-issue worker start path, and the transport probe. Self-heal and `_transport_is_down` keep calling the probe with no flag, so a missing subagent is not a clobbered bin. MANIFEST installs the wrapper before the new probe and `pi-issue-run` so a mid-deploy worker does not assert against the old stock symlink.

Safe because: default `pi-transport-check` stays cli.js-only. Proved by `tests/subagent-extload.test.sh` (missing dests, default probe still prints `PI-TRANSPORT-OK`).

## Verification

```
cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-3277
bash tests/subagent-extload.test.sh
```

Output:

```
OK: MANIFEST declares subagent wrapper, npm-pin symlinks, agent defs, probe
OK: MANIFEST install order: wrapper then probe then pi-issue-run
OK: wrapper is EXTLOAD handshake + stock re-export
OK: agent defs exist and are unpinned
OK: default probe is cli.js-only (missing subagent is not transport-down)
OK: --subagent fails loud when handshake dests are missing
OK: --subagent prints EXTLOAD-OK when handshake dests are present
OK: --subagent rejects a pinned agent def
OK: install.sh copies wrapper, npm-pins stock symlinks, links agent defs
OK: install.sh --check reports a dropped subagent symlink
OK: pi-issue-run asserts subagent EXTLOAD at worker start
ALL OK: subagent extension is MANIFEST-owned and EXTLOAD-asserted
```

```
./bin/pi-transport-check
```

Output: `PI-TRANSPORT-OK size=710 version=0.84.4`

```
sgscan --base origin/main
```

Output: `No new security findings.`

The p14-test-listing-gate test failed with exit 1 on two pre-existing unhosted files (`pi-intake-tick-difficulty-from-issue.test.sh`, `scout-effectiveness-multirepo.test.sh`). Filed #3482 and #3483. This PR's test is hosted from `tests/ci-standards-audit.test.sh`.

the crgate call reported CodeRabbit is not signed in on this machine; no CodeRabbit review ran.

run-proof: `bash tests/subagent-extload.test.sh` exit 0; `./bin/pi-transport-check` -> `PI-TRANSPORT-OK size=710 version=0.84.4`

research: official docs (Pi examples/extensions/subagent/README.md) and live search of the installed probe. Compared fleet-pi-extensions-canary (absence of a proven id is not a fail, so it cannot assert EXTLOAD at worker start) and putting the check only in pi-transport-self-heal (workers call the probe bin, not the systemd wrapper). Adopted: repo-ize the existing probe and add `--subagent`.

help-first: ran `/home/nish/.local/bin/pi-transport-check --help`; the live probe has no `--help` and treats the flag as a cli.js path (`PI-TRANSPORT-CORRUPT: --help missing or not a regular file`). Default run is `PI-TRANSPORT-OK size=710 version=0.84.4` and does not assert subagent EXTLOAD.

organ-heartbeat: bin/pi-transport-check not-an-organ: repo-izes the existing cli.js probe; no new timer, exporter, or heartbeat metric

loose-ends-canary: worktree:/home/nish/workspaces/agent-worktrees/issue-fleet-ops-3277 stale-worktree

Closes #3277
