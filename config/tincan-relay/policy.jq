# Renders the tincan relay's approval policy from one agent roster
# (fleet-ops#9979). The hand-made ~/.local/state/tincan-relay/approval.json is
# what this replaces: it was written by hand on the box, so nothing in the repo
# said what the gate was, and a new agent silently reached every other agent.
#
# Stock tool only, no glue: jq, the JSON processor, driven by this program file.
# The policy is secret-free (agent names and two settings), so it is generated
# in the repo and installed by the host playbook, never hand-made.
#
#   jq -j --indent 1 -n --rawfile roster agents.txt -f policy.jq
#
# -j (join output) matters: without it jq appends a newline the hand-made file
# did not have. The render is byte-for-byte the file that ran from 2026-10-22.
#
# Each agent we own gets a gate that holds a request whose chain includes any
# agent outside the roster, so an outside helper or joiner is held by default
# and a request between our own agents goes through. `relay` is in every list
# because the relay itself is a hop in the chain. notify names where a held
# request is announced and hold_ttl how long it waits for an answer.
($roster | split("\n") | map(select(startswith("#") | not)) | map(select(test("\\S")))) as $agents
| ($agents + ["relay"] | sort | unique) as $allowed
| {gate: ($agents | map({key: ., value: {unless: $allowed}}) | from_entries), notify: "hermes", hold_ttl: "24h"}
