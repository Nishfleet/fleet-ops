## Weekly retro

`retro-weekly.timer` starts `retro-weekly.service` every Monday at 07:00 IST.
It is built so a fooled model cannot do harm, not so it is asked not to.

- The model runs in a bwrap jail: the system is read-only, `/home` is an empty
  tmpfs, and only the session logs and steering files are bound back read-only. The gh login, the Cloudflare tokens, the
  seat files, the App key and the other Claude logins are not there.
- It has no GitHub token. A later step in the unit files at most three
  follow-up issues using the worker App's issues-only installation token
  (`fleet-grafana-github-token.service` mints it) with an empty `gh` config
  directory. Repo and labels are fixed in the unit.
- The report goes to the vault's `_system/retro/` and syncs to the Mac. A
  follow-up issue is a fixed five-line file (class, count, fix rung, owning
  repo and fix kind, each from a list); the unit builds the public title and
  body from a template, then `config/retro-public-deny.txt` must find no session
  id, path, quote, time of day, link, email or secret shape in it. One refusal
  fails the unit and files nothing.
- The jail has no network. The only way out is `retro-weekly-api.socket`, served
  by `systemd-socket-proxyd` to `api.anthropic.com:443` and nothing else.
- Follow-up issues carry only the label `retro` (`needs-orchestrator` would start
  a paid orchestrator run per issue), one open issue per class.
- The call is Claude Code to the Anthropic API with the model pinned in the unit.
  The `ollama` seat is a cloud service (`api_base` is `https://ollama.com`), so
  it is not used. The pin check fails the unit if the call was anything else
  and prints a `retro-provider:` line.

- Run it now: `systemctl --user start retro-weekly.service`, then
  `journalctl --user -u retro-weekly -f`.
- Switch it on: `systemctl --user enable --now retro-weekly.timer`.
- Switch it off: `systemctl --user disable --now retro-weekly.timer`.
- Delete it: switch it off, delete the four units (service, timer, api socket and api service), `prompts/retro-weekly.md`, the two
  `config/retro-*` files and step 2e of `systemd/fleet-sync.service`, then
  `systemctl --user unlink retro-weekly.service retro-weekly.timer retro-weekly-api.socket retro-weekly-api.service`.

