# CI standard

The standing rule lives in the vault (`CI standard: batched, minimal, near-zero
failures`). This file is the part that belongs next to the reusable workflows
so a new check is written correctly instead of caught later.

Reusable workflows in this repo are the mechanism. Call them with `uses:`;
pass `inputs`; do not copy or override critical steps.

## Required checks are pure

A required status check must be a function of the PR's own diff.

**Wrong:** `counts[marker] !== ceiling` against a committed JSON file, or any
gate that fails unless the PR runs `--update` on a shared baseline.

That shape is a global lock. Two PRs that are each legal alone collide in the
merge queue over one number. 0509's design-system ratchet (issue #1056 there)
is the textbook case.

**Right:** fail only when a count exceeds its ceiling (`>` / `<=`). Tighten
the ceiling on main after merge — a scheduled or push-triggered job, not the
contributor PR.

Same idea as ESLint `--max-warnings`, Betterer, Sorbet `srb rbi todo`, and
RuboCop `.rubocop_todo.yml`.

Exact equality is still correct for pinning a downloaded binary (sha256 of
shellcheck, gitleaks). That pin is not a shared counter every PR must edit.

## The lint

`.github/scripts/required-check-purity.mjs` flags the wrong shape.

`.github/workflows/ci-required-check-purity.yml` is the reusable caller.
It is **advisory** (warn, do not block) until existing instances are fixed.
Promote with `enforce: true` after 0509#1056 lands.
