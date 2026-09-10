# New Nishfleet repository

Copy `template/.github/workflows/` into a new repo as `.github/workflows/`.

Those callers point at the central reusable workflows in `Nishfleet/fleet-ops`.
Do not copy the steps out of the reusable files. Change behaviour with `inputs`.

After this lands, a `v1` branch on fleet-ops will be the pin that auto-updates.
Until that branch exists, the callers use `@main`.

## What you get

- Batched PR checks (install, test, secret scan) with a job timeout, caching,
  and path gating inside the job so required checks always report.
- Auto-merge arm on every non-draft PR.

Replace the placeholder `verify-command` in `ci.yml` with this repo's real
test and build commands before the first PR.
