## Provider watch

Providers change their offerings and publish no change event (Command Code moved to
one model only, OpenCode added a free slug), and nothing on the box noticed. A daily
schedule is the only way to see it, so `fleet-provider-watch.timer` starts
`fleet-provider-watch.service` every day at 06:30 IST (a few minutes of random delay,
`Persistent=true`).

No model id is ever stored in or filed on this public repo. The snapshot, the changed-id
lists and an optional ignore list live on the host, in the unit's `StateDirectory`
(`~/.local/state/provider-watch`, mode 0700); the repo keeps only `config/provider-watch.json`.

- One run reads each distinct provider (api_base plus the `os.environ/` key name, unique by key
  variable) from `config/litellm-proxy.yaml` and GETs its OpenAI-style `<api_base>/models` listing
  with that provider's key. A base with no `/v1`-style tail (`https://ollama.com`, the MiniMax
  `/anthropic` base) gets `/v1/models`. `curl --retry 2 --retry-delay 20` (three tries, 20 s apart;
  curl does not retry 401 or 403), so a blip does not page. The key goes to curl in a 0600 header
  file in the unit's runtime directory (`-H @file`), never argv.
- The keys come from the same per-provider key files the LiteLLM container reads; the unit lists
  the ones it needs one by one (not the whole directory), so the master key and the Claude logins
  are not in its environment. A missing file fails the unit with a plain line naming that provider
  while every other provider is still checked (`EnvironmentFile=-`); CI fails when a router key has
  no file line in the unit.
- First run for a provider: the sorted ids are saved to `catalog.json` in the state directory and
  nothing is filed (`provider-watch: <name> seeded, <n> models, nothing filed`).
- Later runs diff against that snapshot. A change writes the added and removed ids to
  `changes/<UTC date>-<provider>.txt` in the state directory (no cap), files ONE issue per changed
  provider, and then updates the snapshot, so a change is not filed twice. A provider whose filing
  fails keeps its old snapshot and fails the unit.
- The issue is fixed text only: title `Provider watch: <provider> model list changed`, the added and
  removed counts, the sentence "The ids are in the host state file changes/<date>-<provider>.txt
  under the StateDirectory of fleet-provider-watch.service." and the acceptance bullets. No text
  from the network reaches it. Labels `provider-watch` (created if missing, never rewritten) and
  `needs-orchestrator`: fleet-ops#8304 says control-plane work is never self-admitted, and the vault
  standing rule (`global-standing-rules.md`, nish3451/nish-vault#23) makes this one exception, from
  Nish on 2026-10-15, so the worker App's label starts one orchestrator hand-off run per issue (a
  paid model session, capped by `ORCHESTRATE_DAILY_MAX`). That run is on this host as the runner
  user, unjailed, so it reads `~/.local/state/provider-watch/changes/<file>` directly; the body
  tells it to keep ids out of issue text, PR text and commits. An issue with the same title that is open, or was created in the last 7 days even if
  closed, means the change is not filed again (the snapshot still updates). At most 3 issues per
  run; the rest wait for the next run.
- The acceptance bullets: a seat marked `"billing": "flat"` in `config/provider-watch.json` may get
  a real call to free or in-plan ids only; every other seat's body forbids all calls and sends the
  ids back as a `needs-nish-decision` line (the unit decides, not the model; MiniMax is marked flat
  on the router config header: "he is on the flat MiniMax Yearly Plus plan (5-hour and weekly
  limits, no per-token bill)", Nish 2026-10-09; the OpenCode keys are unlimited for
  one DeepSeek flash model only, so they are not marked; the Alibaba Token Plan stays unmarked on
  purpose, so its added ids get no call at all: its billing, credit ceiling and judge-only row are
  recorded in the router config header (fleet-ops#9220) and in Nish's ruling on that seat
  (fleet-ops#4445, "this token plan isn't for use with other models"), so a probe of another ID
  spends the judge lane's own allowance on a model that can carry no row. Nish kept the plan on
  2026-10-28 and left the classification to the agents (fleet-ops#9914): the agents implement that
  kept plan here, and any future spend, renewal or plan change stays a `needs-nish-decision` line.
  Then an eval-score before any router weight
  (`tests/evals`), a router PR only inside the standing rules (no new spend, 3 to 5 providers,
  removing a router row needs Nish's yes, no extra weight for a lower score), and a plain
  `needs-nish-decision` line for anything that costs money or needs his login.
- Every id must match `^~?[A-Za-z0-9._:/-]{1,64}$` and hold no `//` or `www.`, or that provider is
  refused: the unit fails with a line showing the first offender sanitized to `[A-Za-z0-9_-]`, and
  nothing is recorded or filed for it. Only a change to `ignore.txt` or to the provider's `watch`
  clears it.
- A listing that is still 5xx, 408, 429, a timeout, empty, or empty after the filters logs
  `provider-watch: <name> listing unavailable (HTTP <code>), skipped; outages page through
  litellm_deployment_state` and does not fail the unit. Any other non-200 (404 from a wrong listing
  path or api_base, 400) fails it, so a provider cannot silently drop out of the check. HTTP 401 or
  403 means a dead or expired key or login: every run logs one plain line naming the provider and
  what Nish must do and moves on (fleet-ops#9912: a standing state must not re-fail the unit on
  every daily run and keep the failed-unit list never empty), and no issue is filed. A router row
  with a key but no https api_base, or a key variable outside `^[A-Z][A-Z0-9_]*_API_KEY(_[0-9]+)?$`,
  is refused.
- `config/provider-watch.json` holds only generic per-provider settings: `watch` (an ERE; only ids
  matching it are compared; Cline lists a large catalogue that changes about weekly, so it watches
  only `:free`, `-free`, `deepseek/`, `z-ai/` and `cline` ids), `billing` (`flat`) and `listing`
  (`none` skips a provider with no listing endpoint). Ids to hide (early-access names) go one
  extended regex per line in `ignore.txt` in the state directory, matched case-insensitively; they
  never go in git.
- Not covered: outages (`litellm_deployment_state` in Grafana already pages those) and
  `not covered: price/limit pages, no API`.

- Run it now (it files a real issue on a change): `systemctl --user start fleet-provider-watch.service`, then
  `journalctl --user -u fleet-provider-watch -f`.
- Switch it on (once): `systemctl --user enable --now fleet-provider-watch.timer`. `fleet-sync.service`
  links the pair on every deploy (step 2g) but never enables it. The first run seeds the snapshot.
- Switch it off: `systemctl --user disable --now fleet-provider-watch.timer`.
- Read a change: `cat ~/.local/state/provider-watch/changes/<date>-<provider>.txt`. Reset a
  provider: delete its key from `catalog.json` (the next run seeds it again).
- Delete it: switch it off, delete `systemd/fleet-provider-watch.service`,
  `systemd/fleet-provider-watch.timer`, `config/provider-watch.json`, `tests/test_provider_watch.py`
  (and its name on the pytest line of the gh-login step in `ci.yml`), the two rows in
  `.agents/skills/verify-fleet/fleet-map.md` and step 2g of `systemd/fleet-sync.service`, then
  `rm` the two links in `~/.config/systemd/user/`, run `systemctl --user daemon-reload` and
  `rm -r ~/.local/state/provider-watch`.

