The seam-since logic in `bin/fleet-blind-audit` used `grep ... | head -1` under `set -o pipefail`. When the grep matches multiple lines, `head` exits after the first and the upstream grep receives SIGPIPE; the 141 exit code then propagates through the pipeline. This caused `tests/fleet-blind-audit.test.sh` scenario 4 to fail with exit 141.

Replace the two `| head -1` pipes with `grep -m1`, which stops at the first match without generating a signal. Keep `|| true` for the no-match case.

Prevention: `tests/fleet-blind-audit.test.sh` now greps `bin/fleet-blind-audit` for `| head -N` pipes and fails the test if any survive.

Verification:
```text
$ bash tests/fleet-blind-audit.test.sh
...
OK: no head -N truncation pipes in fleet-blind-audit
OK: fleet-blind-audit.test.sh
Exit code: 0
```

Closes #838
