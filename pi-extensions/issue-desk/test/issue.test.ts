import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { capFile, countRecent, parseFiled } from "../src/cap.ts";
import { execFileRunner } from "../src/exec.ts";
import {
  BODY_MAX,
  TITLE_MAX,
  composeBody,
  fileIssue,
  hasMarker,
  issueUrlFrom,
  reply,
  type FileIssueDeps,
} from "../src/issue.ts";
import {
  combine,
  ghCreate,
  ghList,
  scripted,
  tempRoot,
  tincanReply,
  writeIntake,
  type Answer,
} from "./helpers.ts";

const NOW = Date.parse("2026-10-23T12:00:00Z");
const URL = "https://github.com/Nishfleet/0509/issues/4242";

const INPUT = {
  requestId: "req-1",
  sender: "muse",
  chain: ["muse", "issue-desk"],
  repo: "0509",
  title: "Export button does nothing on mobile",
  body: "Tapping Export on a phone does nothing. It should download the report.",
};

const setup = async (answer: Answer, overrides: Partial<FileIssueDeps> = {}) => {
  const root = await writeIntake(await tempRoot(), [
    { name: "0509", product: true },
    { name: "tether", product: true },
    { name: "fleet-ops", product: true },
    { name: "inish-site", product: false },
  ]);
  const stateDir = join(root, "state");
  const { run, calls } = scripted(answer);
  const deps: FileIssueDeps = {
    run,
    env: {},
    gh: "gh",
    repoRoot: root,
    stateDir,
    maxPerDay: 10,
    now: () => NOW,
    ...overrides,
  };
  return { deps, calls, root, stateDir };
};

const filed = async (stateDir: string): Promise<string[]> =>
  (await readFile(capFile(stateDir), "utf8").catch(() => ""))
    .split("\n")
    .filter((line) => line !== "");

const prefill = async (
  stateDir: string,
  records: Array<{ at: string; request_id: string; repo?: string; url?: string }>,
): Promise<void> => {
  await mkdir(stateDir, { recursive: true });
  await writeFile(
    capFile(stateDir),
    records
      .map((record) =>
        JSON.stringify({ repo: "0509", url: URL, ...record }),
      )
      .join("\n") + "\n",
    "utf8",
  );
};

describe("fileIssue allowlist", () => {
  it("rejects fleet-ops without touching gh", async () => {
    const { deps, calls } = await setup(ghCreate(URL));
    await expect(fileIssue(deps, { ...INPUT, repo: "fleet-ops" })).rejects.toThrow(
      /fleet-ops is never accepted/,
    );
    expect(calls).toEqual([]);
  });

  it("rejects a repo that is not a product repo, and names the ones it accepts", async () => {
    const { deps, calls } = await setup(ghCreate(URL));
    await expect(fileIssue(deps, { ...INPUT, repo: "inish-site" })).rejects.toThrow(
      /is not on the allowlist. Use exactly one of: 0509, tether/,
    );
    expect(calls).toEqual([]);
  });

  it("rejects an owner-qualified or traversing repo name", async () => {
    const { deps } = await setup(ghCreate(URL));
    for (const repo of ["Nishfleet/0509", "../0509", "0509 ", ""]) {
      await expect(fileIssue(deps, { ...INPUT, repo })).rejects.toThrow(
        /not on the allowlist/,
      );
    }
  });
});

