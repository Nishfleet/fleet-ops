# fleet-ops verification map

This folder is the maintained list of what the box does and how to prove each part.
Read this index, then use the matching feature file as the recipe.

## Baseline preconditions

- A container from `SKILL.md` Launch, with `converge.log` holding a `PLAY RECAP` line.
- `$RUN` and `$EV` set as in Launch.
- Drive only the container this run started.

## Driving conventions

- Run box commands with `podman exec "$RUN" sh -c '<command>'`.
- Treat every command as literal.
- Save each command's output under `$EV/<feature>/`.

## Proof and skip reporting

- Proof is the command, its output and its exit code, plus a second read of the state it changed.
- A step that needs a stand-in from the `STANDINS` block in `SKILL.md` is reported as "stand-in", never as proven.
- Report a stop with the failing task name and its `Origin:` line from the log.

## Feature entry contract

Each file has an H1, one paragraph, and four H2s in this order: `Sub-features`,
`How to get to it (user POV)`, `Driving it with podman exec`, `Gotchas`.

## Features

- [host-play-converge.md](host-play-converge.md): the deploy applies on a fresh box, twice.
- [relay-approval-policy.md](relay-approval-policy.md): the tincan relay gate file is rendered and installed.
- [retired-paths.md](retired-paths.md): a retired path or unit is gone after a run.
- [system-units.md](system-units.md): each installed system unit loads and starts.
- [alert-rules.md](alert-rules.md): Prometheus loads the alert rules and the rule tests pass.
