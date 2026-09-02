# fleet-unjustified-wait must accept corpse as a dead-class terminal (fleet-ops#2724)

Two readers still filter on the pre-#2327 `health_class` taxonomy. The
metrics-export side (`_read_dead_credentials`) was already fixed by
fleet-ops#2667: it now matches the `credentials_bad` signal in EITHER
`health_class` OR `failure_mode`, and `tests/fleet-metrics-export.test.sh`
already carries corpse fixtures (terminal corpse shape copied verbatim from
the live ledger, plus the non-credential corpse that must stay OUT). This PR
is the matching fix on the unjustified-wait side, which was still blind to
the corpse class.

## Why

`bin/fleet-unjustified-wait`'s dead-class audit accepted only
`credentials_bad` as a valid dead state. The seat-health extension rewrites
a seat past the corpse threshold to the TERMINAL `health_class="corpse"`
(fleet-ops#2327/#2415) for ANY failure mode and clears `usable_at` — a
corpse is RETIRED, with the `seat_dead=true` marker as its only named clock.
Every corpse therefore tripped a false-positive UNJUSTIFIED-WAIT every tick,
and heartbeat tier 1 returned `unjustified_rc=1` forever on the live
evidence shape: `commandcode/minimax-m3-free` carrying
`seat_dead=true, health_class=corpse, failure_mode=credentials_bad,
http_status=403`.

## Scope

- `bin/fleet-unjustified-wait`:
  - dead-class case now accepts `credentials_bad|corpse` (was
    `credentials_bad` only); the dead-marker-missing guard messages the
    live `health_class` instead of hardcoding `credentials_bad`.
  - cross-cutting seat_dead-with-non-dead-class check accepts both
    `credentials_bad` and `corpse`; header docstring adds the corpse class
    alongside `credentials_bad`.
- `tests/fleet-unjustified-wait.test.sh`: scenarios 5b/5c/5d lock the fix
  forward — corpse+dead=true+credentials_bad exits 0
  (the live-evidence regression), corpse+dead=true+transient_http exits 0
  (the corpse class covers non-credential failure modes; the filter must
  not over-key on `failure_mode`), corpse+dead=false exits 1
  (a corpse without the dead marker is still an inconsistent write).

## Tradeoffs

No change to the metrics-export reader: fleet-ops#2667's
`credentials_bad in (health_class, failure_mode)` match already surfaces the
corpse row and is more precise than a plain class-set match (it excludes a
transient_http corpse from the credential alert). Re-keying it again here
would duplicate shipped work.

## Blast Radius

Only the seat ledger audit in `bin/fleet-unjustified-wait` changes class
acceptance. Healthy/transient/quota_bench/quota_exhausted/rate_limited
paths are untouched; the seat_dead=true inconsistent-write guard is
narrowed (now accepts corpse) but still flags any OTHER non-dead class, so
genuinely inconsistent records stay loud. Consumers: heartbeat tier 1
(`unjustified_rc`) and the FleetDeadCredentialSeats alert path. With the fix
missing, every corpse seat pinned heartbeat tier 1 red forever — the
continuing false-positive cost ends with this PR.

## Verification

Reproduced on the unfixed main with the live evidence shape (scratch
ledger, no network — the bin audits local state only):

```
$ FLEET_SEAT_LEDGER_DIR=<scratch>/seats ... bin/fleet-unjustified-wait <scratch>
[UNJUSTIFIED-WAIT] seat corpse seat_dead=true with health_class=corpse — dead marker without credentials_bad (clock inconsistent)
[UNJUSTIFIED-WAIT-FAIL] unjustified waits=1 — TOP GEAR invariant violated
rc=1   # FALSE POSITIVE on the pre-fix filter
```

After the fix, same scratch run:

```
$ ... bin/fleet-unjustified-wait <scratch>
[UNJUSTIFIED-WAIT-OK] every wait carries a named clock — TOP GEAR invariant holds
rc=0
```

Guard directions verified live: corpse+dead=false still exits 1 with
`dead marker missing (clock=repair gate)`; corpse+dead=true
(transient_http) exits 0.

Offline suites:

```
$ bash tests/fleet-unjustified-wait.test.sh
OK: clean ledger exits 0 with UNJUSTIFIED-WAIT-OK
OK: corpse seat_dead=true (credentials_bad failure_mode) is clean
OK: corpse seat_dead=true (transient_http failure_mode) is clean
OK: corpse seat_dead=false is flagged as missing dead marker
OK: fleet-unjustified-wait: clock audit, timer gates, loud fail, auto-file dedupe, repair, observe-to-close
exit 0 (23 OK)

$ bash tests/fleet-metrics-export.test.sh
OK: ... corpse fixtures still green (50 OK, exit 0)
```

run-proof: transcript above — pre-fix repro exits 1 with the false-positive
LOUD, post-fix same input exits 0 with UNJUSTIFIED-WAIT-OK and the corpse
regression scenarios 5b/5c/5d fail on the old bin and pass on the new.

Closes #2724