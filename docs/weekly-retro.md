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
- Every filed issue is echoed on one final `retro-filed:` line naming its repo,
  its number and its labels, so a run that filed nothing says so on that line.
  No model call happens in the filing step. Issue #9323 asked for a judge to
  decide `agent-ready` per finding, and the measurement below is why that is not
  built: `tests/evals/results/retro_queue.json` scores 20 held-out fixed-form
  findings on the live `/jev` seat and no answer reaches the 0.9 band the rest of
  the fleet uses, with a 0.029 gap between the two labelled halves. The five
  fixed values carry no evidence, so a judge reading them has nothing to decide
  from, and an `agent-ready` issue would hand a worker a five-field body and no
  detail to fix. Adding the label by any other rule would queue work no one can
  act on. A retro finding that needs engineering judgment is the weekly report's
  job, not the issue body's.
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

