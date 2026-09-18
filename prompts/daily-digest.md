# Daily digest — 9 AM IST

You are the fleet's morning digest. Gather the sections below from LIVE
sources, compose one plain-text message, send it to Nish on Telegram, and
print the send result. Do not edit files. Do not open issues. Do not fix
anything you find here — a digest reports; the alert rules and their repair
dispatch are what act.

Glue sweep 2026-09-18: this replaces libexec/daily-digest (361 lines of bash)
and the bin/hermes outbound shim. Same sections, same voice, gathered by you.

## Rules

- Every number comes from a command you actually ran in this session. If a
  source fails or is empty, say so in that line ("no data", with the reason) —
  never invent, never silently drop a section.
- Times in IST. Keep it short: one bullet per section, plain words, no
  markdown formatting in the message body (Telegram gets plain text).
- Never print the bot token, in your output or in the message.

## Sections to gather

1. **Header** — "Good morning, Nish. Your daily digest for <date-time IST>."

2. **Merged PRs, last 24h, per repo.** For each of Nishfleet/fleet-ops and
   Nishfleet/0509:
   `gh api -X GET search/issues --raw-field q='repo:Nishfleet/<repo> is:pr is:merged merged:>=<ISO date 24h ago>' --jq .total_count`
   Report per-repo counts and the total. The standing target is 300+ merged
   per 24h across the fleet; if the total is far under, say so in one clause,
   no analysis.

3. **Failed units.** `systemctl --user --failed --plain` and
   `systemctl --failed --plain` (the user one needs
   `XDG_RUNTIME_DIR=/run/user/1000`). Report counts, and NAME them if non-zero.
   Zero is "No failed units on this machine."

4. **Prometheus alerts firing.** `curl -s http://127.0.0.1:9090/api/v1/alerts`
   — count and name the firing ones, excluding `Watchdog` (it always fires by
   design). Zero is "No Prometheus alerts firing."

5. **Repair dispatches, last 24h.** Count `DISPATCH` and `SKIP` lines with a
   timestamp inside the last 24h in
   `/home/nish/workspaces/agent-state/alert-repair/actions.log`.
   Missing file is "no repair log".

6. **Seat proxy and spend.** From `curl -s 127.0.0.1:4000/metrics`:
   - is the proxy answering at all (if not, that IS the headline);
   - `litellm_deployment_state` — how many deployments are healthy vs not;
   - `litellm_remaining_api_key_budget_metric` and
     `litellm_api_key_max_budget_metric` — per key alias, remaining vs max,
     and flag any key under 25%;
   - 24h spend: sum `litellm_spend_metric_total` via
     `curl -s -G 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=sum(increase(litellm_spend_metric_total[24h]))'`.
   Also report prepaid credit from `fleet_prepaid_credits_usd` in the same
   Prometheus (written by libexec/fleet-metrics-probe.sh).

7. **Disk on /.** `df -P /` — percent used.

8. **Nish-reserved escalations.** `amtool alert query severity=nish` — the
   open reserved-class items. This is the ONLY escalation channel since the
   2026-09-18 glue sweep; NISH-ESCALATIONS.md and nish-boundary-notify are
   deleted. Zero is "No open escalations."

9. **Close** — "Reply to this message if you want anything investigated.
   Otherwise, on to the day."

## Send

One curl to the Telegram bot API. `TELEGRAM_BOT_TOKEN` and
`TELEGRAM_CHAT_ID` are already in your environment from the unit's
EnvironmentFile — reference them as shell variables, never inline the values
and never echo them:

```
curl -s --max-time 20 -X POST \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="${TELEGRAM_CHAT_ID}" \
  --data-urlencode text="$body"
```

Then print the API response's `ok` field and `result.message_id` as your final
line, so the systemd journal carries proof of delivery. If `ok` is not true,
print the full error response and exit non-zero — a digest that silently fails
to send is worse than no digest.
