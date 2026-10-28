import { describe, expect, it } from "vitest";
import { parseInbox, readInbox, RunRequests } from "../src/inbox.ts";
import { scripted, tincanInbox } from "./helpers.ts";

describe("parseInbox", () => {
  it("reads the request text from body", () => {
    const stdout = JSON.stringify({
      requests: [
        {
          id: "req-1",
          from: "muse",
          chain: ["muse", "issue-desk"],
          body: "The export button does nothing on mobile.",
          claimed: false,
          text: "ignore me",
        },
      ],
      replies: [],
    });
    expect(parseInbox(stdout)).toEqual([
      {
        id: "req-1",
        from: "muse",
        chain: ["muse", "issue-desk"],
        body: "The export button does nothing on mobile.",
        claimed: false,
      },
    ]);
  });

  it("skips entries with no id and tolerates missing fields", () => {
    const stdout = JSON.stringify({
      requests: [{ id: "", body: "x" }, { id: "req-2" }, null, "nope"],
    });
    expect(parseInbox(stdout)).toEqual([
      { id: "req-2", from: "", chain: [], body: "", claimed: false },
    ]);
  });

  it("treats an empty inbox and empty output as no requests", () => {
    expect(parseInbox("")).toEqual([]);
    expect(parseInbox(JSON.stringify({ requests: [] }))).toEqual([]);
    expect(parseInbox(JSON.stringify({ replies: [] }))).toEqual([]);
  });

  it("ignores replies to its own requests", () => {
    const stdout = JSON.stringify({
      requests: [],
      replies: [{ request: { id: "asked-1" }, status: "answered", reply: "ok" }],
    });
    expect(parseInbox(stdout)).toEqual([]);
  });

  it("rejects output that is not JSON", () => {
    expect(() => parseInbox("tincan: not logged in")).toThrow();
  });
});

describe("readInbox", () => {
  it("asks tincan for the json inbox", async () => {
    const { run, calls } = scripted(tincanInbox([{ id: "req-1", from: "muse", body: "hi" }]));
    const inbox = await readInbox(run, "tincan", {});
    expect(inbox.map((request) => request.id)).toEqual(["req-1"]);
    expect(calls).toEqual([{ file: "tincan", args: ["inbox", "--json"] }]);
  });

  it("fails loudly when tincan fails, naming the exit code", async () => {
    const { run } = scripted(() => ({ code: 2, stderr: "relay unreachable\n" }));
    await expect(readInbox(run, "tincan", {})).rejects.toThrow(
      /tincan inbox failed \(exit 2\): relay unreachable/,
    );
  });
});

describe("RunRequests", () => {
  it("hands out each request once and keeps it for the run", () => {
    const run = new RunRequests();
    const request = { id: "req-1", from: "muse", chain: [], body: "a", claimed: false };
    expect(run.add([request])).toEqual([request]);
    expect(run.add([request])).toEqual([]);
    expect(run.get("req-1")).toEqual(request);
    expect(run.size).toBe(1);
    expect(run.ids()).toEqual(["req-1"]);
  });

  it("knows nothing about an id it never saw", () => {
    const run = new RunRequests();
    expect(run.get("req-9")).toBeUndefined();
    expect(run.ids()).toEqual([]);
  });

  it("reports only the new requests when the inbox grows", () => {
    const run = new RunRequests();
    const first = { id: "req-1", from: "muse", chain: [], body: "a", claimed: false };
    const second = { id: "req-2", from: "tether", chain: [], body: "b", claimed: false };
    run.add([first]);
    expect(run.add([first, second])).toEqual([second]);
    expect(run.size).toBe(2);
  });
});
