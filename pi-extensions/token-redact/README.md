# token-redact

A Pi extension that rewrites token-shaped strings out of the session file before Pi writes them, so a raw token never reaches `~/.pi/agent/sessions`.

Audit item W1c of the 2026-10-22 VPS audit (fleet-ops#10157): the writer side of the redaction design. Purging the rows already in the stores is W1b, another lane.

## What it does

It registers two handlers and no tools: `tool_result` and `message_end`. Both fire before Pi appends the message to the session file, so the stored copy is the redacted one. Text, thinking, the arguments error string and the content, details and structured content of a tool result are redacted; image blocks and tool-call arguments are left alone.

The `tool_result` rewrite is also what the model reads on the next turn, because Pi hands the tool result back from the same message. A run that must pass a token through its own command line does not fit this extension: run it with `TOKEN_REDACT=off`.

A tool call's `arguments` stay as the model wrote them. Pi replaces the message in place, so the object it stores is the object it runs: rewriting the arguments would run the command with the placeholder in place of the token. What the extension can reach instead is the copy of that command in the tool result.

A match becomes `[REDACTED:<shape-id>]`, so a later reader can see that something was removed and which shape it was, and never see the value.

Six shapes, each bounded by its own character class so a word that merely contains a token prefix is not touched. The class in front of a token is the class that can follow it, plus the two characters of a JSONL escape, so a token on the second line of a JSONL transcript is redacted too.

| shape id | what it catches |
| --- | --- |
| `store-github-token` | `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_` |
| `store-github-fine-grained-pat` | `github_pat_` |
| `store-anthropic-key` | `sk-ant-` |
| `store-gitlab-token` | `glpat-` |
| `store-slack-token` | `xoxb-`, `xoxa-`, `xoxp-`, `xoxr-`, `xoxs-` |
| `store-npm-token` | `npm_` |

`src/shapes.ts` is the only list. `shapeRegex` builds one regex per shape, and the tests import it, so a change to the boundary rules is a change in one place.

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

46 tests, no network: a fake Pi records the handlers, and a session-shaped JSONL transcript is the input. They cover each shape, the boundaries (a prefix inside a longer word is not touched, two adjacent tokens are both redacted, a token after a JSONL escape is redacted), every content type, the off switch, that a tool call's arguments pass through unchanged, and that the extension registers no tool, no command and no flag.

## Switch off, delete

Set `TOKEN_REDACT=off` in the environment of the run you want unchanged.

To delete it: remove this directory. Nothing else reads it.

## What this does not cover

- **Claude Code** and **Devin** write their own transcripts with no stock redaction switch, so their stores keep the gap. The upstream asks are filed on each vendor's tracker; see the issue for the links.
- **Leviathan** mirrors the Pi and Claude logs into its own SQLite index, so a token already in a log is already in the index. Fixing the writers fixes the index going forward.
- Rows already in a store are purged by W1b, not here.

## Measured canary, 2026-10-23

One fake token-shaped string per shape, written through Pi's own tool output, then the session file read back:

| writer | shapes in the store | note |
| --- | --- | --- |
| Pi with this extension | **0** | 6 `[REDACTED:store-...]` markers instead |
| Pi without it (`TOKEN_REDACT=off`) | 6 | the negative control |

The other writers in that run were measured with a store scanner that is not part of this repo, so their numbers stay in fleet-ops#10157.
