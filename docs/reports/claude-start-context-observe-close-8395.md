# Observe-close for #8395 — Claude session start context

Issue #8395 asked for a per-item measurement of the VPS Claude start context,
then a config deletion of items with zero use in the last 14 days of
transcripts. `~/.claude/settings.json` is not a repo file (no symlink, not in
the README copy-allowlist, `git log -S enabledPlugins` is empty). The change
is on the host. This report is the receipt.

The host diff against
`~/.claude/settings.json.bak-before-8395-20260923T062416Z` touches exactly
two keys:

- `skillOverrides` was empty and is now 54 entries, each the string `"off"`.
- `enabledPlugins` flipped two keys from true to false:
  `code-review@claude-plugins-official` and
  `commit-commands@claude-plugins-official`.

No other key differs. Neither file has `mcpServers` or
`enabledMcpjsonServers`, so the MCP part of the ask had nothing to disable.

## What the probes measured

First-request context is `input_tokens + cache_creation_input_tokens +
cache_read_input_tokens` on the first assistant usage record. Claude Code
was 2.1.280 for every session below.

| Probe | Session | Total |
|---|---|---|
| bare baseline | `~/.claude/projects/-tmp-ab-before/237a63dd-11c2-46e8-a431-667c2fdfc83a.jsonl` | 31,134 |
| bare baseline, second session | `~/.claude/projects/-tmp-ab-before2/c00ca93a-….jsonl` | 31,136 |
| overrides on, plugins still on | `~/.claude/projects/-tmp-dbg-after/06cb8531-740d-4c71-9fe6-404a031bfaab.jsonl` | 24,884 |
| live settings | `~/.claude/projects/-tmp-final-after/13709794-1327-430b-97bc-fdc1f7cd7760.jsonl` | 24,892 |
| live settings, second session | `~/.claude/projects/-tmp-verify-live/19af1026-4a48-4fdd-bc6f-2156d1649f06.jsonl` | 24,894 |
| `$HOME` before | `~/.claude/projects/-home-nish/8a579ba5-7434-4312-bcd2-4584b92b7696.jsonl` | 38,217 |
| `$HOME` after | `~/.claude/projects/-home-nish/5a7978fe-98e4-4b6c-b226-92a85cbe46c0.jsonl` | 32,198 |

The durable bare cut is 31,134 → 24,892 (−6,242). The durable `$HOME` cut
is 38,217 → 32,198 (−6,019). The −6,250 figure (31,134 → 24,884) is the
mid-cut session `06cb8531`, which also dropped `frontend-design` from the
listing; the live session `13709794` puts that line back. It is not the
cut on every fresh session.

`$HOME` is 7,083 above the bare baseline before the cut (38,217 − 31,134)
and 7,306 above after (32,198 − 24,892). The instructions attachment is
the difference: both `$HOME` sessions hash to `4e631daac778` and include
`~/.claude/projects/-home-nish/memory/MEMORY.md` (15,495 characters in
the before-session instructions JSON). Both bare sessions hash to `a763c568f272` and do
not. That file is the memory index. It was left in place.

Between the `$HOME` pair the instructions hash does not change. Attachment
JSON size moves by −17,855 on `skill_listing`, +14 on `deferred_tools_delta`,
and −1 on `hook_success`. The 6,019 tokens are the skill listing.

Between the bare baseline and the live session the instructions hash does
not change. Attachment JSON size moves by −18,763 on `skill_listing` and
by +2, −1, and +4 on `environment`, `hook_success`, and `prompt_snapshot`
(the cwd path in the memory paragraph). The 6,242 tokens are the listing.

## Per-item token cost

The `$HOME` before listing is 29,332 characters (under the 30,008 character
cap the bare transcript hits), 103 names. The after listing is 12,557
characters, 52 names. The 53 removed blocks are the exact text in
`8a579ba5`'s `skill_listing.content`. Their lengths sum to 17,700.
Each item's tokens are `6019 × (block chars) / 17700`, largest-remainder
rounded so the column sums to 6,019.

`pydantic` is one of the 54 `skillOverrides` and costs 0 in this table.
Its `SKILL.md` sets `user-invocable: false` and `disable-model-invocation: true`,
and the name is absent from both listings.

