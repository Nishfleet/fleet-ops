# New Nishfleet repository

Copy `template/.github/workflows/` into a new repo as `.github/workflows/`
and `template/.fleet/gate-integrity.yml` to `.fleet/gate-integrity.yml`.

Those callers point at the central reusable workflows in `Nishfleet/fleet-ops`
at `@v1`. Do not copy the steps out of the reusable files. Change behaviour with
`inputs`.

`v1` is the compatible pin. It moves only for compatible changes. A breaking
change gets a `v2` branch and a new pin.

## What you get

- Batched PR checks (install, test, secret scan) with a job timeout, caching,
  and path gating inside the job so required checks always report.
- Auto-merge arm on every non-draft PR.
- Gate integrity (CI-gaming detector) with per-repo globs in `.fleet/gate-integrity.yml`.

Replace the placeholder `verify-command` in `ci.yml` with this repo's real
test and build commands before the first PR.
