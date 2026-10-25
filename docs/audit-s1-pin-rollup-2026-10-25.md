# Audit S1 pin roll-up — 2026-10-25

Receipt for fleet-ops#10165. Audit item S1 asks for every `uses:` pinned by
`pinact`, plus a Dependabot `github-actions` entry with a 3-day cooldown.

- `pinact run --check` exits 0 on `main` in all nine repos. Run 2026-10-25
  12:52 IST with pinact 5.0.1.
- All nine `.github/dependabot.yml` files have a `github-actions` entry with
  `cooldown: default-days: 3`.
- The two pin PRs that were still open are merged, and their merge commits are
  ancestors of their `main`: Nishfleet/inish-site#241 (`e622f5e`) and
  Nishfleet/seo-fix-kit#303 (`713d659`). `compare/main...<sha>` reports
  `ahead_by=0` for each.

The roll-up table with each repo's exit code, IST time and note, and the one
open item outside this roll-up, are on the audit tracker. Per-repo detail is
kept off this public repo.
