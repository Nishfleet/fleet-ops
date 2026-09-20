# Observe-close for #6926 — hand-placed `nish-boundary-notify.service.d/10-rate-limit.conf`

Issue #6926 (fleet-blind-audit, 2026-09-14) flagged a **real file** (not a
symlink into the repo systemd/ tree) at
`~/.config/systemd/user/nish-boundary-notify.service.d/10-rate-limit.conf`
— a hand-placed drop-in that hides from the unit-name-only hunts
(fleet-ops#2924 / #1548). The ask: "Absorb into the repo + MANIFEST, or
delete if superseded."

The orchestrator decision on the issue (2026-09-17) settled the route:
check the drop-in's current contents, provenance and repo ownership
through the gap-closure process; no new machinery, no deletion of a live
override without its normal gates. This record is that check, completed.

## What the drop-in was — content recovered from history, not guessed

The orchestrator decision asked for the drop-in's *current contents*.
The current contents are: nothing — the path is gone (below). The
last-known contents are recoverable from main's history because the
drop-in **was absorbed before it was superseded**:

```
$ git show 5b298fb28:systemd/nish-boundary-notify.service.d/10-rate-limit.conf
# Rate limit fix for nish-boundary-notify.service
# The heartbeat writes ~30 boundary entries to NISH-ESCALATIONS.md in ~2 minutes
# each run, triggering the path unit 30x and hitting the default
# StartLimitBurst=5 / StartLimitIntervalSec=10s.
# Raise the burst to accommodate a full heartbeat burst.
#
# StartLimitBurst and StartLimitIntervalSec are [Unit] options
# (systemd.unit(5)); placing them under [Service] makes systemd 255 reject
# StartLimitIntervalSec with "Unknown key name ... ignoring" and the interval
# silently stays at the 10s default. That caused a real start-limit-hit on
# 2026-09-02 09:54 (service silenced mid-escalation). Moved to [Unit].
[Unit]
StartLimitBurst=50
StartLimitIntervalSec=180
```

Quoted verbatim; the exact blob on main is the citation — `git show
5b298fb28:systemd/nish-boundary-notify.service.d/10-rate-limit.conf`.

## Provenance (every step a merged commit on main, verified ancestors)

1. **Audit (2026-09-14):** the file existed hand-placed (~/.config, real
   file) → this issue.
2. **First absorption attempt:** `c28fa997b` sat on `claim/issue-4547` and
   never landed; the three symlinked drop-ins were dangling and systemd
   silently dropped the config (recorded in the next commit's message).
3. **Absorption landed:** `5b298fb28` "docs+systemd: README/standing-rules
   match reality; land the 3 live drop-ins whose symlinks dangled" put
   `systemd/nish-boundary-notify.service.d/10-rate-limit.conf` on main —
   the repo owned the drop-in from here.
4. **Supersession:** `6fdd20ed1` "cut(escalation): one stock amtool line
   replaces the 1,181-line notify tower" (2026-09-18, dated by
   `gh api repos/…/commits/6fdd20ed1`) deleted the entire tower —
   `bin/nish-boundary-notify`, `bin/money-boundary-raise`, `bin/hermes`,
   the `NISH-ESCALATIONS.md` path unit, the drop-in
   `systemd/nish-boundary-notify.service.d/10-rate-limit.conf`, and the
   six-to-seven tests that pinned them — replacing the job class with one
   stock line: `amtool alert add alertname=NishEscalation severity=nish
   --annotation=summary='<one sentence>'` → alertmanager `severity="nish"`
   route → telegram receiver (`config/alertmanager.yml`).
5. Both commits are ancestors of origin/main (`git merge-base
   --is-ancestor 6fdd20ed1 origin/main` and same for `5b298fb28` — both
   pass, checked 2026-09-20 from origin/main `4f7bca5a3`).

So the audit's two outcomes both already happened in sequence: the
drop-in *was* absorbed (3), then *superseded and deleted* (4) through a
merged, gated commit — not by this PR. No live override was removed by
this closure; there is no live override left to remove.

## Why no new machinery — and why no senior conference

The override was never new machinery (a `StartLimit*` tuning of an
existing unit, not a new capability), and it is already gone. The issue's
senior-conference trigger ("Route to senior conference when the override
is new machinery") therefore does not fire. Re-creating a rate-limit conf
for a unit that no longer exists anywhere would be the one wrong remaining
move; the correct residual action is only to keep the machinery map from
pointing workers at the dead unit.

## Verification (live on netcup-rs2000, 2026-09-20 ~16:1x UTC)

Host state, each probed fresh this closure:

- `ls /home/nish/.config/systemd/user/nish-boundary-notify.service.d/` →
  `No such file or directory`; the drop-in path itself is ENOENT (same
  result for the file probe). The audit's evidence path
  `/home/nish/workspaces/agent-state/fleet-blind-audit/reports/20260914T221231Z/report.md`
  is also gone — the blind-audit organ was retired in the same glue sweep
  (its findings live in filed issues; PR #7976 is the retired-machinery
  observe-close record).
- `XDG_RUNTIME_DIR=/run/user/1000 systemctl --user cat
  nish-boundary-notify.service` → "No files found for
  nish-boundary-notify.service."; `--user status` → "Unit
  nish-boundary-notify.service could not be found."
- `systemctl --user list-unit-files`, `list-units --all`,
  `list-timers --all` | grep -iE 'boundary|hermes' → no matches ×3.
- `find ~/.config/systemd ~/.local/bin -iname '*boundary*' -o -iname
  '*hermes*'` → zero hits.
- **Replacement organ live:** `prometheus-alertmanager.service` active
  (running since 2026-09-13, system unit — intentionally outside the repo
  systemd/ tree); `amtool alert query severity=nish` → reachable
  unauthenticated at 127.0.0.1:9093, zero open nish alerts. The one-line
  escalation contract lives in the `config/alertmanager.yml` comment
  block (line ~23).
- **Repo state:** `git ls-tree -r origin/main --name-only | grep -i
  boundary` → only `docs/reports/nish-boundary-notify-observe-close-6800.md`
  (record, not machinery); `systemd/` at origin/main has 41 entries,
  none boundary-notify; `git grep 10-rate-limit origin/main` → no match
  outside reports and the bench ledger. Nothing in a manifest references
  the unit; `systemd/system/` holds only oomd/tailscaled/slice drop-ins.

## Residual seam repaired in the same PR

`docs/organ-catalog.md` still carried the row

```
| Boundary-notify (Nish-reserved) | nish-boundary-notify | nish-boundary-notify.service | standing rule |
```

— a unit-name-only hunt trap of exactly the class #2924/#1548 target:
the row directed reuse to a unit that no longer exists. This PR re-points
that row at the live mechanism (alertmanager `severity="nish"` route via
the stock amtool line) and adds the deletion note in the catalog's
existing DELETED convention. No other row needs action: the catalog is
the machinery map that absorbed the MANIFEST role after the allowlist
rewrite (`5b298fb28` era), and no manifest row for nish-boundary-notify
survives anywhere on main.

## Disposition

Resolved-by-deletion, matched to the 2026-09-18 escalation cut
(`6fdd20ed1`): the drop-in was absorbed on main (`5b298fb28`) and then
deleted with the unit it tuned, through gates, before this issue closed.
The finding cannot re-occur: the unit, its .d directory, the drop-in, its
symlink and every delivery-path binary are gone from host and repo, and
the replacement organ is live. This record supplies the acceptance
evidence; no detector, script, config or unit change is required.