| Skill | Listing chars | Tokens |
|---|---:|---:|
| playwright-best-practices | 1014 | 345 |
| swiftui-expert-skill | 781 | 266 |
| ai-sdk | 615 | 209 |
| cloudflare-email-service | 537 | 183 |
| fastmcp | 520 | 177 |
| ast-grep | 510 | 173 |
| tailwind-v4-shadcn | 507 | 172 |
| xcode-build-orchestrator | 490 | 167 |
| php-pro | 487 | 166 |
| turborepo | 475 | 161 |
| oxlint | 475 | 161 |
| web-perf | 466 | 158 |
| agents-sdk | 446 | 152 |
| turnstile-spin | 437 | 149 |
| check-pr | 431 | 147 |
| durable-objects | 402 | 137 |
| shadcn | 395 | 134 |
| swift-testing-expert | 390 | 133 |
| workers-best-practices | 386 | 131 |
| vercel-react-best-practices | 361 | 123 |
| sandbox-sdk | 359 | 122 |
| angular-developer | 353 | 120 |
| tailwind-css-patterns | 346 | 118 |
| vercel-composition-patterns | 342 | 116 |
| cloudflare-one | 342 | 116 |
| zod | 338 | 115 |
| typescript-advanced-types | 334 | 114 |
| email-and-password-best-practices | 323 | 110 |
| finish-saas-product | 322 | 109 |
| adev-writing-guide | 317 | 108 |
| better-auth-best-practices | 315 | 107 |
| nodejs-backend-patterns | 312 | 106 |
| design-inspiration-picker | 290 | 99 |
| core-data-expert | 285 | 97 |
| swift-concurrency | 264 | 90 |
| accessibility | 230 | 78 |
| cloudflare-one-migrations | 217 | 74 |
| bash-defensive-patterns | 216 | 73 |
| bun | 212 | 72 |
| seo | 211 | 72 |
| cloudflare-deploy | 211 | 72 |
| vite | 196 | 67 |
| tdd-workflow | 188 | 64 |
| next-best-practices | 185 | 63 |
| reference-core | 175 | 59 |
| nodejs-best-practices | 173 | 59 |
| next-cache-components | 112 | 38 |
| next-upgrade | 103 | 35 |
| pr-review | 89 | 30 |
| design-polish | 63 | 21 |
| bootstrap | 60 | 20 |
| release-notes | 54 | 18 |
| backlog | 38 | 13 |

The four plugin command names are not in the `$HOME` before listing, so
they are not in that 6,019. They are in the bare before listing
(`237a63dd`, 109 names) and gone from the live listing (`13709794`, 52
names). The stored lines are name-only; the next entry,
`typesafe:typesafe-ai`, still has its description, so the names are not
a tail cut. Same apportionment against the bare 6,242 tokens and 17,813
listing characters:

| Listing line | Chars | Tokens |
|---|---:|---:|
| `- commit-commands:clean_gone` | 29 | 10 |
| `- commit-commands:commit-push-pr` | 33 | 12 |
| `- commit-commands:commit` | 25 | 9 |
| `- code-review:code-review` | 26 | 9 |

That is 40 tokens, not a 2-token plugin surface. `06cb8531` (plugins still
on, 24,884, 55 names) versus `13709794` (those two plugins off, 24,892,
52 names) is +8. The listing went 12,488 → 12,557 characters because
`frontend-design`'s description came back while the four short command
names left.

## 91 skill dir commands and 73 directories

`/tmp/dbg-after/log` at 2026-09-23T06:23:16.553Z says
`getSkills returning: 91 skill dir commands, 3 plugin skills, 40 bundled skills`.
In the 2.1.280 binary that count is `skillDirCommands.length` from the
loader whose failure log says "Skill directory commands failed to load".
On disk that day, and still:

- 73 entries in `~/.claude/skills/` (directories and skill symlinks),
  excluding `.stfolder`, `.stignore`, `MEMORY.md`, and the `synced` container.
- 18 files in `~/.claude/commands/`.

73 + 18 = 91. The two sets do not overlap. All 18 command stems are in
the bare listing's 109 names. `pydantic` is one of the 73 and is not in
the 109, for the frontmatter reason above.

