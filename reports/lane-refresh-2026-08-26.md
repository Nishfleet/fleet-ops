# Lane refresh evidence (fleet-ops#384)

Probed 2026-08-26T16:35:25Z. No API keys in this file.

## Paid flash on OpenRouter and Zenmux

Live `/models` prices, USD per million tokens:

| Model | OpenRouter in/out | Zenmux in/out | In Pi catalog? |
| --- | ---: | ---: | --- |
| Qwen 3.8 flash | slug missing | slug missing | no |
| GLM 5.3 flash (`z-ai/glm-5.3-flash`) | 0.075 / 0.250 | 0.075 / 0.250 | no (`pi --list-models glm-5.3-flash` empty) |
| DeepSeek V4 Flash 0731 | 0.060 / 0.120 | n/a (zenmux `deepseek/deepseek-v4-flash` is 0.22 / 0.66) | yes |

Qwen 3.8 closest hits are not flash: `qwen/qwen3.8-27b` is $0.425/$2.55 (OpenRouter) and $0.50/$3.00 (Zenmux). Not wired.

`~deepseek/deepseek-v4-flash-latest` is cheaper ($0.03/$0.075) but it is an auto-router id, not a pinned slug. Not wired.

Quality: `fleet2/eval/LEAGUE.md` (2026-08-20, 3022 results). `or-deepseek-v4-flash-0731` scores 0.646 on 171 tasks. GLM 5.3 flash has no league row (published 2026-08-26). Among the three named models that exist, 0731 is cheapest and the only one with a quality bench plus a live Pi slug.

Zenmux DeepSeek V4 Flash is 3.7× OpenRouter input, 5.5× output. Empty zenmux allowlist.

Winner wired: `openrouter` / `deepseek/deepseek-v4-flash-0731` at provider cap 2 (already measured). Pi transport: `pi --list-models deepseek-v4-flash` lists that slug on openrouter.

OpenRouter credits at probe: total_credits 90.06, total_usage 34.61269796 (control for the CommandCode spawn below).

## Free MiniMax M3 on CommandCode / OpenCode

CommandCode catalog has both `minimax/minimax-m3-free` (free-tier form) and `MiniMaxAI/MiniMax-M3` (likely metered). Only the `-free` slug is allowlisted.

Live spawn 2026-08-26T16:49:19Z:

- POST `https://api.commandcode.ai/provider/v1/chat/completions`
- model `minimax/minimax-m3-free`
- HTTP 200 in 9.8s, reply `pong`
- usage: 173 prompt / 1 completion tokens, 142 cached
- no `cost` / `billing` / `credit` fields on the body

CommandCode has no usage API (`/credits`, `/usage`, `/me` all miss). Meter check is the spawn body plus OpenRouter credits as a control (must not move).

OpenRouter credits 5.5 minutes later (2026-08-26T16:54:59Z): total_credits 90.06, total_usage 34.61269796, delta 0. The CommandCode spawn did not leak onto a metered OpenRouter seat.

Pi transport after adding the slug to `~/.pi/agent/models.json`: `pi --print --provider commandcode --model minimax/minimax-m3-free` returned `pong`.

Live `pick_seat` against this PR's seat-caps plus the live catalog, with prepaid seats tried, returned `commandcode/minimax/minimax-m3-free`.

OpenCode catalog has no MiniMax M3. Live probes:

- `minimax-m3-free`, `minimax/minimax-m3`, `MiniMax-M3`, `MiniMaxAI/MiniMax-M3` → ModelError not supported
- `minimax-m3` → CreditsError insufficient balance (would bill)

OpenCode stays cap=0. That M3 path does not share the DeepSeek-on-OpenCode monthly wall; it is a separate paid id and is not wired.

Direct `minimax` / `MiniMax-M3` stays the existing metered last-resort. Not double-wired onto CommandCode.
