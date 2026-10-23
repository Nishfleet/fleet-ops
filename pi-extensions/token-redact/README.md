# token-redact

A Pi extension that rewrites token-shaped strings out of the session file before Pi writes them, so a raw token never reaches `~/.pi/agent/sessions`.

Audit item W1c of the 2026-10-22 VPS audit (fleet-ops#10157): the writer side of the redaction design. Purging the rows already in the stores is W1b, another lane.

## What it does

It registers two handlers and no tools: `tool_result` and `message_end`. Both fire before Pi appends the message to the session file, so the stored copy is the redacted one. Text, thinking, tool-call arguments and the arguments error string are redacted; image blocks are left alone.

A match becomes `[REDACTED:<shape-id>]`, so a later reader can see that something was removed and which shape it was, and never see the value.

Six shapes, each bounded by its own character class so a word that merely contains a token prefix is not touched:

| shape id | what it catches |
| --- | --- |
| `store-github-token` | `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_` |
| `store-github-fine-grained-pat` | `github_pat_` |
| `store-anthropic-key` | `sk-ant-` |
| `store-gitlab-token` | `glpat-` |
| `store-slack-token` | `xoxb-`, `xoxa-`, `xoxp-`, `xoxr-`, `xoxs-` |
| `store-npm-token` | `npm_` |

The same six shapes, in the same order, live in `config/token-store-scan.toml` (gitleaks, for scanning a store) and `.semgrep/token-store-shapes.yml` (the CI rule). `tests/test_token_store_scan.py` fails when the three lists drift, so widening one and not the others is red.

## Install

```
pi install <path or git url>
```

or load it for one run with `-e`:

```
pi -e pi-extensions/token-redact/index.ts
```

Pi's own extension point, no wrapper. `package.json` names `./index.ts` as the single extension entry.

## Configuration

| variable | default | what it does |
| --- | --- | --- |
| `TOKEN_REDACT` | unset, redaction on | set to `0`, `false`, `no` or `off` to stop redacting |

The switch is read once, when Pi loads the extension, so a session that started with redaction on keeps it for its whole life.

## Tests

```
npm ci
npm test
```

42 tests, no network: a fake Pi records the handlers, and a session-shaped JSONL transcript is the input. They cover each shape, the boundaries (a prefix inside a longer word is not touched, two adjacent tokens are both redacted), every content type, the off switch, and that the extension registers no tool, no command and no flag.

`tests/test_token_store_scan.py` in the repo root runs them in CI, alongside the checks that hold the three shape lists in step.

## Switch off, delete

Set `TOKEN_REDACT=off` in the environment of the run you want unchanged.

To delete it: remove this directory, `config/token-store-scan.toml`, `.semgrep/token-store-shapes.yml` and `tests/test_token_store_scan.py`, and drop the semgrep config from the `semgrep scan` line in `.github/workflows/ci.yml`. Nothing else reads them.

## What this does not cover

- **Claude Code** and **Devin** write their own transcripts with no stock redaction switch, so their stores keep the gap. The upstream asks are filed on each vendor's tracker; see the issue for the links.
- **Leviathan** mirrors the Pi and Claude logs into its own SQLite index, so a token already in a log is already in the index. Fixing the writers fixes the index going forward.
- Rows already in a store are purged by W1b, not here.
- `config/token-store-scan.toml` deliberately turns the default gitleaks rules off: `generic-api-key` alone flagged 20,000 lines of ordinary prose and hashes in the Claude transcripts.