describe("fileIssue create", () => {
  it("files one needs-triage issue and returns its url", async () => {
    const { deps, calls, stateDir } = await setup(combine(ghList([]), ghCreate(URL)));
    const result = await fileIssue(deps, INPUT);

    expect(result).toEqual({ url: URL, created: true });
    expect(calls.map((call) => call.args.slice(0, 2))).toEqual([
      ["issue", "list"],
      ["issue", "create"],
    ]);
    const create = calls[1].args;
    expect(create.slice(0, 8)).toEqual([
      "issue",
      "create",
      "--repo",
      "Nishfleet/0509",
      "--label",
      "needs-triage",
      "--title",
      INPUT.title,
    ]);
    expect(create).not.toContain("agent-ready");
    expect(create[8]).toBe("--body");
    expect(create[9]).toContain(INPUT.body);
    expect(create[9]).toContain("tincan-request: req-1");
    expect(create[9]).toContain("requested-by: muse");
    expect(create[9]).toContain("chain: muse > issue-desk");

    const records = (await filed(stateDir)).map((line) => JSON.parse(line));
    expect(records.map((record) => record.url)).toEqual(["", URL]);
    expect(records[1]).toEqual({
      at: new Date(NOW).toISOString(),
      request_id: "req-1",
      repo: "0509",
      url: URL,
    });
  });

  it("searches the repo by request id, in every state", async () => {
    const { deps, calls } = await setup(combine(ghList([]), ghCreate(URL)));
    await fileIssue(deps, INPUT);
    const list = calls[0].args;
    expect(list).toContain("--state");
    expect(list[list.indexOf("--state") + 1]).toBe("all");
    expect(list[list.indexOf("--search") + 1]).toBe("req-1 in:body");
  });

  it("collapses a multi-line title to one line", async () => {
    const { deps, calls } = await setup(combine(ghList([]), ghCreate(URL)));
    await fileIssue(deps, { ...INPUT, title: "  Export   does\nnothing " });
    expect(calls[1].args[calls[1].args.indexOf("--title") + 1]).toBe(
      "Export does nothing",
    );
  });
});

describe("fileIssue is idempotent", () => {
  it("returns the issue this run already filed instead of a second one", async () => {
    const { deps, calls } = await setup(combine(ghList([]), ghCreate(URL)));
    const first = await fileIssue(deps, INPUT);
    const second = await fileIssue(deps, INPUT);
    expect(second).toEqual({ url: URL, created: false });
    expect(first.url).toBe(second.url);
    expect(calls.filter((call) => call.args[1] === "create")).toHaveLength(1);
  });

  it("returns an existing issue found by its tincan-request marker", async () => {
    const existing = {
      url: "https://github.com/Nishfleet/0509/issues/7",
      body: `Old text\n\ntincan-request: req-1\nrequested-by: muse\n`,
    };
    const { deps, calls, stateDir } = await setup(combine(ghList([existing]), ghCreate(URL)));
    const result = await fileIssue(deps, INPUT);
    expect(result).toEqual({ url: existing.url, created: false });
    expect(calls.filter((call) => call.args[1] === "create")).toHaveLength(0);
    expect(await filed(stateDir)).toHaveLength(1);
  });

  it("ignores an issue whose body only mentions another request id", async () => {
    const other = {
      url: "https://github.com/Nishfleet/0509/issues/8",
      body: "tincan-request: req-10\n",
    };
    const { deps, calls } = await setup(combine(ghList([other]), ghCreate(URL)));
    const result = await fileIssue(deps, INPUT);
    expect(result).toEqual({ url: URL, created: true });
    expect(calls.filter((call) => call.args[1] === "create")).toHaveLength(1);
  });
});

describe("fileIssue daily cap", () => {
  it("refuses once the rolling 24 hour cap is reached", async () => {
    const { deps, calls, stateDir } = await setup(combine(ghList([]), ghCreate(URL)), {
      maxPerDay: 2,
    });
    await prefill(stateDir, [
      { at: new Date(NOW - 60_000).toISOString(), request_id: "req-a" },
      { at: new Date(NOW - 3_600_000).toISOString(), request_id: "req-b" },
    ]);
    await expect(fileIssue(deps, INPUT)).rejects.toThrow(
      /daily cap reached: 2 issues filed in the last 24 hours and the limit is 2/,
    );
    expect(calls.filter((call) => call.args[1] === "create")).toHaveLength(0);
  });

  it("counts only the last 24 hours", async () => {
    const { deps, calls, stateDir } = await setup(combine(ghList([]), ghCreate(URL)), {
      maxPerDay: 1,
    });
    await prefill(stateDir, [
      { at: new Date(NOW - 25 * 3_600_000).toISOString(), request_id: "req-old" },
    ]);
    const result = await fileIssue(deps, INPUT);
    expect(result.created).toBe(true);
    expect(calls.filter((call) => call.args[1] === "create")).toHaveLength(1);
  });
});

