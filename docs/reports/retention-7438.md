# Local log retention report

Issue #7438. Advisory only. No files deleted, no retention config changed, no service or timer added or enabled.

Run from the issue branch:

```sh
bin/fleet-asset-census retention-report --helper "$PWD/bin/jev-eval.mjs" --output-json /tmp/retention-7438-live.json
FLEET_RETENTION_ENABLED=0 bin/fleet-asset-census retention-report
```

The installed command resolves the shared `jev-eval` helper from PATH. Use `--helper` for a checkout. The site rollback switch is `FLEET_RETENTION_ENABLED=0`; every value other than `1` skips both scanning and evaluation. Existing census/diff commands and logrotate are unchanged. This command is manual, not scheduled.

## Real run

Re-verified 2026-09-17T22:12:54Z by the resuming worker: `retention-report` exited 0, five classes scored, `proposed_drop_gb` 0, `deleted_bytes` 0. Keep probabilities ranged 0.90 to 0.98; the helper appended five non-synthetic rows to `~/.local/state/pi-packet/jev/artefact-retention.jsonl` (15 rows total). Figures below are from the earlier 17:56:16Z run.

Observed 2026-09-17T17:56:16Z on the VPS. Command exited 0. Five SDK calls through the shared helper, 4,248 input tokens, estimated $0.000178416 at the helper's recorded rate. Each call used `--cap-usd 1`, the helper's shared cumulative budget. The earlier 17:53:36Z run also passed; the figures below are the second run only.

| Class | Files | Decimal GB | Value, 0–4 | Keep probability | Proposed drop GB |
| --- | ---: | ---: | ---: | ---: | ---: |
| issue-inputs | 2269 | 0.046865562 | 3.22 | 0.93 | 0 |
| issue-outputs | 2253 | 0.004909897 | 3.01 | 0.90 | 0 |
| issue-errors | 2253 | 0.002907730 | 2.93 | 0.90 | 0 |
| watch-active | 1 | 0.005299565 | 3.69 | 0.98 | 0 |
| watch-rotated | 5 | 0.012575721 | 3.19 | 0.92 | 0 |

Proposed drop list: empty. Proposed savings: **0 GB**. Actual deleted bytes: **0**.

Real records include `/home/nish/.local/state/pi-issues/0509-1051.in`, `.out`, `.err`, `/home/nish/.local/state/pi-packet/watch.log`, and `watch.log.1`. The local report lists every measured path, counts, logical and allocated bytes, modification/access age ranges, limitations, and model responses. The shared helper appended real, non-synthetic JSONL rows under `/home/nish/.local/state/pi-packet/jev/artefact-retention.jsonl`, each with a class path/pattern, observation timestamp, state hash, answers, probabilities, usage and duration.

## Limits and approval

Only the five named local classes are measured. R2, filesystem watchers, other state directories, and nested archives are unmeasured. Byte totals are snapshots of changing logs, not a claim about all host disk usage or guaranteed reclaimable blocks.

Modification age is not creation age. Access times are not reliable proof of a human read under relatime/noatime or scanners. Last-read and per-file consumer references remain unknown. Known class references are `systemd/pi-issue@.service`, `config/logrotate.conf`, and `systemd/pi-packet-logrotate.service`. Unknown does not mean unused.

Scores use five ordered levels from no demonstrated remaining value to current operational need. Proposed action is a separate typed choice, not an invented score cutoff. Both are advisory. Before any future deletion, Nish or the weekly review must confirm the exact current list once. This PR contains no deletion implementation or flip flag, so a score cannot grant deletion authority.

## Regression checks

`python3 tests/asset-retention.test.py`: six tests pass. The command-existence test failed before implementation. Tests cover metadata-only enumeration, symlink exclusion, missing roots, malformed scores, helper budget failure without report overwrite, private output permissions, per-class SDK payloads and rollback without a helper call. Fixtures are invented tests, not live scoring proof.

`bash tests/fleet-asset-census.test.sh`: passes, including the new tests and existing census, guard map, metrics, scalability and heartbeat checks.

`bash tests/jev-eval.test.sh`: passes. `sgscan --base origin/main`: no new findings. Local review remains blocked because the review CLI is not signed in; the PR opens as a draft and is not armed for merge until that review runs.
