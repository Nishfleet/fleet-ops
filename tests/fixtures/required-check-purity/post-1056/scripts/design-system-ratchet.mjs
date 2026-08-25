#!/usr/bin/env node
// Fixture: 0509 design-system ratchet AFTER issue 1056.
// Monotonic: a count strictly above its ceiling fails. Counts below pass
// without editing the shared JSON. Tightening happens out of band on main.
import { readFileSync } from "node:fs";
import { join } from "node:path";

const ROOT = new URL("..", import.meta.url).pathname;
const CEILING_PATH = join(ROOT, "docs", "design-system-ratchet.json");

export function readCeilings() {
  return JSON.parse(readFileSync(CEILING_PATH, "utf8"));
}

const counts = { "raw-hex-color": 250 };
const ceilings = readCeilings();
const violations = [];
const ceilingKeys = Object.keys(ceilings).sort();
const expectedKeys = Object.keys(counts).sort();
if (JSON.stringify(ceilingKeys) !== JSON.stringify(expectedKeys)) {
  violations.push(
    "ceiling keys and BANNED_MARKERS disagree — a marker cannot be exempted by deleting its key",
  );
}
for (const marker of Object.keys(counts)) {
  const ceiling = ceilings[marker] ?? 0;
  // Monotonic: a count STRICTLY ABOVE its ceiling is new debt and fails.
  // A count at or below its ceiling passes — sweeping legacy debt does not
  // require editing the shared JSON in the same PR.
  if (counts[marker] > ceiling) {
    violations.push(`${marker}: count ${counts[marker]} exceeds ceiling ${ceiling}`);
  }
}
if (violations.length > 0) {
  console.error("Design-system ratchet violations (new legacy debt):");
  for (const violation of violations) console.error(`  ${violation}`);
  process.exit(1);
}
console.log("Ratchet clean.");
