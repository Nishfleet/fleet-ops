## Why

Nish's 2026-09-04 decision (fleet-ops#3125): measured 3-day sessions->PR
yield (minimax/MiniMax-M3 90%, xai-oauth/grok-4.6 86%, devin/glm-5-2 70%,
openrouter 65%, opencode/nemotron 19%, commandcode/poolside 2%, opencode/mimo
0%) showed the 2026-08-27 volume-first order put the worst lanes first.
Product work now routes by the rolling PR-yield ledger. This PR closes the
umbrella's last open child, #3258. The sibling children already merged:
#3259/#3260/#3261/#3262 were folded here or into #3250 (the ledger,
merged as #3306) and #3263 (extension management) merged as #3304.

## Scope

`config/seat-caps.json`:
- `_comment_volume_order` and `volume_providers_in_order` retired;
  `product_order: "yield"` added.
- xai-oauth provider cap 1->2, grok-4.6 model cap 0->2 (86% yield, prepaid,
  expiry-first); grok-4.5 stays 0 (accepted assumption). The stale
  _grok_402_note is rewritten as history.
- devin: hard_ceiling removed, max_probe_ceiling 8 (provider),
  glm-5-2 `{cap:3, max_probe_ceiling:6}`, swe-1-7 `{cap:4, max_probe_ceiling:8}`,
  dated reason (weekly quota 97% unused 2026-09-04).

`lib/seat-lib.sh`:
- `SEAT_PRODUCT_ORDER` loaded from seat-caps; model-granularity AIMD
  (`SEAT_MODEL_PROBE_CEILING`, `effective_model_cap`, `_model_probe_admitted`,
  learned state under "provider/model" keys).
- pick_seat: `PI_PICK_ROLE=product` + product_order=yield ranks all candidate
  seats by the #3250 ledger (`load_seat_yield`/`seat_yield_for`) descending,
  ties by class prepaid->metered->free, provisional/absent seats at 0.5, and
  logs the yield order once per pick. Volume bucket removed; scout/canary/
  audit picks keep the free-first ladder, keystone unchanged.
- Model-cap read loop switched to \x1f separators so an empty per-model
  `class` no longer shifts `max_probe_ceiling` out of place (the pre-merge
  loader silently dropped model probe ceilings).

`bin/pi-issue-run`, `bin/pi-packet-run`: export `PI_PICK_ROLE=product`.

`install.sh`: a deploy that changes seat-caps.json archives
learned-caps.json (stale learned state cannot pin a raised declared floor).

Retired (deletion-first): `bin/fleet-volume-lane-order-canary` +
`tests/fleet-volume-lane-order-canary.test.sh`, their MANIFEST line,
heartbeat-tier1 block 33 wiring, the rule-enforcement drill hook, and the
led-2026-08-27-worker-lane-order matrix row (now advisory RETIRED); the
cursor $400 matrix rows re-point to product_order/keystone_only_providers.

`lib/fleet-token-efficiency-check.py`: scoped away from `extensions/`
provider plugins (maxTokens is pi model-registry metadata, not a
prompt-assembler output cap) — #3304's template/extensions sources need
this too.

Tests: new `tests/seat-lib-yield-order.test.sh` (product yield routing,
class tie-break, provisional fallback, scout free-first, log line) hosted by
tests/seat-lib.test.sh; `tests/seat-lib-aimd.test.sh` extended for
model-level AIMD; fleet-token-economy / token-economy-routing updated to the
yield economy; scenario 4b in fleet-token-efficiency.test.sh pins the
extensions scope.

## Tradeoffs

- The yield ledger exists and is live (#3306 merged): pick_seat reads
  seat-yield.json via the landed load_seat_yield; a missing/unparseable file
  fails open to 0.5 for every seat (class order, prepaid first among equal
  performers), so the router cannot break picks.
- grok-4.5 stays cap 0 (accepted assumption) — provider cap 2 is occupied by
  the 86%-yield grok-4.6.
- One PR closes the umbrella's last remaining child #3258.

## Blast Radius

- pick_seat ordering changes only PI_PICK_ROLE=product callers (pi-issue-run,
  pi-packet-run). Scouts/canaries/audits/keystone keep their exact prior
  order, exercised by the updated drills.
- Deleted canary: its observe-to-open xai-oauth detector is moot (xai-oauth
  is wired cap 2); no open issue carries a `volume-lane-order-canary:`
  marker needing drain.
- Pre-existing, filed separately: live timers fable-fleet-check.timer and
  fleet-landing-watch.timer exist on the box but not in
  systemd/timer-manifest.json (tests/timer-manifest.test.sh LIVE CHECK is
  VPS-only; CI shape lock is green).

## Verification

- `bash tests/seat-lib-yield-order.test.sh` — 6/6 OK (product picks highest
  yield at 0.90; equal yields break to prepaid; tried seats excluded;
  scout stays free-first; yield-order log once per pick).
- `bash tests/seat-lib-aimd.test.sh` — all invariants pass incl. model-level
  AIMD (glm-5-2 probes 4->5 below ceiling 6; swe-1-7 without ceiling stays
  at declared; ollama hard_ceiling unchanged).
- `bash tests/fleet-token-economy.test.sh` + `bash tests/token-economy-routing.test.sh` —
  green under the yield economy.
- `timeout 550 bash tests/seat-lib.test.sh` (host suite, ~30 drills incl.
  the new yield-order drill) — exit 0, ALL OK.
- `bash tests/rule-enforcement.test.sh` — committed matrix valid (128 rules);
  the worker-lane-order row RETIRED-advisory passes committed-matrix and
  live-join gates. LOCAL failures are only the pre-existing live-timer drift
  (fable-fleet-check / fleet-landing-watch not in timer-manifest.json),
  VPS-only, filed as a separate issue.
- `SEAT_CAPS_JSON=$PWD/config/seat-caps.json bash bin/fleet-free-roster-canary`
  (rc=0, gates clean) and `bin/fleet-prepaid-util-canary` (rc=0,
  PREPAID-UTIL-OK; xai-oauth cap=2).
- shellcheck: no new findings on lib/seat-lib.sh, bin/pi-issue-run,
  bin/pi-packet-run, install.sh, bin/fleet-heartbeat-tier1, or the touched
  tests (pre-existing SC2034/SC2046 warnings unchanged).
- `bash tests/fleet-token-efficiency.test.sh` — all scenarios pass incl. the
  new extensions-scope scenario 4b.
- install.sh learned-caps reset exercised in a sandbox (cap-map change =>
  .bak archive; idempotent rerun => no reset).
- sgscan: no new security findings.