## What changed

fleet-ops#1283: two comments still described `ram_gb_per_worker` as the old
#489 1.5 GB clamp after #1168 right-sized it to 0.6. Both are now rewritten
as history so they cannot fight the cap map again:

- `config/seat-caps.json` `_comment_ram_governor` — already rewritten (by
  #1558-era commits) as the 0.5 <- 0.6 story with measurement markers; no
  stale 1.5/formula text remains. Verified live, no change needed.
- `docs/ram-governor-tree.md` — the measurement section was already
  rewritten as history, but still ended with the present-tense claim
  `config/seat-caps.json sets ram_gb_per_worker=0.6`. The live cap map
  holds 0.5 (fleet-ops#1558). This PR turns that tail into history: #1168
  set 0.6, #1558 re-measured under per-repo MemoryMax drop-ins, and the cap
  map now holds 0.5. The doc can no longer fight the cap map.

Test fixtures in `tests/fleet-vibes-canary.test.sh` keep the legacy "1.5"
comment text deliberately — they exercise the anti-vibe gate with a
legacy-style citation and are out of scope per #1283 ("test comments only").

## Verification

- `bash tests/ram-metric-compare.test.sh` — exit 0, ALL OK (scenario 4 locks the
  live cap-map value 0.5)
- `bash tests/fleet-vibes-canary.test.sh` — exit 0, all OK; production seat-caps
  gate and detectors clean
- `bash tests/system-dropins-shape.test.sh` — exit 0, all OK
- live cap map: `jq -r .ram_gb_per_worker config/seat-caps.json` -> 0.5
- stale-claim scan across *.md/*.json/*.sh/*.py: no `clamped ceiling`,
  `min(memory.current p95 * 3)`, or `ram_gb_per_worker=1.5` matches outside
  the deliberate test fixtures
- `sgscan` on the diff: exit 0, no new security findings

Closes #1283