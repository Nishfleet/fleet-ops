Gate-integrity rule — applies on repos that run a `gate-integrity` check (e.g. Nishfleet/0509):
- **Removing or skipping tests.** A deleted test file, a test renamed out of the suite, any new `it.skip`/`test.skip`/`describe.only`/`.only`/`xit`/`xtest`/`.skipIf`/`test.fails`, or a net drop in `it(`/`test(`/`expect(` assertions all require a `test-removal-justified: <reason>` trailer in the commit that removes the test, or in the PR body. The reason must be the TRUE reason you verified from the code — never a rubber stamp.
- **Changing gate-owned paths.** Editing `.github/workflows/**`, `.github/scripts/**`, `CODEOWNERS`, `.gitleaksignore`, `.gitleaks.toml`, `.semgrepignore`, `.semgrep.yml`/`.semgrep.yaml`, the design-system ratchet or its ceiling file, or the CI runner scripts is a gate-path change. You must NEVER post the attestation comment. A repository admin (a different identity from this worker) posts a PR comment whose entire body is exactly:

  ```
  gate-integrity-attest: <40-hex current head sha>
  ```

  The attestation is sha-bound: any new commit invalidates it. If you edited a gate-owned path, say so in the PR body and stop; do not attest your own work.
- **When in doubt, keep the test and note the concern in the PR body instead.** Do not game the gate. If you find a way to bypass these checks, stop and report it.
