# Plan — seat-caps: deploy the EFFECTIVE table, and make retirement expressible (fleet-ops#4960)

> Manager mode (heavy). One mechanism, two faults. `install.sh --check` reds forever because
> `seat-caps.json` is MERGE-installed (`seat_caps_merge_unknown_providers`, install.sh:338,
> fleet-ops#4205) but checked with a raw `cmp -s` (install.sh:889-893). And the same merge
> copies a live-only provider row back, so deleting a row from `config/seat-caps.json` (PR #4950,
> straitly, "402 credit exhausted, seat retired") is indistinguishable from "the repo never
> declared it" — the retired seat is resurrected at cap 2 on every deploy and stays pickable.
> Fix = compare the effective table in `--check`, and give the repo a dated tombstone the merge
> honors. No new organ: `install.sh` + `config/seat-caps.json` + `tests/fleet-ops-deploy.test.sh`.

## Phases (acceptance-driven)

- [x] phase 1 (acceptance 5 + 2 data half): prior-art check before inventing a field —
  `git log --oneline -20 -- install.sh` and `grep -rn 'intentional_cap_zero\|max_probe_ceiling' install.sh lib/seat-lib.sh`.
  Record the verdict in the PR body. Then add the tombstone to `config/seat-caps.json` itself
  (one top-level `retired_providers` map, `{ "<provider>": { "retired": "<ISO date>", "reason": "<why>" } }`),
  seeded with `straitly`, and drop the now-redundant `_comment_straitly_wipe` prose key (net ~0 lines).
  In-file, not a second list: install.sh already copies this one file atomically, so a separate
  tombstone file could land out of order (live keeps the row, repo loses the marker = resurrection again).
  DONE `b4c8beda`: `retired_providers.straitly{retired:2026-09-10, reason}`; `_comment_straitly_wipe` removed; `jq -S` whole-file diff vs origin/main shows those two changes and nothing else. Prior-art verdict: `intentional_cap_zero` classifies a PRESENT row and `reason` is that row's dated field, so neither can express "the row is gone"; install.sh has 0 references to either. Tombstone reuses the sanctioned `retired: <ISO date> + reason` shape, one new top-level key, no second convention.
- [x] phase 2 (acceptance 2): `install.sh` honors the tombstone — in `seat_caps_merge_unknown_providers`
  (install.sh:338) skip a live-only row whose provider name is in the repo's `retired_providers`
  (repo-declared rows still always win, so a stale tombstone can never delete a repo declaration);
  and in `seat_caps_would_downgrade` (install.sh:265) skip tombstoned names so an intentional
  retirement is not reported as the fleet-ops#371 cap downgrade the guard exists to stop.
  Also trim the phase-1 `reason` string to the shape-met one-liner (deletion-first: the extra history
  belongs in the PR body, not the data file) — reviewer Consider.
  DONE `c9b04923`: the merge skips a live-only tombstoned row (repo rows still win; unparseable fallback unchanged); `load()` in the downgrade guard returns the whole doc and the guard skips tombstoned names. Reviewer verified old==new behaviour byte-for-byte for a repo with no tombstone, and the teeth check (remove the tombstone -> the live straitly row comes back).
- [ ] phase 3 (acceptance 1): `install.sh --check` compares the EFFECTIVE table for
  `config/seat-caps.json` — build the effective file with the same `seat_caps_merge_unknown_providers`
  normalization and compare it against the live copy with `content_equivalent` (install.sh:194,
  fleet-ops#4894), instead of `cmp -s`. Must still DIFF when (a) a repo-declared provider's live cap
  differs, (b) the live file is unparseable, (c) the live file is a symlink pointing anywhere other
  than the repo copy. No extra helper and no second serializer: the merge already emits the
  `json.dump(indent=2, ensure_ascii=False)` shape `content_equivalent` compares.
  Also land the phase-2 reviewer's one-line hardening in `seat_caps_would_downgrade`: the skip becomes
  `if name in retired and name not in repo: continue`, so a stale tombstone plus a repo-declared row
  still reports the real drop (aligns the guard with the merge rule that a tombstone only ever
  suppresses a LIVE-ONLY row).
- [ ] phase 4 (acceptance 4 + 3): regression tests in `tests/fleet-ops-deploy.test.sh`, appended
  after scenario 12h — (a) a hand-wired provider row present only in the live copy, repo otherwise
  identical -> `--check` exits 0; (b) a provider tombstoned in the repo -> after install the live
  copy has no such row AND an untombstoned live-only row still survives; (c) a repo-declared
  provider whose live cap differs -> `--check` still exits 1 and prints the DIFF. Plus the
  unparseable-live and symlink-elsewhere DIFF probes, and a fourth assertion the reviewer asked for:
  a tombstoned live-only row must NOT trip `seat_caps_would_downgrade` (`NONFATAL REFUSE ... would
  lower live seat caps` must be absent from install output, and install must exit 0 on a repo whose
  seat-caps.json is NOT origin/main's blob — the guard-skip path). Then run the suite green.
- [ ] phase 5 (ship): commit, push `claim/issue-4960`, PR `Closes #4960` with
  Verification / run-proof / research / help-first / loose-ends sections, arm auto-merge.

## Phase review record (manager, per-phase reviewer)
- Phase 2 review (stock reviewer): **0 Act-on, NOT BLOCKING.** Verified by execution: no-tombstone parity byte-identical old vs new (merge still adds live-only rows; guard still fires `name:cap->missing` and `name:cap->lower`); a stale tombstone never deletes a repo declaration; the unparseable fallback is `cmp`-identical over 4 malformed fixtures; all three `load()` validity checks survive on both sides; `bash -n` + `shellcheck -S warning` clean; `fleet-ops-deploy` (ok=81) and `fleet-token-economy` both rc 0; teeth proven (tombstone removed -> live straitly comes back at cap 2). CONSIDER (recorded): (1) the guard skip was unconditional, so a stale tombstone plus a repo row blinded it — FOLDED INTO PHASE 3 as a one-liner (`and name not in repo`); (2) no automated test covers the tombstone path yet — phase 4; (3) a list-valued `retired_providers` degrades to `set()` and fails open, matching the merge's existing fail-open posture on unparseable input — NOTED, not changed. NOTED: the merged live copy carries `retired_providers` through; every consumer reads `.providers` only.
- Phase 2 NOTE for phase 4: pre-existing, out of scope — the #371 guard's `->missing` branch flags ANY live-only row as a cap drop, so on a non-origin/main install path (issue worktree, hot-patch retarget) the guard refuses on `opencode-go` even though the #4205 merge deliberately preserves it. Unchanged by this PR (same line before and after); the normal deploy path short-circuits via `seat_caps_is_origin_main_blob`, proven end-to-end rc=0 with the real config. FILE A FOLLOW-UP ISSUE at phase 5; phase 4's guard-skip scenario must therefore use a live copy whose only live-only row is the tombstoned one.
- Phase 1 review (stock reviewer): **0 Act-on, NOT BLOCKING.** Verified live: `jq -e` valid, 2-space style, trailing newline, `jq -S` whole-file diff vs origin/main shows only the tombstone + the removed comment key; no seat-caps reader breaks (every reader is key-scoped; `bin/fleet-vibes-canary`'s only top-level iterator filters to `_comment*`/`_note`/`_hard_cap`); `tests/fleet-vibes-canary.test.sh` and `tests/seat-caps-citation.test.sh` both exit 0. CONSIDER (recorded, folded into phase 2/4 as above): tombstone is inert until phase 2; trim the over-long `reason`; assert the tombstone does not trip the #371 downgrade guard; place the data key after the prose block; record the acceptance-5 verdict in the PR body at phase 5. NOTED: the shape is the one acceptance 2 authorizes; a repo-declared `providers.straitly` row must keep winning or the config text becomes a lie.

## Files to Modify
- `config/seat-caps.json` — add top-level `retired_providers` (straitly, dated + reason); delete the redundant `_comment_straitly_wipe` key.
- `install.sh` — `seat_caps_merge_unknown_providers` (~:338) honors the tombstone; `seat_caps_would_downgrade` (~:265) skips tombstoned names; `process_entry`'s `--check` branch (~:889) compares the effective table for seat-caps.
- `tests/fleet-ops-deploy.test.sh` — the three regression scenarios + header greps.

## New Files (none)
- None. No new timer, unit, checker, exporter, canary or workflow. `bin/fleet-ops-drift.py` untouched.

## Risks
- Symlink check must stay FIRST in the `--check` seat-caps branch: normalizing/merging before it would make a hijacked symlink compare clean (acceptance 1(c)).
- Unparseable live must stay red: the merge's unparseable fallback emits the repo copy, which cannot byte-equal an unparseable live file, so `content_equivalent` still returns false. Assert it.
- Tombstone must never outrank the repo: a name in BOTH `.providers` and `retired_providers` keeps the repo row. If inverted, a stale tombstone silently deletes a live declaration and scenario (c) loses its teeth.
- While the tombstone is in the repo but not yet deployed, `--check` is legitimately red (pending retirement) — one tick of expected red, not a second mechanism.
- Deliberate trade-off: `--check` now goes green for live-only hand-wired rows. That is the false red being removed; do NOT add a canary for it (acceptance 3).
