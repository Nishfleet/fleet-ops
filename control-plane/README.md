# control-plane

Workflow `run:` blocks over 50 lines, moved here as TypeScript with unit tests (fleet-ops#10456).
One job per PR; the YAML copy is deleted in the same PR.

| Job | Entry point |
|-----|-------------|
| `agent-dispatch.yml` `list` (the sweep) | `src/sweep.ts` |

Node 24 runs the `.ts` files directly (type stripping), so there is no build step. Keep to
erasable syntax: no enums, namespaces or constructor parameter properties.

Tests: `npm ci && npm test`. CI runs them in the `ci` job, through
`tests/test_control_plane_sweep.py`. The suite replays `config/sweep-rework-cases.json` and
`config/sweep-liveness-events.json` against the code, and runs the whole sweep against a fake `gh`.

Switch off: delete this directory and restore the `list` job's `run:` block from git history.
