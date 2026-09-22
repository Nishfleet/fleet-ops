#!/usr/bin/env python3
"""fleet-ops#7744 — router group hygiene guard for config/litellm-proxy.yaml.

The issue's first defect class: a model_list rung routed `senior` (and
worker fallbacks) at a deployment that cannot return tool calls — the
`worker-capable-devin` CustomLLM bridge, an agent-in-a-box that answers
final prose and exits the worker run clean with zero deliverable.

What this pins mechanically (the proof discipline — "only deployments that
returned finish_reason=tool_calls on real packets" — stays the bench
process, fleet-ops#7761's standing rule):

  1. No model_list rung points at an agent-in-a-box host: api.devin.ai,
     windsurf.com, server.codeium.com, api2.cursor.sh — the #4263/#6133
     verdict is that these expose no /v1/chat/completions wire.
  2. Every model_list rung is an OpenAI-compatible chat deployment:
     litellm_params.model starts with "openai/" and model_info.mode is
     "chat" — the only surface proven to carry tool_calls end to end.
  3. The worker groups (worker-cheap, worker-capable) are non-empty and
     fall back to each other (fleet-ops#4404); every fallback target names
     a group that exists in model_list.
  4. senior exists and follows the same host/provider rules — it consumes
     prose, but an agent-in-a-box rung is never a legal senior seat.
  5. Nothing in model_list shares a (model, api_base) identity with a
     benched: entry — a benched rung still routed is a silent restore.

Run: python3 tests/litellm-router-groups.test.py
"""
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
CFG = ROOT / 'config' / 'litellm-proxy.yaml'
FAILS = []

# Hosts proven to expose no OpenAI-compatible inference wire — Devin and
# Windsurf serve agent sessions, not chat completions (fleet-ops#4263,
# #6133, #7761).
AGENT_HOSTS = ('api.devin.ai', 'windsurf.com', 'server.codeium.com',
               'api2.cursor.sh')
WORKER_GROUPS = ('worker-cheap', 'worker-capable')


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


def main():
    cfg = yaml.safe_load(CFG.read_text())
    model_list = cfg.get('model_list') or []
    benched = cfg.get('benched') or []
    groups = {}
    for dep in model_list:
        groups.setdefault(dep.get('model_name'), []).append(dep)

    check(bool(model_list), 'model_list is non-empty')

    for dep in model_list:
        p = dep.get('litellm_params') or {}
        name = '%s (%s)' % (dep.get('model_name'),
                            (dep.get('model_info') or {}).get('id'))
        base = str(p.get('api_base') or '')
        check(not any(h in base for h in AGENT_HOSTS),
              '%s api_base %s is not an agent-in-a-box host' % (name, base))
        check(str(p.get('model') or '').startswith('openai/'),
              '%s uses an openai/-compatible provider (got %r)'
              % (name, p.get('model')))
        check((dep.get('model_info') or {}).get('mode') == 'chat',
              '%s model_info.mode is chat' % name)

    for g in WORKER_GROUPS + ('senior',):
        check(groups.get(g), 'group %s has at least one deployment' % g)

    fb = {}
    for ent in (cfg.get('router_settings') or {}).get('fallbacks') or []:
        fb.update(ent)
    for src, targets in fb.items():
        check(src in groups, 'fallback source %s is a real group' % src)
        for t in targets:
            check(t in groups, 'fallback %s -> %s targets a real group'
                  % (src, t))
    check(fb.get('worker-cheap') == ['worker-capable']
          and fb.get('worker-capable') == ['worker-cheap'],
          'worker groups fall back to each other (fleet-ops#4404)')
    # A worker group must never fall back to a prose-only lane: every
    # fallback target of a worker group is itself a worker group.
    for g in WORKER_GROUPS:
        for t in fb.get(g, []):
            check(t in WORKER_GROUPS,
                  'worker fallback %s -> %s stays inside worker groups'
                  % (g, t))

    bench_ids = set()
    for b in benched:
        p = b.get('litellm_params') or {}
        bench_ids.add((p.get('model'), p.get('api_base')))
    for dep in model_list:
        p = dep.get('litellm_params') or {}
        check((p.get('model'), p.get('api_base')) not in bench_ids,
              'routed rung %s @ %s is not still in the benched: block'
              % (p.get('model'), p.get('api_base')))

    if FAILS:
        print('FAIL: litellm-router-groups (%d failed check(s))'
              % len(FAILS), file=sys.stderr)
        return 1
    print('PASS: litellm-router-groups')
    return 0


if __name__ == '__main__':
    sys.exit(main())
