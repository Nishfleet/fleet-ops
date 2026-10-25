# compound-engineering plugin update — 2026-10-25

Receipt for fleet-ops#9734. The cross-model doc review peer was reading the
reviewed document from disk instead of from the text embedded in its prompt, so
a denied read ended the run with no artifact.

- The installed plugin moved to a release above 3.30.5 that contains the
  upstream fix, and the fix line is present in the installed review script.
- Three consecutive cross-model doc review runs through the opencode peer on
  one ~2 KB document each wrote the adversarial artifact, and each artifact
  passes the findings-schema check.
- Refreshing the plugin marketplace cache does not move the release that the
  marketplace entry is pinned to, so a plugin update has to move that pin
  first. That pin is what made the earlier update a silent no-op.
- The opencode peer route needs `npx` on PATH for its transport preflight, and
  the review script writes no artifact at all while the host serving family is
  unattested.

Detail is kept off this public repo.
