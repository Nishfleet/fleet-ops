## Red main issues

The hourly sweep (the `red-main` job in `agent-dispatch.yml`, on the caller's `GITHUB_TOKEN`) keeps exactly one open `agent-ready` issue per workflow file in an enrolled repo whose latest finished run on the default branch failed (CI included; disabled, dynamic and agent-dispatch workflows are skipped, and so are runs from forks). The issue body starts with the line `red-main: <workflow file>` and names the failing run, its first failing step and the last green sha. A `GITHUB_TOKEN` label fires no event, so the next sweep's `agent-ready` listing starts the worker.

- A new failing run adds a comment (marker `red-main-run: <run id>`), at most one a day.
- A green latest run closes the issue with a link to that run, unless a worker holds it (`agent-in-progress`); the next green sweep closes it after.
- An issue closed after a failing run is not filed again for that run.
- An issue is filed for a workflow at most once a day, and at most three new issues a day per repo, so a workflow that flips between red and green cannot start a worker every hour.
- Builders do not file their own issue for a red main: they use this one (fleet-ops#9308).

The sweep polls the latest run instead of reacting to `workflow_run`: that trigger takes literal workflow names in each caller stub (no wildcard), so a new or renamed workflow would be missed in every repo, and a missed event would leave an issue open after main turned green. The sweep reads the state itself, so it also closes.

**Switch it off:** set the repo variable `RED_MAIN` to `off` on the calling repo. **Delete it:** remove the `red-main` job, `tests/test_red_main_sweep.py`, its name in the `gated` list and test step of `ci.yml`, and this section. `Nishfleet/fleet-ops` is not swept.

