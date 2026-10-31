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
    OPENAI_API_KEY: ${{ secrets.LITELLM_PILOT_KEY }}
  config: |
    {"model": {"api": "openai-completions"}}
network:
  allowed: [defaults, python, node, llm.nish.sh]
timeout-minutes: 30
safe-outputs:
  create-pull-request:
    title-prefix: "[pilot] "
  add-comment:
---

# Fix the labelled issue

Fix issue #${{ github.event.issue.number }} in one small pull request. Follow AGENTS.md, run the tests the change touches, and name the source behind each non-trivial choice in the PR body. If the issue cannot be fixed safely, add one comment saying why instead.
