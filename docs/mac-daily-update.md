## Mac daily update

`mac/` is the Mac counterpart of [Daily update](daily-update.md), owned by Nish.
A launchd agent runs `topgrade` once a day at 04:30 local time, at low priority
and with no prompts, and reads the config installed with it. Homebrew formulae
and casks are left to `brew autoupdate`, so the steps the job does run are the
`disable` and `commands` lists in `mac/topgrade.toml`. Neither file carries an
absolute home path: launchd does not expand `~`, so the plist names only system
paths, and `~` appears only in the custom commands, which topgrade runs through
a shell. `tests/test_mac_topgrade.py` pins the schedule, the arguments, the
steps and that rule; it reads the repo copy, so the diffs under "Check" below
are what tie the Mac to it.

It keeps the label the hand-written job used, so step 4's bootout is what
removes that job.

- Install it, or push a change to it:
  1. `mkdir -p ~/.config ~/Library/LaunchAgents`
  2. `install -m 0644 mac/topgrade.toml ~/.config/topgrade.toml`
  3. `install -m 0644 mac/com.nish.topgrade.plist ~/Library/LaunchAgents/com.nish.topgrade.plist`
  4. `launchctl bootout gui/$(id -u)/com.nish.topgrade 2>/dev/null` then
     `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.nish.topgrade.plist`
     (bootout first: launchd reads a plist once, on load)
- Check the Mac still runs the repo copy:
  `diff mac/topgrade.toml ~/.config/topgrade.toml` and
  `diff mac/com.nish.topgrade.plist ~/Library/LaunchAgents/com.nish.topgrade.plist`
  both print nothing. `brew autoupdate status` shows the separate Homebrew job
  is loaded, which is what covers formulae and casks.
- Run it now: `launchctl kickstart -p gui/$(id -u)/com.nish.topgrade` prints the
  pid and exits 0, and `launchctl print gui/$(id -u)/com.nish.topgrade` shows the
  loaded job. The plist names no log file, because a log path is a home path, so
  look for the run in the system log:
  `log show --last 1d --predicate 'process == "topgrade"'`.
- Switch it off: `launchctl bootout gui/$(id -u)/com.nish.topgrade` stops it and
  leaves it unloaded until the next install.
- Delete it: `launchctl bootout gui/$(id -u)/com.nish.topgrade`, then
  `rm ~/Library/LaunchAgents/com.nish.topgrade.plist ~/.config/topgrade.toml`.

