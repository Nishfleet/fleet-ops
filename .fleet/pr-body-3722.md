## OpenRouter free tool-capable models as a free lane — part 1/3: wire the four :free seats

Child of #3316. Wires four OpenRouter `:free` catalog models as free-class seats so the fleet can use them at zero cost.

### What changed

- **`config/pi-models.json`** (new, now MANIFEST-managed → `~/.pi/agent/models.json`): registers `minimax/minimax-m3:free`, `z-ai/glm-5.2:free`, `nvidia/nemotron-3-ultra-550b-a55b:free` and `google/gemma-4-31b-it:free` under provider `openrouter` in `modelOverrides` with `cost 0`. All `apiKey` fields are `!command` refs — no literal secret in the repo.
- **`MANIFEST`**: adds `config/pi-models.json /home/nish/.pi/agent/models.json` (copy-installed, not symlinked — same reason as seat-caps.json, fleet-ops#2910).
- **`install.sh`**: copy-installs `config/pi-models.json` so live pi model config does not silently change with the git working tree.
- **`config/seat-caps.json`**: adds the four seats as `class free`, `cap 2` each, `max_probe_ceiling 3`, each with a dated `_note` citing #3722. Provider `openrouter` cap restored `0 -> 4` so the `:free` lanes are not blocked by the paid-credits park (the paid `deepseek/deepseek-v4-flash-0731` seat stays model-cap 0, product_only, daily_spend_cap_usd 3 from #3724). Yield-gated by #3250/#3251 like every seat (provisional yield 0.5 until 20 measured sessions).

### Verification

`pi --list-models` (live catalog) shows all four wired with cost 0:

```
openrouter          google/gemma-4-31b-it:free                          262.1K   32.8K    yes       yes
openrouter          minimax/minimax-m3:free                             1.0M     65.5K    yes       yes
openrouter          nvidia/nemotron-3-ultra-550b-a55b:free              1M       65.5K    yes       no
openrouter          z-ai/glm-5.2:free                                   256K     230.4K   yes       no
```

`enumerate_seats` (seat-lib) emits all four:

```
openrouter	minimax/minimax-m3:free	0	1
openrouter	z-ai/glm-5.2:free	0	1
openrouter	nvidia/nemotron-3-ultra-550b-a55b:free	0	1
openrouter	google/gemma-4-31b-it:free	0	1
```

`pick_seat` offers the openrouter free seats in the value-order:

```
pick_seat: value-order (product,light): openrouter/minimax/minimax-m3:free@y=0.500000,v=500.000000 openrouter/nvidia/nemotron-3-ultra-550b-a55b:free@y=0.500000,v=500.000000 ...
```

Required tests all pass together (`PI_SEAT_LIB_CHECK_TRANSPORT=0`):

```
bash tests/seat-caps-citation.test.sh   -> PASS
bash tests/seat-lib-aimd.test.sh        -> PASS
bash tests/fleet-token-economy.test.sh  -> PASS
```

Also green: `manifest-shape`, `seat-lib`, `seat-lib-degraded`, `seat-lib-org-reserve`, `entitled-wired-canary`, `fleet-free-roster-canary`, `fleet-cline-glm53-canary`.

### run-proof

- `pi --list-models` live catalog lists the four `:free` models (output above).
- `enumerate_seats` + `pick_seat` from `lib/seat-lib.sh` emit and offer the four seats (output above).
- Three required tests + seven related tests green (output above).

net-positive-because: the diff is net-positive (666 insertions) because it adds the repo-managed `config/pi-models.json` (the full pi model catalog, ~627 lines) that becomes the source of truth for `~/.pi/agent/models.json` — a one-time migration of a previously hand-edited live file into MANIFEST control. The four `:free` seat rows themselves are ~24 lines. This is the durable, self-limiting form of the wiring: future seat wires edit the repo copy, not the live file.

Closes #3722
