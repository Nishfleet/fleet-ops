# grade.yml adoption in four repos (fleet-ops#8797)

Four repos now call the shared grader `Nishfleet/fleet-ops/.github/workflows/grade.yml@main` (fleet-ops#8655). The retired caller `opus-review.yml@main` 404s; fleet-ops#8797 repointed them. All six PRs below merged 2026-09-27.

## The four adoption PRs

| repo | PR | merge commit | change |
|---|---|---|---|
| Nishfleet/TinyStudio.io-public | [#32](https://github.com/Nishfleet/TinyStudio.io-public/pull/32) | `66845dbe85a742083ccbde64919f3e51ecdf5325` | `.github/workflows/opus-review.yml`: `uses:` line only |
| Nishfleet/siterep-public | [#126](https://github.com/Nishfleet/siterep-public/pull/126) | `68f4414103f9721748ab8ccce68f7e1fcda4e640` | `.github/workflows/opus-review.yml`: `uses:` line only |
| Nishfleet/0509-support-inbox | [#27](https://github.com/Nishfleet/0509-support-inbox/pull/27) | `7a2243b3544d847dfbbd21cd7561b55a06ecb5ee` | new `.github/workflows/grade.yml` caller |
| Nishfleet/0509-telemetry | [#12](https://github.com/Nishfleet/0509-telemetry/pull/12) | `db8745f46bd7514f6c981f6b9e3dcb9195379cbd` | new `.github/workflows/grade.yml` caller |

## Acceptance (fleet-ops#8797)

Run 2026-09-27 against each repo's `main`:

```
$ gh api repos/Nishfleet/TinyStudio.io-public/contents/.github/workflows/opus-review.yml --jq .content | base64 -d | grep -q 'workflows/grade.yml@main' && gh api repos/Nishfleet/siterep-public/contents/.github/workflows/opus-review.yml --jq .content | base64 -d | grep -q 'workflows/grade.yml@main' && gh api repos/Nishfleet/0509-support-inbox/contents/.github/workflows/grade.yml --jq .content | base64 -d | grep -q 'workflows/grade.yml@main' && gh api repos/Nishfleet/0509-telemetry/contents/.github/workflows/grade.yml --jq .content | base64 -d | grep -q 'workflows/grade.yml@main' && echo ok
ok
```

## Grade follow-ups

The two public repos' adoption PRs were graded B by Opus (bar 8/9): their header comments still named the retired grader (`fleet-ops#8621`) and the old check name (`opus-review / opus-review`; calling `grade.yml` makes GitHub report `opus-review / grade`). Both PRs merged with the grade check red — the check is not a required check in those repos (fleet-ops#8756 owns making it one). Comment-only fixes, both merged 2026-09-27: [#33](https://github.com/Nishfleet/TinyStudio.io-public/pull/33) (TinyStudio.io-public), [#127](https://github.com/Nishfleet/siterep-public/pull/127) (siterep-public).

The private repos' grade jobs posted no comment before their PRs merged; per fleet-ops#8797 the required check there waits on Nish's GitHub Team call (rulesets 403).

encoded: structure - one shared reusable grader; adoption is a per-repo caller change, and the grade check only gates a repo when its ruleset requires it
