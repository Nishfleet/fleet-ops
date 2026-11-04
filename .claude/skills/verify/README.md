# verify skill

What: a project skill that applies the host play in a throwaway systemd container and proves one feature with kept evidence. Agents load it from `.claude/skills/verify/` (Claude Code, https://code.claude.com/docs/en/skills) and `.agents/skills/verify` (a link, for Pi and other agents).

Keep the map honest: run `/maintain-verification-skill` after a change that adds, moves or removes a feature (a new unit, a new task file, a retired area). It reads each feature's source, drives every feature in one live session, and opens at most one PR of proven corrections.

Switch it off: delete `.claude/skills/verify/` and `.agents/skills/verify`. Nothing else reads them.