The attachment count is a third number. Bare listing 109 =
72 skill directories (the 73 minus `pydantic`) + 18 command files + 19
plugin and bundled names: `claude-api`, `code-review:code-review`,
`commit-commands:clean_gone`, `commit-commands:commit`,
`commit-commands:commit-push-pr`, `dataviz`, `fewer-permission-prompts`,
`frontend-design:frontend-design`, `init`, `keybindings-help`,
`last30days:last30days`, `loop`, `run`, `schedule`, `security-review`,
`simplify`, `typesafe:typesafe-ai`, `update-config`, `workflow-authoring`.

Debug attachment counts, same logs: 109
(`/tmp/claude-ctx-debug.log` 2026-09-23T05:54:51.444Z), 55
(`/tmp/dbg-after/log` 2026-09-23T06:23:19.345Z), 52
(`/tmp/verify-live/log` 2026-09-23T06:28:13.141Z). 109 − 54 overrides = 55
only if `frontend-design` leaves and `pydantic` was never attached.
55 − 4 plugin command names + `frontend-design` returning = 52.

## The 31,132 sessions

`72cf4f8d` (`-tmp-pd1`, 2026-09-23T06:04:53Z), `b5e18ceb` (`-tmp-pd6`,
2026-09-23T06:06:24Z), and `8a827a9c` (`-tmp-pd7`, 2026-09-23T06:07:37Z)
each record 31,132. Each `skill_listing` has skillCount 109 and 30,008
characters, the same shape as the later bare baseline `237a63dd`
(2026-09-23T06:20:59Z, cwd `/tmp/ab-before`, 31,134). The tool list JSON
is equal to that baseline. The prompt text that differs is the memory
directory path (`/tmp/pd1` versus `/tmp/ab-before`). These three ran the
pre-change config. They are not a plugins-off measurement, and they are
not the source of a 2-token plugin figure.

## The issue's 67,472

Session `d3920d3a-c2b7-4521-a118-700a400235b3` (cwd `/home/nish`,
2026-09-23T05:44:23Z, version 2.1.280) is the first request the issue
cites, and its first assistant usage sums to 67,472. It is not a bare
CLI probe.

- Instructions include `~/.claude/CLAUDE.md`, the three rules-library
  files also present on the bare CLI probes (`testing.md`,
  `design-workflow.md`, `coding-style.md`), and `MEMORY.md` (15,440
  characters in that instructions JSON). The `$HOME` CLI probe before the cut is
  38,217 with that same memory file. 38,217 − 31,134 = 7,083 of the
  gap between 67,472 and the bare CLI.
- `prompt_snapshot` tools: 26, versus 11 on the bare CLI probe. The 15
  extras sum to 85,708 characters of tool JSON. `Artifact` is 53,003 of
  those. The others are `AskUserQuestion`, `SendUserFile`, `SuggestSkills`,
  `ReadNotifications`, `mcp__ccd_session__*`, `mcp__visualize__*`,
  `mcp__terminal__read_terminal`, and one `mcp__1a59c906-…` server
  (`batch`, `guide`, `update`).
- `skillCount` is 131, versus 109 on the bare CLI probe and 103 on the
  `$HOME` CLI probe before the cut.

67,472 − 38,217 = 29,255. That remainder sits with the desktop tool
schemas and the larger skill list. The config deletion does not remove
`CLAUDE.md`, `MEMORY.md`, or those desktop tools. Long-session compaction
is issue #8396.

## 14-day zero-use scan

Re-run on 2026-09-24. Files under `~/.claude/projects` whose jsonl mtime
is on or after 2026-09-10 (365 files):

```
find ~/.claude/projects -name '*.jsonl' -newermt '2026-09-10' -print0 \
  | xargs -0 grep -h -o '"skill":"[^"]*"' | sort | uniq -c | sort -nr
```

```
     13 "skill":"last30days"
      4 "skill":"typesafe:typesafe-ai"
      2 "skill":"schedule"
      2 "skill":"loop"
      2 "skill":"last30days:last30days"
      2 "skill":"frontend-design"
      2 "skill":"design-it-twice"
```

No `skillOverrides` key appears. `frontend-design` appears twice and stays
enabled. `"skill":"code-review"` and `"skill":"commit-commands"` are absent.

`.claude.json` `skillUsage.lastUsedAt` inside the same window:
`last30days` (19, 2026-09-23), `last30days:last30days` (2, 2026-09-23),
`loop` (1, 2026-09-21), `schedule` (1, 2026-09-23), `frontend-design`
(1, 2026-09-21), `typesafe:typesafe-ai` (2, 2026-09-21),
`design-it-twice` (1, 2026-09-23). `artifact-design` (2026-08-24) and
`update-config` (2026-08-27) are older than 14 days and are not user-skill
directories, so they were not overridden.

