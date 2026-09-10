#!/usr/bin/env node
// Fixture: 0509 design-system ratchet BEFORE issue 1056.
// Exact equality against docs/design-system-ratchet.json. The PR must run
// --update on that shared file to pass. This is the shape the purity lint
// must flag.
import { readFileSync } from "node:fs";
import { join } from "node:path";

const ROOT = new URL("..", import.meta.url).pathname;
const CEILING_PATH = join(ROOT, "docs", "design-system-ratchet.json");

export function readCeilings() {
  return JSON.parse(readFileSync(CEILING_PATH, "utf8"));
}

const counts = { "raw-hex-color": 262 };
const ceilings = readCeilings();
const violations = [];
for (const marker of Object.keys(counts)) {
  const ceiling = ceilings[marker] ?? 0;
  // Exact match: an increase is new debt; a decrease without --update is a
  // silent slack refill waiting to happen; a hand-raised ceiling fails
  // because the count no longer equals it.
  if (counts[marker] !== ceiling) {
    violations.push(
      `${marker}: count ${counts[marker]} !== ceiling ${ceiling} (run --update in this PR)`,
    );
  }
}
if (violations.length > 0) {
  console.error("Design-system ratchet violations (new legacy debt):");
  for (const violation of violations) console.error(`  ${violation}`);
  process.exit(1);
}
