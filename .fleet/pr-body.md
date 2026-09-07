## fix(spawn-guard): close gate-bypass on devin/cursor CLI shims

Closes #3126

### Problem

The devin and cursor providers are CLI shims that shell out to a vendor binary
(`devin`, `cursor-agent`) with `--permission-mode dangerous`. That binary runs
its own agent with its own tools, so Pi never sees a bash call from inside the
vendor session and the Pi-side guards (`bash-spawn-hook` -> `spawn-guard-core`,
`protected-paths`, `permission-gate`) are all blind on those seats. Proven
2026-08-25: a stash push RAN on the devin seat with no `SPAWN_BLOCKED` line and
no block-log row. This is the fleet's PRIMARY seat (devin) and the cursor
keystone seat.

### Closure (orchestrator decision 2026-09-07)

Edit the existing provider shims so they refuse dangerous operations in the
prompt BEFORE execing the vendor binary. No new organ, no bpf, no new wrapper
binary, no canary organ.

- `template/extensions/provider-spawn-guard.ts` (new): shared pre-exec guard
  mirroring the `spawn-guard-core` rules — stash, recursive delete under the
  home tree, credential-path writes, systemctl restarts, and the 0509
  wrangler-deploy block. Logs to the same `SPAWN_BLOCK_LOG` and writes
  `SPAWN_BLOCKED` to stderr.
- `template/extensions/devin-provider/index.ts` and
  `template/extensions/cursor-provider/index.ts`: import and call
  `assertPromptSafe(prompt)` before the vendor `spawnSync`.
- `MANIFEST` + `config/pi-extensions-allowlist.json`: ship and prove the new
  module.
- `tests/fleet-spawn-guard-provider-shim.test.sh` (new): pins the rule matrix
  and that both shims wire the guard before the vendor spawnSync. Hosted by
  `spawn-guard.test.sh` and pinned in the P14 reachable set.

### Verification

- `bash tests/spawn-guard.test.sh` — exit 0, all four sub-suites green
  (stash-readonly, sudo-write, provider-shim, no-local-bin-clobber).
- `bash tests/fleet-spawn-guard-provider-shim.test.sh` — exit 0, rule matrix
  blocks stash / recursive delete / credential writes / systemctl restart /
  wrangler deploy; both shims wire `assertPromptSafe(prompt)`.
- `bash tests/p14-test-listing-gate.test.sh` — exit 0, provider-shim test
  pinned in the P14 reachable set.
- `bash tests/provider-timeout.test.sh` — exit 0, both provider shims still
  managed with timeouts >= 0.9 x watchdog.
- `bash tests/manifest-shape.test.sh` — exit 0.
- `bash tests/fleet-pi-extensions-canary.test.sh` — exit 0, allowlist clean.
- `bash bin/sgscan` — exit 0, no new security findings.
- `bash bin/fleet-no-agent-names-check --commit-range origin/main..HEAD` —
  exit 0, no agent attribution.

run-proof: tests/spawn-guard.test.sh, tests/fleet-spawn-guard-provider-shim.test.sh, tests/p14-test-listing-gate.test.sh, tests/provider-timeout.test.sh, tests/manifest-shape.test.sh, tests/fleet-pi-extensions-canary.test.sh, bin/sgscan all exit 0

net-positive-because: the diff adds a shared guard module + one test to close a security-critical gate bypass on the fleet's primary seat; the added lines are the enforcement itself, not control-plane machinery.

research: the orchestrator decision (2026-09-07) names the exact fix — edit the existing provider shims to refuse dangerous operations before execing the vendor binary, and extend the existing spawn-guard tests. No new organ.

help-first: the existing spawn-guard tests (fleet-spawn-guard-stash-readonly, fleet-spawn-guard-sudo-write) and the provider shims' existing structure were read before writing the new module and test; the new test follows the same extract-and-assert pattern as the existing stash-readonly test.

organ-heartbeat: template/extensions/provider-spawn-guard.ts not-an-organ: helper module imported by the provider shims, not a standalone organ.
