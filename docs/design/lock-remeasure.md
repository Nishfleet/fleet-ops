# Design: the Hermes lock re-measure (fleet-lock-remeasure)

Status: shipped in this PR. Issue: #10269 (follow-up to #9981).

## Why

`InaccessiblePaths=` is enforced by overmounts made when the unit starts, so it
hides what is on the list at that moment and nothing created later. A new
credential file in an open directory, or a tool that writes its login to a path
the list does not name, is readable from the first turn. The table tests only
prove the conf and `config/agent-locks.json` agree with each other.

## What it is

A stock systemd oneshot and timer, the same shape as `fleet-gh-login-check` and
`fleet-clone-lag`, with `OnFailure=fleet-unit-failed@%N.service` as the page. It
runs on this host as the service user, because only the host holds the `$HOME`
and the gateway's `/proc`; CI cannot see either. The ExecStart is inline (no
`scripts/` file) and CI runs that same line against a fake home and `/proc`
(`tests/test_lock_remeasure.py`).

1. Walk `~/.*`, `~/.config/*`, `~/.config/tincan/*`, `~/.local/share/*`. Each
   entry must be in the gateway's `must_hide` or `needs`, or in the new
   `reviewed_open` map in the contract (path -> reason).
2. For every process in the gateway's cgroup, no open fd and no `environ` or
   `Environment=` value may name a `must_hide` path. A process tree this user
   cannot read, or a missing cgroup, fails: an unmeasured read set is not a pass.

## Alternatives

- A CI check: the runner cannot read this host's `$HOME` or `/proc`.
- Generating `InaccessiblePaths=` from the walk: that changes the lock, which
  #10269 excludes, and could hide a path a child needs.
- A Python file under `scripts/`: banned; inline ExecStart plus a test is the
  repo's own pattern.

## Off switch

`systemctl --user disable --now fleet-lock-remeasure.timer`, remove
`fleet-sync.service` step 2n and its enable line, delete the two unit files and
`reviewed_open`.
