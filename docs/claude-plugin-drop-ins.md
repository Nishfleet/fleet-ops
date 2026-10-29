## Claude plugin drop-ins

`rootfs/etc/claude-code/managed-settings.d/60-nish-mods.json`,
`62-no-toy-mods.json` and `80-inbox.json` are managed-settings drop-ins that
carry only plugin state: an `extraKnownMarketplaces` entry that registers the
marketplace the box reads the plugins from, and the `enabledPlugins` ids. A
plugin id is `name@marketplace`, and a marketplace that no drop-in declares and
the box has not registered leaves the id dead, so each drop-in names its own
marketplace. `fleet-sync.service` fetches and fast-forwards the claude-mods
clone, so the nish-mods directory marketplace is always at `origin/main` (a
failure fails the unit).

- `60-nish-mods.json` registers the nish-mods directory marketplace and enables
  `model-lanes` (every subagent goes to the fleet workers) and `wake-check` (a
  Stop hook blocks a turn that ends on a promise to continue later unless a
  background wait is armed for the awaited condition).
- `80-inbox.json` registers the inbox directory marketplace and enables `inbox`.
  Its content is the file that was hand-written on the box, carried over as-is.
- `62-no-toy-mods.json` switches the four toy mods off: `code-pet`, `boss-fight`,
  `usage-meter` and `token-weather` (decision fleet-ops#10528). They are plugin
  directories rather than marketplace plugins, so the box discovers them from
  `CLAUDE_CODE_PLUGIN_DIRS` in the user settings file and their id ends
  `@inline`; the drop-in turns each one off by id, and a `false` there wins over
  the directory being listed. A managed `enabledPlugins` key merges key by key
  with the user file, which names no inline id, so nothing has to change on the
  box. When the `CLAUDE_CODE_PLUGIN_DIRS` line leaves the user settings
  (fleet-ops#10540), these ids name plugins nobody loads: delete this file and
  retire its `/etc` path in the same PR.

Every `enabledPlugins` key merges with `/etc/claude-code/managed-settings.json`,
which now ships from `rootfs/etc/claude-code/managed-settings.json` ([Managed-settings
defaults](managed-settings-defaults.md)) and keeps its own `model-lanes` line: two files
naming the same id with the same value is a no-op merge.

- Verify: `claude -p hi --output-format stream-json --verbose` prints an init
  line whose plugin list carries every enabled id.
- Switch one plugin off: set its id to `false` in the drop-in and merge.
- Switch a drop-in off: a PR that deletes the file from `rootfs/` and adds its
  `/etc` path to `retired` in `ansible/host.yml`.
- The check is the `unit` job's `tests/test_claude_managed_settings.py`: every
  drop-in is a JSON object, every enabled id names a marketplace a drop-in
  declares or the box has registered, and every id is listed in that
  marketplace's own `marketplace.json` when the directory is on disk. A plugin
  the box loads from a directory has no marketplace, so its id ends `inline`,
  and that name passes only when the value is `false`: nothing checks the name
  of a directory-loaded plugin, so the repo cannot carry switching one on.
