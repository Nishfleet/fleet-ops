import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { LOCK_FILE, reclaimStale } from "../src/cap.ts";

const [dir, token, observed] = process.argv.slice(2);

await mkdir(dir, { recursive: true });
const reclaimed = await reclaimStale(dir, token, observed);
if (reclaimed) {
  await writeFile(join(dir, LOCK_FILE), `${JSON.stringify({ token, pid: process.pid })}\n`, "utf8");
}
process.stdout.write(`${JSON.stringify({ tag: token, reclaimed })}\n`);
