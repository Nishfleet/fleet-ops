# bring devin/cursor provider extensions under fleet-ops management

Part 6/6 of #3125. On 2026-09-04 every heavy packet on the devin seat died at
1801s with rc=1: the provider's `spawnSync` timeout was 1800000ms (30 min),
just past the unit's bound but under the real watchdog. The live timeout was
raised to 2400000ms (40 min, under the 2520s `PI_HANG_TIMEOUT_S`), yet the
extension source lived only in `~/.pi/agent/extensions/` — outside any repo,
able to drift back silently.

This PR makes the value durable:

- `template/extensions/devin-provider/index.ts` and
  `template/extensions/cursor-provider/index.ts` now live in the repo
  (source of truth, byte-identical to the current production files; the
  cursor provider is also at 2400000ms).
- `MANIFEST` maps both to their live `~/.pi/agent/extensions/<provider>/`
  dests, so `fleet-ops-deploy` keeps them converged.
- `install.sh` installs `template/extensions/**` as **file copies**, not
  symlinks. A symlink would resolve the providers' relative import
  `../seat-health.ts` against the repo tree (proven: Bun and Node both
  resolve relative imports against a symlink's real path), where that
  sibling does not live → runtime import failure. A copy keeps resolution
  on the live extensions dir. Same decoupling the `config/seat-caps.json`
  copy gets (fleet-ops#2910).
- `tests/provider-timeout.test.sh` fails loudly if any provider `timeout` is
  `< 0.9 x PI_HANG_TIMEOUT_S` (the 2026-09-04 stall class), if a provider
  leaves MANIFEST, or if the 1800000ms value ever returns.

No new binary, no new scheduler, no new organ — the timeout is pinned by a
test and the source converges via the existing install mechanism.

## Verification

- `bash tests/provider-timeout.test.sh` →
  `ALL OK: both providers managed + timeouts >= 0.9 x PI_HANG_TIMEOUT_S`
  (exit 0); each provider `timeout 2400000ms >= 2268000ms` (0.9 x 2520s), no
  `1800000` regression, both MANIFEST lines present.
- `./install.sh --check` → zero DIFF lines for `devin-provider` /
  `cursor-provider`: both entries converge byte-clean against the live box.
- `bash tests/manifest-shape.test.sh` PASS, `bash tests/fleet-ops-deploy.test.sh`
  PASS, `bash tests/fleet-pi-extensions-canary.test.sh` PASS,
  `bash tests/pi-issue-run-hang-stall-bench.test.sh` PASS, `sgscan` clean.
- `shellcheck install.sh` and `tests/provider-timeout.test.sh` clean.
- Negative probe (numeric): a simulated `1800000ms` timeout is correctly
  below the `2268000ms` bar and is caught.
- `crgate` skipped: CodeRabbit CLI is not signed in on this box (would exit 3
  before scanning); the repo's own audit routes still cover this diff.

architect skipped: depth-1 worker.
Closes #3263
