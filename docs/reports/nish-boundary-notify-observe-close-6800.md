# Observe-close for #6800 — bin/nish-boundary-notify `printf '%b'` escapes + missing 4096-char guard

Issue #6800 (found by the review-6037 audit, fleet-ops#6032 follow-up)
flagged `bin/nish-boundary-notify` for two defects in its 6h
unanswered-questions Telegram digest:

1. The digest body was passed through `printf '%b'`, which interprets
   backslash escapes inside question text: a literal `\n` or `\t` renders
   as a newline/tab and a trailing `\c` truncates the message.
2. No 4096-char Telegram limit guard: an oversized digest fails delivery,
   and because the marker is written only on success the same digest
   retries every 6h until the question set shrinks.

Both findings were accurate for the code that existed when the audit ran.
The subject no longer exists: the whole boundary-notify tower was deleted
on 2026-09-18, so both acceptance items are moot. This report is the
resolution record; no new code is needed.

## Provenance

- The buggy line is visible in the last revision that carried the file
  (`git show 6fdd20ed1^:bin/nish-boundary-notify`, ~line 269):

  ```
  "$HERMES_BIN" send -t telegram --class MONEY-BOUNDARY "$(printf '%b' "$msg")" </dev/null >/dev/null 2>&1
  ```

  `$msg` is assembled just above as `"$msg\n$l"`, where `$l` interpolates
  the raw question title — `%b` was needed to expand the intended `\n`
  separators and expanded any `\n`/`\t`/`\c` inside question text along
  with them. No length check exists anywhere in the digest path.
- `6fdd20ed1` "cut(escalation): one stock amtool line replaces the
  1,181-line notify tower" (committed 2026-09-18, ancestor of
  origin/main) deleted `bin/nish-boundary-notify` (513 lines),
  `bin/money-boundary-raise`, `bin/hermes`, the `nish-boundary-notify.path`
  unit, the three installed binaries under `~/.local/bin`, and the 7
  tests that pinned them.
- The replacement is the documented stock line
  `amtool alert add alertname=NishEscalation severity=nish --annotation=summary='...'`
  → alertmanager `severity="nish"` route → `telegram` receiver
  (`config/alertmanager.yml:76`, `group_interval: 1m`,
  `message: '[{{ .Status }}] {{ .CommonLabels.alertname }}: {{ .CommonAnnotations.summary }}'`).

## Why neither acceptance item needs new code

- **"`%b` escape interpretation"** cannot exist in the new path: there is
  no `printf`, and no escape-interpretation layer anywhere in it. amtool
  passes `--annotation` values verbatim into the POST /api/v2/alerts JSON
  body, and the Go template emits `.CommonAnnotations.summary` verbatim
  into the sendMessage `text` field. Live proof below: a summary
  containing literal `\n`, `\t` and a trailing `\c` was stored and
  delivered as two-char backslash sequences.
- **"bounded-length guard"** is upstream's job now: alertmanager's
  telegram notifier truncates rendered messages to the 4096-char Bot API
  limit instead of failing the send (installed build:
  prometheus-alertmanager 0.26.0+ds). Live proof below: a 4421-char
  summary delivered with `notifications_failed_total{integration="telegram"}`
  staying 0 — Telegram answers HTTP 400 clientError for oversized text,
  so a clean delivery at that size is only possible via truncation.
- **The stuck-retry loop is gone with the file**: there is no marker.
  Retry state belongs to alertmanager (`repeat_interval: 6h` on a
  still-firing alert, `resolve_timeout: 5m`, explicit `endsAt` on
  API-posted alerts); a failed send surfaces as
  `notifications_failed_total` and a fleet alert, not a silent 6h
  re-digest.

## Verification (2026-09-20 ~04:2x UTC, worktree claim/issue-6800 at 4ad959b67)

- Subject gone from origin/main: `find . -name '*boundary*'` in the
  worktree → zero hits; `git log --all -- bin/nish-boundary-notify` ends
  at deletion commit `6fdd20ed1`, and `git merge-base --is-ancestor
  6fdd20ed1 origin/main` passes.
- Host clean: `systemctl --user list-unit-files` and `list-units` grep
  'boundary|hermes' → no hits; `find ~/.config/systemd -iname
  '*boundary*' -o -iname '*hermes*'` → zero; `ls ~/.local/bin` grep
  'boundary|hermes' → zero.
- Replacement live: `prometheus-alertmanager.service` active, amtool
  0.26.0 reaching 127.0.0.1:9093 unauthenticated; the `severity="nish"`
  → telegram route is in `config/alertmanager.yml`.
- **Live probe** (one synthetic alert, same method the tower-cut commit
  used): `amtool alert add alertname=NishEscalation severity=nish
  probe=fleet-ops-6800 --annotation=summary=<4421-char payload containing
  literal \n, \t and a trailing \c> --end +5min`.
  - GET /api/v2/alerts shows the stored annotation at length 4421 with
    `repr()` returning `\\n`/`\\t`/`\\c` — verbatim two-char escapes, no
    interpretation at write.
  - `alertmanager_notifications_total{integration="telegram"}` 14 → 15;
    `alertmanager_notifications_failed_total{integration="telegram"}` = 0
    on every reason — a >4096-char text can only arrive truncated, so the
    length guard is enforced.
  - The alert carried `--end` +5min and self-resolved; a follow-up
    /api/v2/alerts read shows 0 active NishEscalation. `send_resolved:
    true` sent one resolved notification — the only residual phone
    traffic.

## Disposition

Resolved-by-deletion, matched to the 2026-09-18 glue sweep
(`6fdd20ed1`). The finding cannot re-open: the script, its path unit, its
installed binaries and the entire hand-built delivery rail are gone, and
the stock path that replaced them carries neither defect. This report
supplies the acceptance evidence; no detector, script or config change
is required.
