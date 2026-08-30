## Summary
- #1485 reported `tests/pi-issue-start-packet-regen.test.sh` as unregistered in `.github/workflows/ci.yml`, making `tests/ci-standards-audit.test.sh` exit 1 on a clean main checkout.
- Already fixed on main: PR #2097 (commit 7df0183, merged 2026-08-29) recreated ci.yml and registered the test at line 208. On main HEAD 8c71d67 the test passes and the audit is green for this specific complaint.
- #2097 did not reference #1485, so neither GitHub auto-close nor the `fleet-merged-pr-close` observe-to-close helper (which matches a merged PR referencing the issue by `#<N>`) fires — the issue re-claimed every heartbeat tick (5+ claim/release rounds on 2026-08-30). This PR carries `Closes #1485` so the merge closes the loop and breaks the re-claim cycle.
- Paper only: adds `verification-1485.md` recording the already-fixed verdict with live repro evidence. No machinery, no code, no tests added or removed.

## Separate finding (out of scope, filed)
While verifying on main HEAD 8c71d67, `tests/ci-standards-audit.test.sh` still exits 1 — but on a DIFFERENT unregistered test, `tests/memory-index-autocompact-migrated.test.sh`, added by #2167 (commit 8c71d67) without ci.yml registration. Same bug class as #1485 (worker/App PR cannot push to `.github/workflows/**`). Filed as #2172. Not fixed here.

## Verification
- `git rev-parse HEAD` (main) -> `8c71d674448007d26be0a0dde0b9e5d881ce3638`
- `grep -n "pi-issue-start-packet-regen" .github/workflows/ci.yml` -> `208:        bash tests/pi-issue-start-packet-regen.test.sh`
- `git blame -L 208,208 origin/main -- .github/workflows/ci.yml` -> `^7df0183 (Nish 2026-08-29 ... 208) bash tests/pi-issue-start-packet-regen.test.sh`
- `bash tests/pi-issue-start-packet-regen.test.sh` -> `all pi-issue-start-packet-regen cases passed`, exit 0
- `bash tests/p14-test-listing-gate.test.sh` -> exit 1, failing ONLY on `memory-index-autocompact-migrated.test.sh` (the #2172 pre-existing condition, not this PR's scope); the #1485-named test is accounted for.

run-proof: `bash tests/pi-issue-start-packet-regen.test.sh` -> "all pi-issue-start-packet-regen cases passed" (exit 0) on main HEAD 8c71d67 and on this PR HEAD 0a256d2.

Closes #1485
