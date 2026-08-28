Fix sgscan wrapper: --help crash, unknown-flag pass-through, stderr capture.

## What changed

sgscan, the semgrep wrapper used in the worker review gate (sgscan → crgate → repo tests → PR), had three failure modes:

1. `sgscan --help` crashed with `JSONDecodeError` — the flag was passed through to semgrep, which returned text, not JSON.
2. Unknown flags (e.g. `--diff`) were passed through to semgrep, which failed with exit 2 and empty output.
3. When semgrep returned non-JSON output or failed, the wrapper provided no diagnostic.

## Fix

- **--help / -h handler**: prints usage and exits 0 (before the arg-parsing catch-all).
- **Unknown-flag rejection**: any `--*` or `-*` not in the known set now exits 7 (`unknown flag: <name>`) instead of passing through to semgrep.
- **Robust semgrep failure handling**: semgrep non-zero exit or empty output maps to exit 3. Stderr is captured to a temp file and shown on failure.
- **Invalid JSON handling**: JSON parse errors map to exit 3 with descriptive message, not a raw traceback.
- **Always pass `--baseline-commit`** when a base ref is available, even when HEAD equals merge-base (semgrep handles this fine).
- **Added to MANIFEST** so the tool is version-controlled and installed by `install.sh`.
- **Regression test suite**: 7 cases in `tests/sgscan.test.sh` covering --help, unknown flags, no-diff clean, ERROR/WARNING findings, semgrep fatal, and invalid JSON.
- **Test harness fix**: the fake semgrep's `${VAR:-default}` with nested `}` in the default was misparsed by bash — switched to explicit if/else.

Exit codes updated: 3 = semgrep itself failed, 7 = unknown flag (added).

## Verification

```
$ bash tests/sgscan.test.sh
OK: --help exits 0 and prints usage
OK: unknown flag exits 7 without JSONDecodeError
OK: no-diff repo exits 0 and passes --baseline-commit
OK: ERROR finding exits 2
OK: WARNING --json exits 1 and emits valid JSON
OK: semgrep fatal exit 2 maps to wrapper exit 3
OK: invalid semgrep JSON maps to wrapper exit 3
ALL PASS
```

```
$ sgscan --help
sgscan — security scan of what YOU changed.
...
exit: 0
```

```
$ sgscan --diff origin/main...origin/main
unknown flag: --diff
exit: 7
```

Live sgscan on the PR diff itself:
```
$ sgscan
Scanning changes since origin/HEAD (c69ceada)…
No new security findings.
exit: 0
```

## research

sgscan was already a hand-written wrapper (not available as a standard tool). The fix extends it, not builds a new tool. No alternative was considered — the existing wrapper needed repair. `semgrep --help` was consulted to understand its exit codes and output format.

## help-first

`semgrep --help` confirms it has no `--diff` flag and that unknown flags exit 2 with text on stderr. The sgscan wrapper now guards against this before semgrep runs.

Closes #796

research: official docs (semgrep --help) — compared with no off-the-shelf sgscan alternative; the existing hand-written wrapper was already the simplest approach and just needed repair. No alternative adopted or rejected.
help-first: ran --help on semgrep (the underlying tool) — confirmed unknown flags exit 2 with text on stderr; the wrapper needs to guard that path because semgrep alone does not validate unknown flags before emitting non-JSON output.