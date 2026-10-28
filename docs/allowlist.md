## Allowlist

There is no manifest and no installer. A path is live because something
symlinks to it from `~/.config/systemd/user/`, `~/.local/bin/`, or
`~/.pi/agent/prompts/`. EnvironmentFile= targets (e.g. `hc.env`, `deploy.env`,
`cf.env`) are never tracked — only the units that reference them.

