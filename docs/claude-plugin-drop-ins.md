## Claude plugin drop-ins

`rootfs/etc/claude-code/managed-settings.d/60-nish-mods.json` and
`80-inbox.json` are managed-settings drop-ins that carry only plugin state: an
`extraKnownMarketplaces` entry that registers the marketplace the box reads the
plugins from, and the `enabledPlugins` ids. A plugin id is `name@marketplace`, and
a marketplace that no drop-in declares and the box has not registered leaves the
id dead, so each drop-in names its own marketplace. `fleet-sync.service` fetches
and fast-forwards the claude-mods clone, so the nish-mods directory marketplace is
always at `origin/main` (a failure fails the unit).

- `60-nish-mods.json` registers the nish-mods directory marketplace and enables
  `model-lanes` (every subagent goes to the fleet workers) and `wake-check` (a
  Stop hook blocks a turn that ends on a promise to continue later unless a
  background wait is armed for the awaited condition).
- `80-inbox.json` registers the inbox directory marketplace and enables `inbox`.
  Its content is the file that was hand-written on the box, carried over as-is.

Every `enabledPlugins` key merges with `/etc/claude-code/managed-settings.json`,
which now ships from `rootfs/etc/claude-code/managed-settings.json` (README,
"Managed-settings defaults") and keeps its own `model-lanes` line: two files
naming the same id with the same value is a no-op merge.

- Verify: `claude -p hi --output-format stream-json --verbose` prints an init
  line whose plugin list carries every enabled id.
- Switch one plugin off: set its id to `false` in the drop-in and merge.
- Switch a drop-in off: a PR that deletes the file from `rootfs/` and adds its
  `/etc` path to `retired` in `ansible/host.yml`.
- The check is the `unit` job's `tests/test_claude_managed_settings.py`: every
  drop-in is a JSON object, every enabled id names a marketplace a drop-in
  declares or the box has registered, and every id is listed in that
  marketplace's own `marketplace.json` when the directory is on disk.

