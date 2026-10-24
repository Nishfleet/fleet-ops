import { spawn } from "node:child_process";
import { mkdtemp, readFile, unlink, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { LOCK_FILE, capFile, countRecent, lockFile, parseFiled, withStateLock } from "../src/cap.ts";

const CHILD = fileURLToPath(new URL("./lock-child.ts", import.meta.url));

const runChild = (
  dir: string,
  tag: string,
  holdMs: number,
): Promise<{ code: number; lines: string[] }> =>
  new Promise((resolve, reject) => {
    const child = spawn(
      process.execPath,
      ["--experimental-strip-types", CHILD, dir, tag, String(holdMs)],
      { stdio: ["ignore", "pipe", "pipe"] },
    );
    let out = "";
    child.stdout.on("data", (chunk: Buffer) => {
      out += chunk.toString();
    });
    child.stderr.on("data", (chunk: Buffer) => {
      out += chunk.toString();
    });
    child.on("error", reject);
    child.on("close", (code) => resolve({ code: code ?? -1, lines: out.trim().split("\n") }));
  });

const NOW = 1_800_000_000_000;

describe("withStateLock", () => {
  it("serializes two child processes on one lockfile", async () => {
    const dir = await mkdtemp(`${tmpdir()}/issue-desk-lock-`);
    const first = runChild(dir, "child-1", 400);
    const second = runChild(dir, "child-2", 0);
    const [one, two] = await Promise.all([first, second]);
    expect(one.code, one.lines.join("\n")).toBe(0);
    expect(two.code, two.lines.join("\n")).toBe(0);
    const seen = [JSON.parse(one.lines.at(-1)!), JSON.parse(two.lines.at(-1)!)] as Array<{
      tag: string;
      before: number;
    }>;
    expect(seen.map((line) => line.before).sort()).toEqual([0, 1]);
    const records = parseFiled(await readFile(capFile(dir), "utf8"));
    expect(records.map((record) => record.request_id).sort()).toEqual(["child-1", "child-2"]);
  }, 30_000);

  it("recovers a stale lock left by a dead holder", async () => {
    const dir = await mkdtemp(`${tmpdir()}/issue-desk-stale-`);
    const lock = lockFile(dir);
    await writeFile(lock, '{"token":"dead","pid":1}\n', "utf8");
    const old = new Date(Date.now() - 10 * 60_000);
    await utimes(lock, old, old);
    const result = await withStateLock(dir, async (state) => {
      await state.append({
        at: new Date().toISOString(),
        request_id: "after-stale",
        repo: "0509",
        url: "u-1",
      });
      return "ran";
    });
    expect(result).toBe("ran");
    await expect(readFile(lock, "utf8")).rejects.toThrow();
    const records = parseFiled(await readFile(capFile(dir), "utf8"));
    expect(records.map((record) => record.request_id)).toEqual(["after-stale"]);
  });

  it("leaves a successor's lock alone at release", async () => {
    const dir = await mkdtemp(`${tmpdir()}/issue-desk-owner-`);
    const lock = lockFile(dir);
    const result = await withStateLock(dir, async (state) => {
      await state.append({
        at: new Date().toISOString(),
        request_id: "owner",
        repo: "0509",
        url: "u-2",
      });
      await writeFile(lock, '{"token":"successor","pid":2}\n', "utf8");
      return "ran";
    });
    expect(result).toBe("ran");
    const owner = JSON.parse(await readFile(lock, "utf8")) as { token: string };
    expect(owner.token).toBe("successor");
    await unlink(lock);
  });
});

describe("countRecent", () => {
  it("counts a failed-create claim toward the cap", () => {
    const records = parseFiled(
      [
        JSON.stringify({ at: new Date(NOW).toISOString(), request_id: "a", url: "" }),
        JSON.stringify({ at: new Date(NOW).toISOString(), request_id: "b", url: "" }),
        JSON.stringify({ at: new Date(NOW - 25 * 3_600_000).toISOString(), request_id: "c", url: "" }),
      ].join("\n"),
    );
    expect(countRecent(records, NOW)).toBe(2);
  });

  it("counts one request once across its claim and its success", () => {
    const records = parseFiled(
      [
        JSON.stringify({ at: new Date(NOW).toISOString(), request_id: "a", url: "" }),
        JSON.stringify({ at: new Date(NOW).toISOString(), request_id: "a", url: "u-a" }),
        JSON.stringify({ at: new Date(NOW).toISOString(), request_id: "b", url: "u-b" }),
      ].join("\n"),
    );
    expect(countRecent(records, NOW)).toBe(2);
  });
});
