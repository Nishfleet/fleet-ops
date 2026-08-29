# staleness-checker fixtures

## global-standing-rules-excerpt.md

Verbatim excerpt of
`~/workspaces/tooling/nish-vault/_system/shared-memory/global-standing-rules.md`
as of 2026-08-29, copied word-for-word from the source document (lines ~1568-1660).

Used by `tests/staleness-checker.test.sh` Test 8 (fleet-ops#1674) to pin the
real-world input that produced a false-positive staleness issue: the source
doc cites `systemd/systemd#33486`, which an earlier version of the checker
mis-parsed as `Nishfleet/fleet-ops#33486`. The test asserts the extractor
filters that upstream ref out.

The excerpt is vendored in-repo rather than read from the live vault path
because CI runners have `$HOME=/home/runner` and the vault path
`$HOME/workspaces/tooling/nish-vault/...` does not exist there. The previous
test (PR #2023) read the live path directly, passed on the VPS, and broke
main CI the moment it merged untested against main (fleet-ops#1919).

The regression intent is preserved: the test still loads the ACTUAL real-world
text that caused the false positive — including `systemd/systemd#33486` and a
mix of fleet-ops issue refs — not a hand-picked synthetic string. A future
refactor that weakens the owner/repo filter fails against this real text.

When the source document changes, refresh this excerpt from the live vault and
re-verify Test 8 still passes. Do not paraphrase the excerpt; its value depends
on it being the real input.
