# Pending: reusable gate-integrity workflow YAML

The nishfleet-worker App has no `workflows` permission, so these files
cannot land under `.github/workflows/` on this PR. A token with that
scope (Nish) should:

1. `git mv docs/pending-gate-integrity/reusable-gate-integrity.yml .github/workflows/`
2. `git mv docs/pending-gate-integrity/gate-integrity.yml .github/workflows/`
3. `git mv docs/pending-gate-integrity/template-gate-integrity.yml template/.github/workflows/gate-integrity.yml`
4. In `.github/workflows/ci.yml` Shellcheck step, add `.github/scripts/gate-integrity.sh` to the `files=(...)` list.
5. In the P14 `verify-command`, add `bash tests/gate-integrity.test.sh` next to `tests/reusable-workflows.test.sh`.
6. Delete this directory.

Callers use `pull_request_target` plus `merge_group`. Fork PRs are refused
inside the reusable workflow. Empty `ratchet-paths` is correct for repos
without a ceiling file; 0509 should pass its design-system ratchet path
as an input in a separate follow-up.
