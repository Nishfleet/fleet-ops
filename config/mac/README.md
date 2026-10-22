# Mac daily updater

topgrade runs once a day from a launch agent and updates Hermes (stable
channel), the npm globals, grok, herdr and the tincan listeners. Homebrew is
updated by `brew autoupdate`, not here.

Install:

    sed "s#__HOME__#$HOME#g" config/mac/com.nish.topgrade.plist > ~/Library/LaunchAgents/com.nish.topgrade.plist
    cp config/mac/topgrade.toml ~/.config/topgrade.toml
    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.nish.topgrade.plist

Run Hermes's plain `hermes update` once by hand first if its version has no
`--channel` flag.

Run now: `launchctl kickstart gui/$(id -u)/com.nish.topgrade`.

Switch off and delete: `launchctl bootout gui/$(id -u)/com.nish.topgrade`, then
remove the plist and `~/.config/topgrade.toml`.
