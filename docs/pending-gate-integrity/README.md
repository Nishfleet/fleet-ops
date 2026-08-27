# Pending: reusable gate-integrity workflow YAML

The nishfleet-worker App has no `workflows` permission, so these files
cannot land under `.github/workflows/` on this PR. A token with that
scope (Nish) should:

1. `git mv docs/pending-gate-integrity/reusable-gate-integrity.yml .github/workflows/`
2. `git mv docs/pending-gate-integrity/gate-integrity.yml .github/workflows/`
3. ~~`git mv docs/pending-gate-integrity/template-gate-integrity.yml template/.github/workflows/gate-integrity.yml`~~ Done on claim/issue-303 / fleet-ops#498 (template path is not a GitHub workflow; the worker App can push it).
4. In `.github/workflows/ci.yml` Shellcheck step, add `.github/scripts/gate-integrity.sh` to the `files=(...)` list.
5. In the P14 `verify-command`, add `bash tests/gate-integrity.test.sh` and `bash tests/gate-integrity-config.test.sh`.
6. Delete this directory.

Callers use `pull_request_target` plus `merge_group`. Fork PRs are refused
inside the reusable workflow. Empty `ratchet-paths` is correct for repos
without a ceiling file; 0509 should pass its design-system ratchet path
as an input in a separate follow-up.

## Attestation contract (fleet-ops#828)

A comment attests when ANY of its lines (CR-stripped, whitespace-trimmed)
equals `{marker}: {40-hex}` — not when the comment's entire body equals
that string. The previous whole-body exact match dropped every multi-line
attest comment (the real-world shape, where the marker line is followed
by `verifier-attest:` and review prose) and blocked every 0509 merge for
hours (repro: 0509#1273). The reusable now ships raw `comments` and the
decision script's `extract_attestations_from_comments` runs the
line-anchored scan. A prose sentence that merely mentions the marker
still does NOT attest: the line must be the marker and nothing else.

Inline workflow callers (e.g. 0509's own `.github/workflows/gate-integrity.yml`,
which pre-dates the reusable) have the same bug and need a matching fix
in their own repo; that is not the fleet-ops scope of this issue.
