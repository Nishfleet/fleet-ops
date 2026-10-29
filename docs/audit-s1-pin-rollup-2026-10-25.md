# Audit S1 pin roll-up — 2026-10-25

Receipt for fleet-ops#10165. Audit item S1 asks for every `uses:` pinned by
`pinact`, plus a Dependabot `github-actions` entry with a 3-day cooldown.

- `pinact run --check` exits 0 on `main` in all nine repos. Run 2026-10-25
  12:52 IST with pinact 5.0.1, one fresh checkout per repo at `origin/main`.
- All nine `.github/dependabot.yml` files have a `github-actions` entry with
  `cooldown: default-days: 3`, read on the same checkouts.
- The two pin PRs that were still open are merged, and each merge commit is an
  ancestor of its `main`. Verified with
  `gh api repos/Nishfleet/<repo>/compare/main...<sha>` reporting `ahead_by=0`:
  Nishfleet/inish-site#241 (`e622f5e5d8a626d18d66f0c9013df4f44728c4b0`) and
  Nishfleet/seo-fix-kit#303 (`713d65969bf2cbf463c7385551ced7205405f6e1`).

The per-repo roll-up table, with each repo's exit code, IST time and note, and
the one open item outside this roll-up, are on the audit tracker's S1 row
(private). Per-repo detail is kept off this public repo.
