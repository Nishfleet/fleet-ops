import importlib.util
import sys
from datetime import datetime, timedelta, timezone

spec = importlib.util.spec_from_file_location("ce", "/home/nish/workspaces/agent-worktrees/issue-fleet-ops-3052/lib/canary-effectiveness.py")
mod = importlib.util.module_from_spec(spec)
sys.modules["ce"] = mod
spec.loader.exec_module(mod)

end = datetime.now(timezone.utc)
start = end - timedelta(days=mod.WINDOW_DAYS)
events, incidents = mod.collect_live(start, end)
print(f"events={len(events)} incidents={len(incidents)}")
print("\n=== EVENTS (first 20) ===")
for e in events[:20]:
    print(e)
print("\n=== ORGAN first-observed (since) ===")
for o in mod.ORGANS:
    org_events = [e for e in events if e.organ == o.name]
    since = mod.observe_since(org_events)
    print(f"{o.name}: since={since} ({datetime.fromtimestamp(since, tz=timezone.utc) if since else None}) events={len(org_events)} runs={sum(1 for e in org_events if e.kind=='run')} fails={sum(1 for e in org_events if e.kind=='failure')}")
print("\n=== INCIDENTS ===")
for i in incidents:
    dt = datetime.fromtimestamp(i.ts, tz=timezone.utc)
    print(f"{i.repo}#{i.number} {dt.isoformat()} labels={i.labels} title={i.title}")
print("\n=== STATS ===")
for s in mod.compute_all(events, incidents):
    print(s)
