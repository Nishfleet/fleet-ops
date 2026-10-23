import { appendFile, mkdir, readFile } from "node:fs/promises";
import { join } from "node:path";

export const DAY_MS = 24 * 60 * 60 * 1000;

export const STATE_FILE = "filed.jsonl";

export interface Filed {
  at: string;
  request_id: string;
  repo: string;
  url: string;
}

export const capFile = (dir: string): string => join(dir, STATE_FILE);

export const parseFiled = (raw: string): Filed[] =>
  raw
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line !== "")
    .flatMap((line) => {
      try {
        const value = JSON.parse(line) as Partial<Filed>;
        return typeof value?.at === "string" && typeof value?.request_id === "string"
          ? [value as Filed]
          : [];
      } catch {
        return [];
      }
    });

export const countRecent = (filed: readonly Filed[], now: number): number =>
  filed.filter((entry) => {
    const at = Date.parse(entry.at);
    return entry.url !== "" && Number.isFinite(at) && now - at < DAY_MS;
  }).length;

export interface CapState {
  records: Filed[];
  append: (record: Filed) => Promise<void>;
}

let queue: Promise<unknown> = Promise.resolve();

export const withStateLock = <T>(
  dir: string,
  body: (state: CapState) => Promise<T>,
): Promise<T> => {
  const next = queue.then(async () => {
    await mkdir(dir, { recursive: true });
    const path = capFile(dir);
    const raw = await readFile(path, "utf8").catch(() => "");
    const records = parseFiled(raw);
    return body({
      records,
      append: async (record: Filed) => {
        await appendFile(path, `${JSON.stringify(record)}\n`, "utf8");
      },
    });
  });
  queue = next.catch(() => undefined);
  return next;
};
