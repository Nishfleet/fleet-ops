# Tincan relay approval policy

The play renders the relay's approval gate from `config/tincan-relay/agents.txt` and installs it as nish's `approval.json`, 0600, in the relay's state folder.

## Sub-features

- `policy-render` builds the gate with jq from the roster.
- `policy-install` writes the file only when it passes the shape check.

## How to get to it (user POV)

- Edit `config/tincan-relay/agents.txt` or `config/tincan-relay/policy.jq`, merge, and the deploy installs the new gate.

## Driving it with podman exec

- **Converge.** The Launch command. `converge.log` shows `Install the rendered tincan relay approval policy` as `changed` or `ok`.
- **File state.** `podman exec "$RUN" sh -c 'stat -c "%n %a %U:%G" ~nish/.local/state/tincan-relay ~nish/.local/state/tincan-relay/approval.json'` prints mode 700 for the folder and 600 for the file, both `nish:nish`.
- **Gate shape.** `podman exec "$RUN" sh -c 'jq -e ".gate | length > 0" ~nish/.local/state/tincan-relay/approval.json'` exits 0.
- **Roster match.** `podman exec "$RUN" sh -c 'jq -r ".gate | keys[]" ~nish/.local/state/tincan-relay/approval.json'` lists every name in `agents.txt`.

## Gotchas

- The roster check against the live relay is skipped in a container, because no relay runs there.
