## Agent autonomy drop-in

`rootfs/etc/claude-code/managed-settings.d/50-agent-autonomy.json` is a Claude
Code managed-settings drop-in; Claude Code merges every
`/etc/claude-code/managed-settings.d/*.json` into the managed settings. It does
four things:

- Tells the auto-mode safety checker which orgs and repos are ours.
- Allows auto-merge (`gh pr merge --auto`) of an agent's own green PR in the
  repos whose rulesets require checks. Not `--admin`, not approving, not any
  other repo.
- Allows cleanup of an agent's own comments and its own systemd units.
- Adds a prompt hook on agent messages to Nish that bounces asks about routine,
  reversible steps, so the agent does the step and reports the result. Reserved
  matters (money, secrets, irreversible steps, safety gates) still go through.

Every `autoMode` array keeps `"$defaults"`, so these rules add to the built-in
ones and never replace them. `ansible/host.yml` installs the drop-in with a
`validate:` that refuses a file that is not a JSON object (a drop-in that does
not parse stops Claude Code from starting on the whole box), and the `ci` check
"Claude Code managed-settings drop-ins parse and keep the autoMode defaults"
holds both rules before merge.

- Verify: `claude auto-mode config` prints the effective rules, which now
  include the entries from the drop-in beside the defaults.
- Switch it off: a PR that deletes the file from `rootfs/` and adds
  `/etc/claude-code/managed-settings.d/50-agent-autonomy.json` to `retired` in
  `ansible/host.yml`. Remove the "Claude Code managed-settings drop-ins" ci
  step and the install task in the same PR once no drop-in is left.

