# Retired paths and units

A path in `retired`, or a unit in `retired_units` or `retired_user_units` (ansible/host.yml), is gone from the box after a run.

## Sub-features

- `retired-file` removes a listed path.
- `retired-unit` stops and disables a listed unit.

## How to get to it (user POV)

- Delete an installed file from the repo, list its live path in `retired`, and merge. tests/test_removed_install_is_retired.py fails the PR when the list entry is missing.

## Driving it with podman exec

- **Plant.** Before Launch, place the live copy: `podman exec "$RUN" sh -c 'mkdir -p /etc/polkit-1/rules.d && touch /etc/polkit-1/rules.d/50-fleet-runner-restart.rules'`.
- **Converge.** The Launch command. `converge.log` shows `Remove retired host files` as `changed`.
- **Gone.** `podman exec "$RUN" test ! -e /etc/polkit-1/rules.d/50-fleet-runner-restart.rules` exits 0.

## Gotchas

- `Remove retired host files` is in tasks/retired-and-drift.yml, after the tmpfiles task, so in a container it is not reached. See host-play-converge.md.
