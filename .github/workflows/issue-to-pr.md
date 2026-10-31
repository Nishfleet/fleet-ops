---
description: Pilot (fleet-ops#10932) - GitHub's agentic workflow turns a labelled issue into one small PR.
on:
  issues:
    types: [labeled]
    names: [pilot-stock]
permissions:
  contents: read
  issues: read
  pull-requests: read
engine:
  id: pi
  model: openai/pilot
  model-provider: openai
  env:
    OPENAI_BASE_URL: https://llm.nish.sh/v1
    OPENAI_API_KEY: ${{ secrets.PILOT_GATEWAY_TOKEN }}
  config: |
    {"model": {"api": "openai-completions"}}
sandbox:
  agent:
    targets:
      openai:
        # The secret is a Cloudflare Access service token, sent raw in one header
        # (fleet-ops#11311); the edge swaps in the pilot router key.
        auth-header: Authorization
network:
  allowed: [defaults, python, node, llm.nish.sh]
timeout-minutes: 30
safe-outputs:
  # The fleet worker App, not GITHUB_TOKEN: its PRs start CI and review, and its
  # comments are not an approver's (fleet-ops#11311).
  github-app:
    client-id: "4728578"
    private-key: ${{ secrets.NISHFLEET_WORKER_PRIVATE_KEY }}
  create-pull-request:
    title-prefix: "[pilot] "
  add-comment:
    target: triggering
  # gh-aw runs pi's threat detection on the Copilot CLI, which this fleet does not
  # use. The PR still passes CI and the fleet's own review before any merge.
  threat-detection:
    engine: false
---

# Fix the labelled issue

Fix issue #${{ github.event.issue.number }} in one small pull request. Follow AGENTS.md, run the tests the change touches, and name the source behind each non-trivial choice in the PR body. If the issue cannot be fixed safely, add one comment saying why instead.
