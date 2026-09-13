#!/usr/bin/env bash
# p14-main live proof (fleet-ops#6159): one honest production verdict.
set -u
cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-6159
bash measure.sh 2>/dev/null | grep -E '^p14-main' > .fleet/p14-main-6159.deliverable
