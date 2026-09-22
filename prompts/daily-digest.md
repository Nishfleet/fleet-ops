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

7. **Disk on /.** `df -P /` — percent used.

8. **Nish-reserved escalations.** `amtool alert query severity=nish` — the
   open reserved-class items. This is the ONLY escalation channel since the
   2026-09-18 glue sweep; NISH-ESCALATIONS.md and nish-boundary-notify are
   deleted. Zero is "No open escalations."

9. **Close** — "Reply to this message if you want anything investigated.
   Otherwise, on to the day."

## Send — THIS IS THE DELIVERABLE

Gathering the numbers is not the job; Nish receiving them is. You are NOT done
until the send block below has run and returned `"ok":true`. Do not stop after the
last gather step. Do not summarise the digest to stdout instead of sending it.
If you find yourself about to end the turn, check: have you run the send? If
not, run it now.

Transient-failure precedent (fleet-ops#7635): on 2026-09-18 the send timed out
once — `Telegram send failed: Timed out` — and that day's digest was lost
because one attempt was all the implementation had. A single network blip must
never cost a digest, so the send is a bounded retry loop, not one curl: up to
three attempts, five seconds apart, stopping the moment the response contains
`"ok":true`. On the rare timeout where Telegram did receive the message, the
retry can deliver a duplicate — a repeated digest is accepted over a lost one.

`TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are already in your environment
from the unit's EnvironmentFile — reference them as shell variables, never
inline the values and never echo them:

```bash
resp=""
for attempt in 1 2 3; do
  resp=$(curl -s --max-time 20 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    --data-urlencode text="$body") || resp=""
  if printf '%s' "$resp" | grep -q '"ok":true'; then break; fi
  echo "send attempt ${attempt} not ok: ${resp:-<curl error>}" >&2
  if [ "$attempt" -lt 3 ]; then sleep 5; fi
done
printf '%s\n' "$resp" | tee /tmp/daily-digest-send.json
```

Never run the loop a second time: if an attempt returned `"ok":true`, the
digest is delivered.

Print the API response's `ok` field and `result.message_id` as your final line,
so the systemd journal carries proof of delivery. The `tee` above writes the
final response to `/tmp/daily-digest-send.json` and prints it, so the journal
carries the result even when `pi --print` drops the final assistant text. If all
three attempts failed, the printed response is the full error — print it and say
so plainly; a digest that silently fails to send is worse than no digest.
