import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { createIssueDesk } from "../index.ts";
import {
  combine,
  fakePi,
  ghCreate,
  ghList,
  scripted,
  tempRoot,
  textOf,
  tincanInbox,
  tincanReply,
  writeIntake,
  type Answer,
  type Scripted,
} from "./helpers.ts";

const URL = "https://github.com/Nishfleet/0509/issues/4242";
const NOW = Date.parse("2026-10-23T12:00:00Z");

const REQUEST = {
  id: "req-1",
  from: "muse",
  chain: ["muse", "issue-desk"],
  body: "The export button does nothing on mobile.",
  claimed: false,
};

const desk = async (answer: Answer, senders = "muse,instinct,tether,hermes") => {
  const root = await writeIntake(await tempRoot(), [
    { name: "0509", product: true },
    { name: "tether", product: true },
    { name: "fleet-ops", product: true },
  ]);
  const script: Scripted = scripted(answer);
  const { pi, tools } = fakePi();
  createIssueDesk(pi, {
    env: {
      ISSUE_DESK_REPO_ROOT: root,
      ISSUE_DESK_STATE_DIR: join(root, "state"),
      ISSUE_DESK_SENDERS: senders,
    },
    run: script.run,
    now: () => NOW,
    cwd: root,
  });
  return { tools, calls: script.calls, root };
};

const call = async (
  tools: Map<string, { execute: (...args: never[]) => Promise<{ content: Array<{ type: string; text: string }> }> }>,
  name: string,
  params: Record<string, unknown>,
): Promise<string> => {
  const tool = tools.get(name);
  if (tool === undefined) throw new Error(`no tool ${name}`);
  const result = await (tool.execute as unknown as (
    id: string,
    params: Record<string, unknown>,
  ) => Promise<{ content: Array<{ type: string; text: string }> }>)("call-1", params);
  return textOf(result);
};

describe("registration", () => {
  it("registers exactly the three tools issue-desk may use", async () => {
    const { tools } = await desk(tincanInbox([]));
    expect([...tools.keys()].sort()).toEqual([
      "file_issue",
      "tincan_inbox",
      "tincan_reply",
    ]);
  });

  it("gives every tool a description and a schema", async () => {
    const { tools } = await desk(tincanInbox([]));
    for (const tool of tools.values()) {
      expect(tool.description.length).toBeGreaterThan(40);
      expect(tool.parameters).toBeTruthy();
    }
  });
});

describe("tincan_inbox", () => {
  it("lists the waiting request with its id, sender and text", async () => {
    const { tools } = await desk(tincanInbox([REQUEST]));
    const text = await call(tools, "tincan_inbox", {});
    expect(text).toContain("request_id: req-1");
    expect(text).toContain("from: muse");
    expect(text).toContain("chain: muse > issue-desk");
    expect(text).toContain("The export button does nothing on mobile.");
    expect(text).toContain("repos you can file into: 0509, tether");
  });

  it("says the inbox is empty when nothing is waiting", async () => {
    const { tools } = await desk(tincanInbox([]));
    expect(await call(tools, "tincan_inbox", {})).toContain(
      "The inbox is empty. No requests are waiting.",
    );
  });

  it("does not present the same request as new twice", async () => {
    const { tools } = await desk(tincanInbox([REQUEST]));
    await call(tools, "tincan_inbox", {});
    const second = await call(tools, "tincan_inbox", {});
    expect(second).toContain("No new requests.");
    expect(second).toContain("already listed in this run");
    expect(second).toContain("req-1");
  });
});

describe("file_issue", () => {
  it("files one issue for a request it just listed", async () => {
    const { tools, calls } = await desk(combine(ghList([]), ghCreate(URL), tincanInbox([REQUEST])));
    await call(tools, "tincan_inbox", {});
    const text = await call(tools, "file_issue", {
      request_id: "req-1",
      repo: "0509",
      title: "Export does nothing on mobile",
      body: "Tapping Export on a phone does nothing.",
    });
    expect(text).toBe(
      `Filed ${URL} with needs-triage; admission decides whether a worker starts.`,
    );
    expect(calls.filter((entry) => entry.args[1] === "create")).toHaveLength(1);
  });

  it("refuses a request id it never listed", async () => {
    const { tools, calls } = await desk(combine(ghList([]), ghCreate(URL)));
    await expect(
      call(tools, "file_issue", {
        request_id: "req-9",
        repo: "0509",
        title: "t",
        body: "b",
      }),
    ).rejects.toThrow(/unknown request_id "req-9"/);
    expect(calls).toEqual([]);
  });

  it("refuses a sender outside the allowlist", async () => {
    const { tools, calls } = await desk(
      combine(ghList([]), ghCreate(URL), tincanInbox([{ ...REQUEST, from: "stranger" }])),
    );
    await call(tools, "tincan_inbox", {});
    await expect(
      call(tools, "file_issue", {
        request_id: "req-1",
        repo: "0509",
        title: "t",
        body: "b",
      }),
    ).rejects.toThrow(/sender "stranger" may not file issues/);
    expect(calls.filter((entry) => entry.args[0] === "issue")).toEqual([]);
  });

  it("refuses fleet-ops even though the config file lists it", async () => {
    const { tools } = await desk(combine(ghList([]), ghCreate(URL), tincanInbox([REQUEST])));
    await call(tools, "tincan_inbox", {});
    await expect(
      call(tools, "file_issue", {
        request_id: "req-1",
        repo: "fleet-ops",
        title: "t",
        body: "b",
      }),
    ).rejects.toThrow(/fleet-ops is never accepted/);
  });
});

describe("tincan_reply", () => {
  it("answers a request it listed, with the issue url", async () => {
    const { tools, calls } = await desk(combine(tincanReply(), tincanInbox([REQUEST])));
    await call(tools, "tincan_inbox", {});
    const text = await call(tools, "tincan_reply", {
      request_id: "req-1",
      text: `Filed ${URL}`,
    });
    expect(text).toBe("Replied to req-1.");
    expect(calls.at(-1)).toEqual({
      file: "tincan",
      args: ["reply", "req-1", "--", `Filed ${URL}`],
    });
  });

  it("refuses a request id it never listed", async () => {
    const { tools, calls } = await desk(tincanReply());
    await expect(
      call(tools, "tincan_reply", { request_id: "req-9", text: "hi" }),
    ).rejects.toThrow(/unknown request_id "req-9"/);
    expect(calls).toEqual([]);
  });
});