describe("fileIssue limits", () => {
  it("refuses an empty title", async () => {
    const { deps, calls } = await setup(combine(ghList([]), ghCreate(URL)));
    await expect(fileIssue(deps, { ...INPUT, title: "   " })).rejects.toThrow(
      /title is empty/,
    );
    expect(calls).toEqual([]);
  });

  it("refuses a title over the limit and says how long it is", async () => {
    const { deps } = await setup(combine(ghList([]), ghCreate(URL)));
    const title = "x".repeat(TITLE_MAX + 1);
    await expect(fileIssue(deps, { ...INPUT, title })).rejects.toThrow(
      new RegExp(`title is ${TITLE_MAX + 1} characters and the limit is ${TITLE_MAX}`),
    );
  });

  it("accepts a title exactly at the limit", async () => {
    const { deps } = await setup(combine(ghList([]), ghCreate(URL)));
    const result = await fileIssue(deps, { ...INPUT, title: "x".repeat(TITLE_MAX) });
    expect(result.created).toBe(true);
  });

  it("refuses an empty body", async () => {
    const { deps } = await setup(combine(ghList([]), ghCreate(URL)));
    await expect(fileIssue(deps, { ...INPUT, body: "  \n " })).rejects.toThrow(
      /body is empty/,
    );
  });

  it("refuses a body that would go over the limit once the footer is added", async () => {
    const { deps } = await setup(combine(ghList([]), ghCreate(URL)));
    const body = "y".repeat(BODY_MAX);
    await expect(fileIssue(deps, { ...INPUT, body })).rejects.toThrow(
      new RegExp(`the limit is ${BODY_MAX}`),
    );
  });

  it("strips control characters from the body", async () => {
    const { deps, calls } = await setup(combine(ghList([]), ghCreate(URL)));
    await fileIssue(deps, { ...INPUT, body: "a\u0000b\u0007c" });
    expect(calls[1].args[calls[1].args.indexOf("--body") + 1]).toContain("abc");
  });
});

describe("fileIssue failures", () => {
  it("fails without filing when the duplicate check fails", async () => {
    const { deps, calls } = await setup(() => ({ code: 1, stderr: "HTTP 502\n" }));
    await expect(fileIssue(deps, INPUT)).rejects.toThrow(
      /could not check 0509 for an existing issue \(gh exit 1\): HTTP 502/,
    );
    expect(calls.filter((call) => call.args[1] === "create")).toHaveLength(0);
  });

  it("refuses a retry when an earlier attempt left a claim without a url", async () => {
    const { deps, calls, stateDir } = await setup(ghCreate(URL));
    await prefill(stateDir, [
      { at: new Date(NOW).toISOString(), request_id: "req-1", url: "" },
    ]);
    await expect(fileIssue(deps, INPUT)).rejects.toThrow(
      /did not finish, so it is unknown whether the issue exists/,
    );
    expect(calls).toEqual([]);
  });

  it("keeps the claim when gh issue create fails, so a retry cannot double-file", async () => {
    const { deps, stateDir } = await setup(
      combine(ghList([]), () => ({ code: 1, stderr: "label not found\n" })),
    );
    await expect(fileIssue(deps, INPUT)).rejects.toThrow(
      /gh issue create failed \(exit 1\): label not found/,
    );
    const records = (await filed(stateDir)).map((line) => JSON.parse(line));
    expect(records).toEqual([
      { at: new Date(NOW).toISOString(), request_id: "req-1", repo: "0509", url: "" },
    ]);
  });
});

describe("composeBody and the marker", () => {
  it("ends the body with the request footer", () => {
    const body = composeBody("Text", "req-9", "tether", ["muse", "tether"]);
    expect(body.startsWith("Text\n")).toBe(true);
    expect(body.trimEnd().split("\n").slice(-3)).toEqual([
      "tincan-request: req-9",
      "requested-by: tether",
      "chain: muse > tether",
    ]);
  });

  it("falls back to the sender when the chain is empty", () => {
    expect(composeBody("Text", "req-9", "muse", [])).toContain("chain: muse");
  });

  it("matches the marker line exactly", () => {
    expect(hasMarker("x\ntincan-request: req-1\n", "req-1")).toBe(true);
    expect(hasMarker("tincan-request: req-1", "req-1")).toBe(true);
    expect(hasMarker("tincan-request: req-10", "req-1")).toBe(false);
    expect(hasMarker("see tincan-request: req-1 above", "req-1")).toBe(false);
    expect(hasMarker("", "req-1")).toBe(false);
  });
});

