# compound-engineering plugin update — 2026-10-25

Receipt for fleet-ops#9734. The compound-engineering plugin is the Claude Code
plugin that runs this fleet's document reviews. One of its steps sends the
reviewed document to a second model, called the peer. That peer was reading the
document from disk instead of from the text sent with it, so a denied read
ended the run with no review file.

**Why the earlier update did nothing.** Refreshing the plugin marketplace cache
does not move the release that the marketplace entry is pinned to. The pin has
to move first, and the command that adds a marketplace refuses one whose source
does not match the pin. That is what made the earlier update a silent no-op.

- The installed plugin is now release 3.32.1. It is above 3.30.5 and it
  contains the upstream fix, and the fix line is present in the installed
  review script.
- Three consecutive cross-model review runs through the opencode peer, on one
  ~2 KB document, each wrote the adversarial-lens review file. Each file
  passes the findings-schema check. OpenCode is the command-line tool the peer
  runs in.
- The opencode peer route needs `npx` on PATH for its transport preflight, and
  `npx` is not on the default PATH here. Without it the run writes no review
  file and still exits 0. Issue #10278 tracks that.
- The review script writes no file at all when no host route is resolved
  before it starts, and it marks every run's independence unverified while the
  host model family is unattested. The second half is upstream behaviour, so
  no follow-up is filed here.
