import { randomUUID } from "node:crypto";
import { appendFile, link, mkdir, open, readFile, rename, unlink } from "node:fs/promises";
import { join } from "node:path";

export const DAY_MS = 24 * 60 * 60 * 1000;

export const STATE_FILE = "filed.jsonl";

export const LOCK_FILE = "filed.lock";

// A filing holds the lock across two gh calls, each bounded by the 120 s
// execFile timeout, plus the file appends. 300 s is past any live hold, so a
// lock that old means its holder is gone and the rename-steal below may take
// it. The lock wait (240 s) is shorter, so a waiter gives up before it could
// ever steal a lock a live holder still owns.
export const LOCK_STALE_MS = 300_000;

export const LOCK_WAIT_MS = 240_000;

export const LOCK_POLL_MS = 100;

export interface Filed {
  at: string;
  request_id: string;
  repo: string;
  url: string;
}

export const capFile = (dir: string): string => join(dir, STATE_FILE);

export const lockFile = (dir: string): string => join(dir, LOCK_FILE);

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

// One request may leave several records (the claim before gh runs and the
// success after), and a create that failed leaves a claim with an empty url.
// Both count: the claim is written before gh runs, so gh may still have created
// the issue. Distinct request ids in the window, so one filing counts once.
export const countRecent = (filed: readonly Filed[], now: number): number => {
  const recent = new Set<string>();
  for (const entry of filed) {
    const at = Date.parse(entry.at);
    if (Number.isFinite(at) && now - at < DAY_MS) recent.add(entry.request_id);
  }
  return recent.size;
};

export interface CapState {
  records: Filed[];
  append: (record: Filed) => Promise<void>;
}

const parseToken = (raw: string): string | null => {
  try {
    const value = JSON.parse(raw) as { token?: unknown };
    return typeof value.token === "string" ? value.token : null;
  } catch {
    return null;
  }
};

const readOwnerToken = async (path: string): Promise<string | null> => {
  try {
    return parseToken(await readFile(path, "utf8"));
  } catch {
    return null;
  }
};

const inspectLock = async (
  dir: string,
): Promise<{ token: string | null; stale: boolean } | null> => {
  const handle = await open(lockFile(dir), "r").catch((error: NodeJS.ErrnoException) => {
    if (error?.code === "ENOENT") return null;
    throw error;
  });
  if (handle === null) return null;
  try {
    const info = await handle.stat();
    return {
      token: parseToken(await handle.readFile("utf8")),
      stale: Date.now() - info.mtimeMs > LOCK_STALE_MS,
    };
  } finally {
    await handle.close();
  }
};

export const reclaimStale = async (
  dir: string,
  token: string,
  observed: string | null,
): Promise<boolean> => {
  const lock = lockFile(dir);
  const displaced = join(dir, `${LOCK_FILE}.${token}.${randomUUID()}.displaced`);
  try {
    await rename(lock, displaced);
  } catch {
    return false;
  }
  if ((await readOwnerToken(displaced)) === observed) {
    await unlink(displaced).catch(() => undefined);
    return true;
  }
  try {
    await link(displaced, lock);
  } catch (error) {
    await unlink(displaced).catch(() => undefined);
    throw new Error(
      `the issue-desk state lock in ${dir} was taken by another filing while a stale lock was being put back, so nothing was filed and two filings may be running. Try the request again in a minute.`,
      { cause: error },
    );
  }
  await unlink(displaced).catch(() => undefined);
  return false;
};

const waitOrGiveUp = async (deadline: number, dir: string): Promise<void> => {
  if (Date.now() >= deadline) {
    throw new Error(
      `the issue-desk state lock in ${dir} is held by another filing; try the request again in a minute`,
    );
  }
  await new Promise((resolve) => setTimeout(resolve, LOCK_POLL_MS));
};

const acquire = async (dir: string, token: string): Promise<void> => {
  const lock = lockFile(dir);
  const deadline = Date.now() + LOCK_WAIT_MS;
  for (;;) {
    try {
      const handle = await open(lock, "wx", 0o600);
      await handle.writeFile(`${JSON.stringify({ token, pid: process.pid })}\n`, "utf8");
      await handle.close();
      return;
    } catch (error) {
      if ((error as NodeJS.ErrnoException)?.code !== "EEXIST") throw error;
    }
    const held = await inspectLock(dir);
    if (held === null || !held.stale) {
      await waitOrGiveUp(deadline, dir);
      continue;
    }
    if (await reclaimStale(dir, token, held.token)) continue;
    await waitOrGiveUp(deadline, dir);
  }
};

export const withStateLock = async <T>(
  dir: string,
  body: (state: CapState) => Promise<T>,
): Promise<T> => {
  await mkdir(dir, { recursive: true });
  const lock = lockFile(dir);
  const token = randomUUID();
  await acquire(dir, token);
  try {
    const raw = await readFile(capFile(dir), "utf8").catch(() => "");
    const records = parseFiled(raw);
    return await body({
      records,
      append: async (record: Filed) => {
        await appendFile(capFile(dir), `${JSON.stringify(record)}\n`, "utf8");
      },
    });
  } finally {
    const owner = await readOwnerToken(lock);
    if (owner === token) await unlink(lock).catch(() => undefined);
  }
};
