## Claude plugin drop-ins

`rootfs/etc/claude-code/managed-settings.d/60-nish-mods.json`,
`65-ask-ledger.json`, `80-inbox.json` and `85-no-playwright.json` are
managed-settings drop-ins that carry only plugin state: an
`extraKnownMarketplaces` entry that registers the marketplace the box reads the
plugins from, and the `enabledPlugins` ids. A plugin id is `name@marketplace`, and
a marketplace that no drop-in declares and the box has not registered leaves the
id dead, so each drop-in that enables a plugin names its own marketplace. A drop-in
that switches a plugin off names no marketplace: the box installed the plugin at
user scope and the drop-in only overrides that entry with `false`. Both marketplaces
are `github` sources, so Claude Code loads the plugins from its plugin cache and no
path into a working tree is involved (fleet-ops#10823).

- `60-nish-mods.json` registers the nish-mods marketplace (`Nishfleet/claude-mods`;
  the repo has no tags, so no `ref`) and enables
  `model-lanes` (every subagent goes to the fleet workers) and `wake-check` (a
  Stop hook blocks a turn that ends on a promise to continue later unless a
  background wait is armed for the awaited condition).
- `80-inbox.json` registers the inbox marketplace (`petekp/inbox`, pinned to tag
  `v0.2.14`) and enables `inbox`. Bump the `ref` by PR to take a new release.
- `85-no-playwright.json` switches `playwright@claude-plugins-official` off, so no
  Claude Code session loads the Playwright browser tools (fleet-ops#10529: the box
  has one browser tool, the Chrome DevTools MCP). Managed settings win over the
  user's `enabledPlugins`, which still lists the plugin as `true`, so leaving the
  user file alone is safe. Switch it back on: delete the file and add
  `/etc/claude-code/managed-settings.d/85-no-playwright.json` to `retired` in
  `ansible/host.yml`, because `copy` never deletes.

Every `enabledPlugins` key merges with `/etc/claude-code/managed-settings.json`,
which now ships from `rootfs/etc/claude-code/managed-settings.json` ([Managed-settings
defaults](managed-settings-defaults.md)) and keeps its own `model-lanes` line: two files
naming the same id with the same value is a no-op merge.

- Verify: `claude -p hi --output-format stream-json --verbose` prints an init
  line whose plugin list carries every enabled id, and no switched-off one.
- Switch one plugin off: set its id to `false` in the drop-in and merge.
- Switch a drop-in off: a PR that deletes the file from `rootfs/` and adds its
  `/etc` path to `retired` in `ansible/host.yml`.
- The check is the `unit` job's `tests/test_claude_managed_settings.py`: every
  drop-in is a JSON object, every enabled id names a marketplace a drop-in
  declares or the box has registered, every id is listed in that
  marketplace's own `marketplace.json` when the directory is on disk, and the
  Playwright switch-off is pinned to `85-no-playwright.json` (a `false` id names
  no marketplace and is exempt from the manifest check).

