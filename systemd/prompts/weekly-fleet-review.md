# Weekly Fleet Review (WFR) — Model Discovery + Senior Review

This prompt runs weekly (Sun 04:30 IST) via `agent-cron-run weekly-fleet-review`.

It performs two duties:
1. **Model discovery**: fetch latest pricing and capabilities from models.dev and OpenRouter, filter to tool-capable models that are either free or cheaper than the current metered median, and write `config/model-candidates.json`.
2. **Existing WFR duties** (if any): other fleet health/scorecard checks (keep existing steps; this prompt augments them).

## Model discovery steps

### 1. Run last30days research
Run the `last30days` skill (non‑interactive) to capture current community sentiment on best‑value open‑weight models for autonomous coding agents.
```bash
mkdir -p ~/Documents/Last30Days
last30days --agent "best value open-weight models for autonomous coding agents: free tiers, rate limits, provider routing" --emit=compact --save-dir ~/Documents/Last30Days
```

### 2. Fetch catalogues
Fetch the machine‑readable catalogues:
```bash
curl -s https://models.dev/api.json -o /tmp/models_dev.json
curl -s https://openrouter.ai/api/v1/models -o /tmp/openrouter_models.json
```

### 3. Parse and filter
Use the following Python script to:
- Extract from both sources: `provider`, `model`, `pricing` (price_in, price_out), `context_window`, `supports_tools` (or `tools` flag).
- Classify each as `free` (price_in == 0), `prepaid` (provider‑specific prepaid plans), or `metered` (per‑token).
- Only keep models where `supports_tools == true`.
- Compute the median `price_in` among all metered models (excluding free).
- Include models that are `free` OR have `price_in < median`.
- Output `config/model-candidates.json` with the schema:
```json
{
  "provider": "...",
  "model": "...",
  "class": "free|prepaid|metered",
  "price_in": 0.0,
  "price_out": 0.0,
  "tools": true,
  "ctx": 0,
  "source": "models.dev|openrouter",
  "seen_at": "2026-09-05T..."
}
```

Run the script (inline):
```python
import json, statistics, time, os
from pathlib import Path

def load_json(f):
    with open(f) as fp:
        return json.load(fp)

md = load_json('/tmp/models_dev.json')
or = load_json('/tmp/openrouter_models.json')

# Normalise entries
models = []
for entry in md.get('models', []):
    models.append({
        'provider': entry.get('provider'),
        'model': entry.get('name'),
        'price_in': entry.get('pricing', {}).get('input', 0.0),
        'price_out': entry.get('pricing', {}).get('output', 0.0),
        'ctx': entry.get('context_window', 0),
        'tools': entry.get('supports_tools', False),
        'source': 'models.dev'
    })
for entry in or.get('data', []):
    models.append({
        'provider': entry.get('provider', {}).get('name', 'openrouter'),
        'model': entry.get('id'),
        'price_in': entry.get('pricing', {}).get('input', 0.0),
        'price_out': entry.get('pricing', {}).get('output', 0.0),
        'ctx': entry.get('context_length', 0),
        'tools': entry.get('supports_tools', False),
        'source': 'openrouter'
    })

# Filter tool-capable
tool_models = [m for m in models if m['tools']]

# Separate free and metered
free = [m for m in tool_models if m['price_in'] == 0]
metered = [m for m in tool_models if m['price_in'] > 0]

# Compute median
if metered:
    prices = sorted([m['price_in'] for m in metered])
    median = statistics.median(prices)
else:
    median = float('inf')

# Filter: free OR cheaper than median
candidates = [m for m in tool_models if m['price_in'] == 0 or (m['price_in'] > 0 and m['price_in'] < median)]

# Add class and seen_at
now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
for c in candidates:
    c['class'] = 'free' if c['price_in'] == 0 else 'metered'  # prepaid handled by provider
    c['seen_at'] = now

# Write to config/
config_dir = Path(os.environ.get('WORKDIR', '/home/nish/workspaces/tooling/fleet-ops-deploy-clone')) / 'config'
config_dir.mkdir(exist_ok=True)
with open(config_dir / 'model-candidates.json', 'w') as f:
    json.dump(candidates, f, indent=2)

print(f'DIGEST:: Model discovery complete: {len(candidates)} candidates written to config/model-candidates.json')
```

### 4. Verify
Check that the file exists and has the required fields.

## Existing WFR duties (if any)
If there are other weekly review tasks (e.g., health checks, scorecards), they continue here. This prompt is additive; the above discovery step is now part of the weekly run.

## Output
The script prints a `DIGEST::` line which `agent-cron-run` will pick up and send via `hermes` (or fall back to the log file).