describe("issueUrlFrom", () => {
  it("finds the issue url in gh output", () => {
    expect(issueUrlFrom("https://github.com/Nishfleet/0509/issues/12\n")).toBe(
      "https://github.com/Nishfleet/0509/issues/12",
    );
    expect(
      issueUrlFrom("warning: x\nCreating issue in Nishfleet/tether\n\nhttps://github.com/Nishfleet/tether/issues/3\n"),
    ).toBe("https://github.com/Nishfleet/tether/issues/3");
  });

  it("fails when gh printed no url", () => {
    expect(() => issueUrlFrom("done\n")).toThrow(/did not return an issue URL/);
  });
});

describe("state file", () => {
  it("ignores a line it cannot parse", () => {
    const parsed = parseFiled(
      '{"at":"2026-10-23T00:00:00.000Z","request_id":"a"}\nnot json\n\n',
    );
    expect(parsed.map((record) => record.request_id)).toEqual(["a"]);
  });

  it("counts only filed records inside the window", () => {
    const records = parseFiled(
      [
        JSON.stringify({ at: new Date(NOW).toISOString(), request_id: "a", url: "u-a" }),
        JSON.stringify({ at: new Date(NOW - 23 * 3_600_000).toISOString(), request_id: "b", url: "u-b" }),
        JSON.stringify({ at: new Date(NOW - 24 * 3_600_000).toISOString(), request_id: "c", url: "u-c" }),
        JSON.stringify({ at: "not a date", request_id: "d", url: "u-d" }),
        JSON.stringify({ at: new Date(NOW).toISOString(), request_id: "e", repo: "0509", url: "" }),
      ].join("\n"),
    );
    expect(countRecent(records, NOW)).toBe(2);
  });
});

describe("reply", () => {
  it("sends the request id and the text as separate arguments, after --", async () => {
    const { run, calls } = scripted(tincanReply());
    await reply(run, "tincan", {}, "req-1", "Filed https://github.com/Nishfleet/0509/issues/1");
    expect(calls).toEqual([
      {
        file: "tincan",
        args: ["reply", "req-1", "--", "Filed https://github.com/Nishfleet/0509/issues/1"],
      },
    ]);
  });

  it("keeps a message that starts with a dash from becoming a flag", async () => {
    const { run, calls } = scripted(tincanReply());
    await reply(run, "tincan", {}, "req-1", "-hello");
    expect(calls[0].args).toEqual(["reply", "req-1", "--", "-hello"]);
  });

  it("refuses empty text", async () => {
    const { run, calls } = scripted(tincanReply());
    await expect(reply(run, "tincan", {}, "req-1", "   ")).rejects.toThrow(
      /reply text is empty/,
    );
    expect(calls).toEqual([]);
  });

  it("fails loudly when tincan reply fails", async () => {
    const { run } = scripted(tincanReply(3, "unknown request\n"));
    await expect(reply(run, "tincan", {}, "req-1", "hi")).rejects.toThrow(
      /tincan reply failed \(exit 3\): unknown request/,
    );
  });
});

describe("execFileRunner", () => {
  it("never goes through a shell", async () => {
    const result = await execFileRunner("/bin/echo", ["$HOME", ";", "id"]);
    expect(result.code).toBe(0);
    expect(result.stdout.trim()).toBe("$HOME ; id");
  });

  it("reports a missing binary as a failure with a message", async () => {
    const result = await execFileRunner("/nonexistent/issue-desk-binary", []);
    expect(result.code).not.toBe(0);
    expect(result.stderr).not.toBe("");
  });

  it("passes an environment through to the child", async () => {
    const result = await execFileRunner("/usr/bin/env", [], {
      env: { ISSUE_DESK_PROBE: "yes" },
    });
    expect(result.stdout).toContain("ISSUE_DESK_PROBE=yes");
  });
});
