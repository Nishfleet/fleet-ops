---
name: verify-fleet
description: "Run one real fleet unit and collect proof: invocation id, journal, artifact, exit status, CPU time, and memory peak. Use when a change touches systemd/, prompts/, or config/, or when a report names a unit, timer, or template."
---

# Verify fleet

The fleet CLI is stock. Use `systemctl --user`, `systemd-run --user`, `journalctl --user`, and `gh`. Do not add a script, and do not print a token, a key file, or `fleet-gh-token.env`.

Read `fleet-map.md` in this directory before deciding what a unit does. One row is one unit, timer, path, slice, or template. A drop-in belongs to its unit.

## When

A pull request that touches `systemd/`, `prompts/`, or `config/` includes a `## Verification` section with one real run of this skill. Pick the unit that changed, or the unit that reads the prompt or config that changed. Templates take the instance from the issue (`pi-scout@0509`).

## Run

1. Start the real unit: `systemctl --user start <unit>`, or `systemd-run --user` when the map says the job is a transient probe. System-manager units (`tailscaled.service`, `user@1000.service`, `user-1000.slice`) use `systemctl` without `--user`.
2. Wait until the unit is inactive or failed: `systemctl --user show <unit> -p ActiveState -p SubState --value`.

## Proof

Record every item:

- Invocation id: `systemctl --user show <unit> -p InvocationID --value`
- Journal for that id: `journalctl --user _SYSTEMD_INVOCATION_ID=<id> --no-pager -o short-iso`
- The artifact the map says this unit must leave (pull request, comment, label, or file path, with a timestamp). Quote the URL or path. Do not `cat` a token file; a non-empty check is `test -s <path>` and nothing else.
- Exit: `systemctl --user show <unit> -p ExecMainStatus -p Result --value`. When the journal for this invocation says `Failed with result`, that line is the result of the run even if a later `reset-failed` cleared `Result`.
- CPU and memory: `systemctl --user show <unit> -p CPUUsageNSec -p MemoryPeak --value`

## Failure proof

When the map says the unit must fail on a bad outcome, show that failure. `pi-scout@` with no `supply: ready_count=` line exits through its abort gate: the journal contains `scout-abort-gate:` and systemd records `result 'exit-code'`. A `Result=success` on a case the map says must fail means the verification failed.

## Healthy

Healthy is the map's healthy column for that unit. A quiet journal is not enough.
