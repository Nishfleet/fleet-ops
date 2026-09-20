# Observe-close for #6616 — fleet-socket-drill-5855a/b drill-fixture user units

Issue #6616 asked for the teardown of four leftover user units from the
2026-09-13 #5855 acceptance drill — `fleet-socket-drill-5855a.socket` and
`fleet-socket-drill-5855b.socket` plus their two `.service` companions —
all real files under `~/.config/systemd/user/`, with `5855a.socket` still
active and listening on 127.0.0.1:15855 at filing time (2026-09-14).

The teardown looked blocked: the spawn-guard rule
`systemctl_restart_fleet_unit` (fleet-ops#5605) refused
`systemctl --user stop` of any `fleet-*` unit from agent sessions, and the
machinery-authorization hunt kept filing both fixtures as unregistered
machinery (ranks 90/91, `kind=unit`, absent from
`config/machinery-allowlist.json`). The issue offered two fix options —
a dated drill-fixture allowlist in `spawn-guard-core.ts`, or a
non-`fleet-` naming rule plus a one-time teardown from a non-guarded
context.

By the time this claim ran (2026-09-20), every moving part named in the
issue was already gone. No new code is needed; this report is the
resolution record.

## What was found

1. **The fixtures are gone.** All four unit files are absent, no unit
   with either name is loaded, and nothing listens on 127.0.0.1:15855.
   The `~/.config/systemd/user/` directory mtime is
   `2026-09-20 10:45:38 IST` — the last add/remove in that directory
   happened minutes before this run's checks (10:51 IST). No
   `*.wants/` symlink remnants and no broken symlinks remain under the
   directory. The user journal's retention starts 2026-09-19 06:22 and
   holds no `fleet-socket-drill` entries, so the stop/removal itself left
   no journal trail inside the window — the teardown actor is not
   provable from journal evidence, only the end state is.
2. **The blocking guard is gone.** `systemctl_restart_fleet_unit` lived
   in `template/extensions/spawn-guard-core.ts` (521 lines), deleted on
   main by `7c2b2beac` "cut(extensions): delete 2,663 lines of pi
   extensions; stock forks + systemd carry the rest" together with the
   fleet fork of `bash-spawn-hook.ts` and the six spawn-guard tests.
   The live `~/.pi/agent/extensions/` set carries no spawn-guard file,
   and nothing in it references `fleet-*` unit stops. Both fix options
   in the issue presupposed this guard; with it deleted the trap it
   described no longer exists.
3. **The hunt is gone.** `4d7ab9f28` "cut(gates-evaluators): delete 21
   of the 31 process gates; keep the 10 with live callers" deleted
   `bin/fleet-machinery-authorization-gate`,
   `lib/machinery-authorization-gate.py` (952 lines),
   `config/machinery-allowlist.json` (329 lines) and its 355-line test —
   the commit notes new machinery needs Nish's explicit endorsement by
   standing rule instead of an allowlist gate. No timer or unit on this
   host invokes it, and a repo-wide grep for `fleet-socket-drill`
   returns zero hits, so nothing can file the fixtures any more.
   `7c2b2beac` and `4d7ab9f28` are both ancestors of `origin/main`
   (verified with `git merge-base --is-ancestor`).

## Acceptance verification (2026-09-20, netcup-rs2000)

| Acceptance bullet | Result |
|---|---|
| `systemctl --user list-units --all 'fleet-socket-drill*'` empty | `0 loaded units listed.` |
| Four unit files gone from `~/.config/systemd/user/` | Full directory listing has no `fleet-socket-drill-*` entry; `grep -rln "fleet-socket-drill" ~/.config/systemd/ /etc/systemd/` → zero hits; `list-unit-files` → no match |
| `daemon-reload` run | `systemctl --user daemon-reload` exit 0 at ~10:57 IST |
| Hunt produces zero hits for both names | Gate + allowlist + test deleted on main (`4d7ab9f28`); no live timer/unit references it; repo grep for `fleet-socket-drill` → zero hits |

Additional probes: `ss -tln` shows no listener on :15855;
`systemctl --user list-units --all` shows no `machin`/`hunt` units;
no `*drill*` entries under `default.target.wants/` or
`timers.target.wants/`.

## Residual note

The `fleet-`-prefix naming trap the issue described is moot — nothing
blocks `systemctl --user stop fleet-*` today — but future drill
fixtures should still avoid the `fleet-` namespace so they read as
fixtures in listings and stay clear of any future fleet-unit guard.
Filed as a naming preference, not a gate: no machinery remains that
would enforce it.