`pluginUsage` on 2026-09-24: `code-review@claude-plugins-official` and
`commit-commands@claude-plugins-official` have usageCount 0 and
`lastUsedAt` 2026-08-10. They were set false. `frontend-design` stays
true because of the skillUsage hit and the two skill-field hits above.
`typesafe@inline` count 2, left true. `swift-lsp` and `typescript-lsp`
stay true: they are the editor LSP plugins. `context7@inline` count 9,
last used 2026-09-21, was already false in the backup and was left false.

The user command file `~/.claude/commands/code-review.md` is still on
disk. The live probe listing in `13709794` still contains the line
`- code-review: Code Review`. The removed line is the plugin id
`code-review:code-review`.

## Kept user skills (19)

Directories and skill symlinks under `~/.claude/skills/` that are not in
`skillOverrides`. `.stfolder` and `synced` are also there; they are not
skills. `synced` holds 15 nested `SKILL.md` files; the bare listing
names only `docs` from that set.

`blast-radius`, `clean`, `cloudflare`, `design`, `design-it-twice`,
`design-system`, `frontend-design`, `github-actions-minutes`, `last30days`,
`pause-safely`, `refactor`, `review`, `review-adjudication`,
`session-pickup`, `ship`, `unslop`, `vitest`, `why`, `wrangler`.

53 listed overrides + `pydantic` (overridden, not listed) + 19 kept = 73
skill entries.

## Disabled skills (54)

Each key in `skillOverrides` is `"off"`:

1. `accessibility`
2. `adev-writing-guide`
3. `agents-sdk`
4. `ai-sdk`
5. `angular-developer`
6. `ast-grep`
7. `backlog`
8. `bash-defensive-patterns`
9. `better-auth-best-practices`
10. `bootstrap`
11. `bun`
12. `check-pr`
13. `cloudflare-deploy`
14. `cloudflare-email-service`
15. `cloudflare-one`
16. `cloudflare-one-migrations`
17. `core-data-expert`
18. `design-inspiration-picker`
19. `design-polish`
20. `durable-objects`
21. `email-and-password-best-practices`
22. `fastmcp`
23. `finish-saas-product`
24. `next-best-practices`
25. `next-cache-components`
26. `next-upgrade`
27. `nodejs-backend-patterns`
28. `nodejs-best-practices`
29. `oxlint`
30. `php-pro`
31. `playwright-best-practices`
32. `pr-review`
33. `pydantic`
34. `reference-core`
35. `release-notes`
36. `sandbox-sdk`
37. `seo`
38. `shadcn`
39. `swift-concurrency`
40. `swift-testing-expert`
41. `swiftui-expert-skill`
42. `tailwind-css-patterns`
43. `tailwind-v4-shadcn`
44. `tdd-workflow`
45. `turborepo`
46. `turnstile-spin`
47. `typescript-advanced-types`
48. `vercel-composition-patterns`
49. `vercel-react-best-practices`
50. `vite`
51. `web-perf`
52. `workers-best-practices`
53. `xcode-build-orchestrator`
54. `zod`

## Left in place

`~/.claude/CLAUDE.md` and auto-memory stay. They are Nish's standing
documents, not a config deletion of an unused plugin or skill.

`enabledPlugins` still true: `swift-lsp@claude-plugins-official`,
`typescript-lsp@claude-plugins-official`,
`frontend-design@claude-plugins-official`, `typesafe@typesafe-ai`.
The backup had six true keys (those four plus the two flipped above) and
thirteen already false, including the names the issue listed as likely
contributors (`swift-lsp` and `typescript-lsp` among the six that were
true; `figma`, `claude-mem`, `superpowers`, `telegram`, `semgrep`,
`feature-dev`, `pr-review-toolkit`, and the rest already false).

encoded: 5 — the host file `~/.claude/settings.json` (`skillOverrides` 54×`"off"`, `enabledPlugins` `code-review` and `commit-commands` false). No lower rung can hold it: the file is outside the repo allowlist in README, so there is no structure to delete, no CI gate, no rule, and no skill that applies it, and a sync organ would be new glue (docs/ARCHITECTURE.md, correction ladder).
