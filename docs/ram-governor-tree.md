# RAM Governor — fleet memory policy tree

Owner: fleet-ops. Authored 2026-08-26 alongside [issue #71][#71] (and proven
by the drill behind [#64][#64]).

[#64]: https://github.com/Nishfleet/fleet-ops/issues/64
[#71]: https://github.com/Nishfleet/fleet-ops/issues/71

## Why this document exists

The fleet's memory policy is NOT a single setting. It is **five layers**
stacked, each catching what the layer below it misses. A worker is killed only
when every layer below fails in order. This file lists them in that order,
names every file they live in, and tells a new operator which key does what.
Read once; treat as canonical.

## The tree

```
   MIN_FREE_RAM_MB=2500            (launch floor — prevent work starting)
   per-worker MemoryHigh/Max       (per cgroup — throttle and bound)
   user@1000.service 50%           (Ubuntu stock — NEUTRALIZED, was the
                                    drill's collateral kill authority)
   user-1000.slice 12G + 80%       (system drop-in — repo-owned, this issue)
   this slice (app-pi\x2dissue.slice) 80% (fleet-only — repo-owned, last resort)
   kernel OOM                      (the absolute last — never the only one)
```

Read bottom-up for the kill chain: a worker dies only when every layer above
fails. Read top-down for the budget chain: memory is rationed from the launch
floor inward.

## Layer-by-layer

### 1. Launch floor — `bin/pi-issue-run` → `MIN_FREE_RAM_MB=2500`

**What it does.** `pi-issue-run` reads `/proc/meminfo`'s `MemAvailable` and
refuses to start a worker if less than ~13.1 GiB is free (1024 × `2500 MB`
residual + working-set headroom). This is the brake that should do **almost
all** the work — work never starts in the first place if the box is already
under pressure.

**Owner:** `bin/pi-issue-run` and `bin/pi-packet-run`.

### 2. Per-worker throttle — `systemd/pi-issue@.service`

**What it does.** Each worker runs with
`MemoryHigh=3G` (throttle-and-reclaim, no kill) and `MemoryMax=6G` (hard
ceiling per worker) plus `RuntimeMaxSec=45min` so a wedge dies on the wall
clock. The throttle layer punishes one worker at a time — it cannot punish
the host.

**Owner:** `systemd/pi-issue@.service`.

### 3. Ubuntu stock policy — `user@1000.service` `ManagedOOMMemoryPressure=kill` at 50%

**What it does.** Ubuntu's `10-oomd-user-service-defaults.conf` ships
oomd-policy-on-by-default at 50% / 30s on `user@.service`. This is the
distro's safety net for the desktop case — it is too aggressive for a
batch fleet.

**2026-08-26 01:24 IST drill collateral:** this stock layer fired and
reaped 5 live fleet workers at 75% memory pressure in `user@1000.service`.
The fleet's deliberate 80% layers never fired because the stock 50%
tripped first.

**Status: NEUTRALIZED.** A drop-in was placed the same minute at
`/etc/systemd/system/user@1000.service.d/50-no-distro-oomd-kill.conf`
that sets `ManagedOOMMemoryPressure=auto`. It is repo-owned by issue #71
(installed via `./install.sh --system` or the manual path in the
README). The two deliberate 80% layers below are the SOLE kill
authority for fleet work.

### 4. user-1000.slice — `MemoryHigh=12G` and `ManagedOOMMemoryPressure=kill` at 80% / 60s

**What it does.** This system-scope drop-in covers everything `nish` runs:
the fleet, every Claude/agent interactive session in `session-*.scope`
(SIBLINGS of `user@1000.service`, which no user-manager slice config can
govern), every browser, every test suite.

`MemoryHigh=12G` is **first** — kernel reclaim, cold pages go out first
to the 8 G swap, active work keeps its hot set. Nobody dies.

`ManagedOOMMemoryPressure=kill / 80%` is **second** — emergency kill of
the worst-pgscan descendant cgroup only when 12 G of reclaim hasn't been
enough to keep pressure below 80% for 60 s straight. Baseline pressure
on this box is 0.00 (`/proc/pressure/memory` `some avg10` with the
fleet running, n=5); 80% sustained is nowhere near normal operation —
it is an emergency, which is the only time this should fire.

**Owner:** `systemd/system/user-1000.slice.d/50-ram-governor.conf`,
installed live at `/etc/systemd/system/user-1000.slice.d/50-ram-governor.conf`.

`DurationSec` is GLOBAL in systemd 255 (per-slice `DurationSec` is not a
valid key, `systemd-analyze verify --man=no` reports "Unknown key name …
ignoring"). The 60 s duration is set in
`/etc/systemd/oomd.conf.d/99-fleet.conf` as
`DefaultMemoryPressureDurationSec=60s`.

### 5. app-pi\x2dissue.slice — `ManagedOOMMemoryPressure=kill` at 80%

**What it does.** This slice is `app-pi\x2dissue.slice` (declared in
`systemd/app-pi\x2dissue.slice`). It is the FINAL fleet-layer kill
authority — same 80% / 60s as layer 4, but scoped to the worker slice
itself. systemd's cgroup hierarchy means layer 4 sees the slice as
ONE descendant; layer 5 sees what's inside it.

**Owner:** `systemd/app-pi\x2dissue.slice`.

**Why two layers at the same threshold?** Belt-and-braces. Layer 4
might be down or disabled for an unrelated reason; layer 5 keeps the
fleet covered even so. Either one firing is enough; both firing means
the box is in genuine trouble and was not caught by layers 1-3.

### 6. Kernel OOM killer (the floor)

**What it does.** Plain `kernel oom_kill` on `Out of memory` in the host
memcg. Reachable when every layer above is missing, bypassed, or has
failed. Reaps arbitrarily; not a policy — a final non-policy.

**Why it is not a layer to rely on.** On a busy box the kernel OOM
chooses by `oom_score`, not by policy. sshd, tailscaled, the fleet
heartbeat and the intake timers all have `ManagedOOM*=auto` set in
their slices/units so oomd won't take them — but if oomd itself is
broken (`systemd/systemd#33486`-style), kernel OOM picks. Surviving it
is a side effect, not a design.

## Status — what is repo-owned

| Layer | Repo path | Live path | Install |
|---|---|---|---|
| 1 — launch floor | `bin/pi-issue-run` | `~/.local/bin/pi-issue-run` | `./install.sh` (default) |
| 2 — per-worker throttle | `systemd/pi-issue@.service` | `~/.config/systemd/user/pi-issue@.service` | `./install.sh` (default) |
| 3 — stock neutralizer | `systemd/system/user@1000.service.d/50-no-distro-oomd-kill.conf` | `/etc/systemd/system/user@1000.service.d/...` | `./install.sh --system` (or manual) |
| 4 — slice governor | `systemd/system/user-1000.slice.d/50-ram-governor.conf` | `/etc/systemd/system/user-1000.slice.d/...` | `./install.sh --system` (or manual) |
| 5 — fleet slice | `systemd/app-pi\x2dissue.slice` | `~/.config/systemd/user/app-pi\x2dissue.slice` | `./install.sh` (default) |

Layers 3 and 4 are NEW in this repo as of issue #71; layers 1, 2 and 5 were
already repo-owned.

## Drill history

| Date (IST) | Slice | Trip | Layer that fired | Outcome |
|---|---|---|---|---|
| 2026-08-26 00:53 | `oomd-drill.slice` | n/a | kernel memcg OOM at 3 GiB anon | Succeeded (proved `MemoryMax`, not oomd) |
| 2026-08-26 01:24 | `oomd-drill.slice` | 75.07% > 50.00% for 60 s | Ubuntu stock `user@1000.service` 50% layer | Reaped 1 drill service + 5 live workers (collateral) — proved oomd still works, exposed drill collateral scope |
| 2026-08-26 01:34 | (n/a) | (deploy) | n/a | `50-no-distro-oomd-kill.conf` placed — stock layer neutralized |

Future drills should use **one of the deliberate 80% layers** to fire; not
the stock 50% (now neutralized) and not the kernel OOM. Soak up RAM until
`/proc/pressure/memory` `some avg10` rises above 80% for 60 s straight on
the target slice. Drill slice is `MemoryHigh=128M / MemoryMax=1G /
MemorySwapMax=0 / RuntimeMaxSec=180` per the existing drill template.

## Measurement mismatch and admission decision — fleet-ops#202 / #489

#193 sized a self-calibrate formula against a 35 MB RSS figure. That number
is process VmRSS (`ps` / `/proc/PID/status`), not cgroup `memory.current`.

Live sample 2026-08-26:

- 12 live `pi-issue@` units
- `memory.current` p95 = 822.6 MB (`p95_bytes=862556160`)
- p95*3 clamps to the 1.5 GB ceiling
- `/proc/pressure/memory` `some avg10` was 1.53, not zero

2026-08-27 rolling sample (`~/.local/state/ram-measurement/ram-metric-compare.json`):

- 14 live `pi-issue@` units
- `memory.current` p95 = 1163.1 MB
- process `VmRSS` p95 = 2.8 MB
- ratio 411.8

fleet-ops#489 decided to keep `memory.current` for admission (not process
VmRSS). fleet-ops#1168 right-sized the live budget from that 1.5 GB p95*3
clamp to the measured typical-worker value 0.6; fleet-ops#1558 then
re-measured under per-repo MemoryMax drop-ins and `config/seat-caps.json`
now holds `ram_gb_per_worker=0.5`. Process VmRSS is much smaller, so using
it would raise lanes but undercount real cgroup cost.

Do not cite the 35 MB figure as cgroup cost.

## Tuning — read first

DO NOT raise `ManagedOOMMemoryPressureLimit` above 80% on this box.
Baseline pressure is 0.00 with the fleet running. 80% sustained for 60 s
is nowhere near normal operation; anything higher means oomd never fires
and we fall through to kernel OOM. Both are bad outcomes.

DO NOT lower it. 60% (systemd's default) fires on normal multi-worker
transients — every Pi prompt with all providers racing would be a kill
event, not an exception.

DO NOT set `ManagedOOMSwap` to anything other than `auto`. Killing on
swap usage reaps useful work — workers idle on API calls have cold pages
that Linux swaps out by design, and that is healthy here.

IF a real pressure event ever causes oomd to kill, the right answer is
to add tiered per-protocol throttles in Pi (NOT to relax oomd).
