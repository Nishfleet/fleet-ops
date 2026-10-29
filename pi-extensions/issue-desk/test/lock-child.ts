import { mkdir } from "node:fs/promises";
import { withStateLock } from "../src/cap.ts";

const [dir, tag, holdMs] = process.argv.slice(2);

await mkdir(dir, { recursive: true });
await withStateLock(dir, async (state) => {
  const before = state.records.length;
  await new Promise((resolve) => setTimeout(resolve, Number(holdMs)));
  await state.append({
    at: new Date().toISOString(),
    request_id: tag,
    repo: "0509",
    url: `https://github.com/Nishfleet/0509/issues/${tag}`,
  });
  process.stdout.write(`${JSON.stringify({ tag, before })}\n`);
});
