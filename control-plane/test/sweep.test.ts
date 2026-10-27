import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { type Gh, type GhResult, redRework, requeue, runLive, sweep } from "../src/sweep.ts";

const config = (name: string) => JSON.parse(readFileSync(new URL(`../../config/${name}`, import.meta.url), "utf8"));

const merge = (a: any, b: any): any =>
  a && b && typeof a === "object" && typeof b === "object" && !Array.isArray(a) && !Array.isArray(b)
    ? Object.fromEntries([...new Set([...Object.keys(a), ...Object.keys(b)])].map((k) => [k, k in b ? merge(a[k], b[k]) : a[k]]))
    : b;

describe("redRework", () => {
  const rework = config("sweep-rework-cases.json");
  it.each(rework.cases)("case $id", (c: any) => {
    const { pr, issue, comments } = merge(rework.base, c.set);
    expect(redRework({ pr, issue, comments }).reason).toBe(c.want);
  });
});

describe("runLive", () => {
  const events = config("sweep-liveness-events.json");
  it.each(events.cases)("case $name", (c: any) => {
    const rv = { status: c.run_status, jobs: c.jobs.map(([name, status]: string[]) => ({ name, status })) };
    expect(runLive(rv, c.ref)).toBe(c.want);
  });
});

const ok = (v: unknown): GhResult => ({ code: 0, stdout: typeof v === "string" ? v : JSON.stringify(v), stderr: "" });
const issue = (number: number, created_at: string, labels: string[], extra: object = {}) => ({
  number, created_at, state: "open", issue_dependencies_summary: { blocked_by: 0 }, labels: labels.map((name) => ({ name })), ...extra,
});
const claimPr = (number: number, issueNo: number, extra: object = {}) => ({
  number, headRefName: `claim/issue-${issueNo}`, isDraft: false, isCrossRepository: false, mergeable: "MERGEABLE", autoMergeRequest: {}, labels: [], ...extra,
});
const red = [{ name: "ci", status: "COMPLETED", conclusion: "FAILURE", completedAt: "2026-10-09T00:00:00Z", startedAt: "2026-10-09T00:00:00Z" }];

function fakeGh(bodyOnStdout: boolean, calls: string[]): Gh {
  const prs = [claimPr(7001, 7001), claimPr(8001, 7003), claimPr(8002, 9502, { labels: [{ name: "needs-coordinator" }] })];
  return async (args) => {
    const key = args.join(" ");
    calls.push(key);
    if (/^issue list .*agent-in-progress/.test(key)) return ok([{ number: 11 }]);
    if (/^issue list/.test(key)) return ok([{ number: 7001 }, { number: 7002 }]);
    if (/^pr list .*--head/.test(key)) return ok([]);
    if (/^pr list/.test(key)) return ok(prs);
    if (/^issue view 7003 /.test(key)) return ok({ comments: [0, 1, 2].map(() => ({ body: "x".repeat(60_000), createdAt: "2026-10-01T00:00:00Z" })) });
    if (/^issue view 9502 /.test(key)) return { code: 1, stdout: "", stderr: "GraphQL: Could not resolve to an issue or pull request with the number of 9502." };
    if (/^issue view /.test(key)) return ok({ comments: [] });
    if (/^pr view 7001 /.test(key)) return ok({ headRefName: "claim/issue-7001", mergeStateStatus: "CLEAN", statusCheckRollup: [] });
    if (/^pr view 8001 /.test(key)) return ok({ headRefName: "claim/issue-7003", mergeStateStatus: "CLEAN", statusCheckRollup: red });
    if (/^pr view 8002 /.test(key)) return ok({ headRefName: "claim/issue-9502", mergeStateStatus: "CLEAN", statusCheckRollup: red });
    if (/^api graphql/.test(key)) return ok({ data: { repository: { mergeQueue: { entries: { nodes: [] } } } } });
    if (/^api repos\/o\/r\/issues\/9502$/.test(key)) {
      const body = '{"message":"This issue was deleted","documentation_url":"https://docs.github.com/rest","status":"410"}';
      return { code: 1, stdout: bodyOnStdout ? body : "", stderr: "gh: This issue was deleted (HTTP 410)" };
    }
    if (/^api repos\/o\/r\/issues\/7001$/.test(key)) return ok(issue(7001, "2026-10-01T00:00:00Z", ["agent-ready"]));
    if (/^api repos\/o\/r\/issues\/7002$/.test(key)) return ok(issue(7002, "2026-10-02T00:00:00Z", ["agent-ready"]));
    if (/^api repos\/o\/r\/issues\/7003$/.test(key)) return ok(issue(7003, "2026-10-03T00:00:00Z", ["agent-in-progress"], { body: "y".repeat(140_000) }));
    return { code: 1, stdout: "", stderr: `fake gh: unexpected call: ${key}` };
  };
}

describe("sweep", () => {
  it.each([true, false])("a deleted issue does not abort the sweep (body on stdout: %s)", async (bodyOnStdout) => {
    const calls: string[] = [];
    const lines: string[] = [];
    const out = await sweep({ repo: "o/r", issue: "", closed: "" }, { gh: fakeGh(bodyOnStdout, calls), sleep: async () => {}, log: (l) => lines.push(l) });
    expect(out.refs).toEqual(["claim/issue-7001", "claim/issue-7002", "claim/issue-7003"]);
    expect(out.stalledRefs).toEqual([]);
    expect(lines.some((l) => l.includes("#9502: issue gone"))).toBe(true);
  });

  it("an explicit issue lists only it, skipping parked labels", async () => {
    const gh: Gh = async (args) =>
      args.join(" ") === "api repos/o/r/issues/5" ? ok(issue(5, "2026-10-01T00:00:00Z", ["agent-ready", "needs-split"])) : { code: 1, stdout: "", stderr: "unexpected" };
    const out = await sweep({ repo: "o/r", issue: "5", closed: "" }, { gh, sleep: async () => {}, log: () => {} });
    expect(out.refs).toEqual([]);
  });

  it("an issue read that is not a 404 or 410 aborts the sweep", async () => {
    const gh: Gh = async () => ({ code: 1, stdout: "", stderr: "gh: Server Error (HTTP 502)" });
    await expect(sweep({ repo: "o/r", issue: "5", closed: "" }, { gh, sleep: async () => {}, log: () => {} })).rejects.toThrow(/issue read failed/);
  });

  it("a requeued dead claim and priority-now order", async () => {
    const calls: string[] = [];
    const gh: Gh = async (args) => {
      const key = args.join(" ");
      calls.push(key);
      if (/^issue list .*agent-in-progress/.test(key)) return ok([{ number: 11 }]);
      if (/^issue list/.test(key)) return ok([{ number: 1 }, { number: 2 }]);
      if (/^pr list .*--head/.test(key)) return ok([]);
      if (/^pr list/.test(key)) return ok([]);
      if (/^issue view 11 /.test(key)) return ok({ comments: [{ body: "agent run started: https://github.com/o/r/actions/runs/99", createdAt: "x" }] });
      if (/^run view 99 /.test(key)) return ok({ status: "completed", jobs: [] });
      if (/^issue edit 11 /.test(key)) return ok("");
      if (/^api graphql/.test(key)) return ok({ data: { repository: { mergeQueue: { entries: { nodes: [] } } } } });
      if (/^api repos\/o\/r\/issues\/1$/.test(key)) return ok(issue(1, "2026-10-01T00:00:00Z", ["agent-ready"]));
      if (/^api repos\/o\/r\/issues\/2$/.test(key)) return ok(issue(2, "2026-10-02T00:00:00Z", ["agent-ready", "priority-now"]));
      return { code: 1, stdout: "", stderr: `unexpected ${key}` };
    };
    const out = await sweep({ repo: "o/r", issue: "", closed: "" }, { gh, sleep: async () => {}, log: () => {} });
    expect(out.refs).toEqual(["claim/issue-2", "claim/issue-1"]);
    expect(out.stalledRefs).toEqual(["claim/issue-11-miss-review"]);
    expect(calls).toContain("issue edit 11 -R o/r --remove-label agent-in-progress --add-label agent-ready");
  });
});

describe("requeue", () => {
  const ENDED = "orchestrator hand-off ended without a PR: https://example.invalid/runs/";
  const now = Date.parse("2026-10-27T12:00:00Z") / 1000;
  const tried = (number: number, hoursIdle = 7, ended = 1, labels = ["orchestrator-tried"], assoc = "OWNER") => ({
    number,
    updatedAt: new Date((now - hoursIdle * 3600) * 1000).toISOString(),
    labels: labels.map((name) => ({ name })),
    comments: Array.from({ length: ended }, (_, i) => ({ body: `${ENDED}${number}${i}`, authorAssociation: assoc })),
  });
  async function run(issues: object[], queued = 0) {
    const writes: string[] = [];
    const logins: boolean[] = [];
    const gh: Gh = async (args, opts) => {
      const key = args.join(" ");
      if (/^issue list .*needs-orchestrator/.test(key)) return ok(Array.from({ length: queued }, (_, number) => ({ number })));
      if (/^issue list/.test(key)) return ok(issues);
      writes.push(key);
      logins.push(opts?.runnerLogin === true);
      return ok("");
    };
    await requeue({ repo: "o/r" }, { gh, sleep: async () => {}, log: () => {} }, now);
    const edits = (label: string) => writes.filter((w) => w.startsWith("issue edit") && w.includes(label)).map((w) => Number(w.split(" ")[2]));
    return { writes, logins, edits };
  }

  it("requeues an issue idle over 6 h and leaves a fresh one", async () => {
    const r = await run([tried(1, 7), tried(2, 5)]);
    expect(r.edits("--add-label needs-orchestrator")).toEqual([1]);
    expect(r.writes[0]).toBe("issue edit 1 -R o/r --remove-label orchestrator-tried --add-label needs-orchestrator");
  });
  it("writes the requeue label as the runner login, not the job token", async () => {
    expect((await run([tried(1)])).logins).toEqual([true]);
  });
  it("requeues at most 3 a sweep", async () => {
    expect((await run([1, 2, 3, 4, 5, 6, 7].map((n) => tried(n)))).edits("--add-label needs-orchestrator")).toHaveLength(3);
  });
  it("already queued issues use up the batch", async () => {
    expect((await run([1, 2, 3, 4].map((n) => tried(n)), 2)).edits("--add-label needs-orchestrator")).toHaveLength(1);
  });
  it("three ended hand-offs escalate instead of requeue", async () => {
    const r = await run([tried(1, 7, 3), tried(2, 7, 2)]);
    expect(r.edits("--add-label needs-nish-decision")).toEqual([1]);
    expect(r.edits("--add-label needs-orchestrator")).toEqual([2]);
    expect(r.writes.some((w) => w.startsWith("issue comment 1 ") && w.includes("runs/10") && w.includes("runs/12"))).toBe(true);
  });
  it("escalated and queued issues are left alone", async () => {
    const r = await run([tried(1, 7, 3, ["orchestrator-tried", "needs-nish-decision"]), tried(2, 7, 1, ["orchestrator-tried", "needs-orchestrator"])]);
    expect(r.writes).toEqual([]);
  });
  it("a full queue requeues nothing but still escalates", async () => {
    const r = await run([tried(1), tried(2, 7, 3)], 3);
    expect(r.edits("--add-label needs-orchestrator")).toEqual([]);
    expect(r.edits("--add-label needs-nish-decision")).toEqual([2]);
  });
  it("a stranger's comments are not counted", async () => {
    const r = await run([tried(1, 7, 3, ["orchestrator-tried"], "NONE")]);
    expect(r.edits("--add-label needs-nish-decision")).toEqual([]);
    expect(r.edits("--add-label needs-orchestrator")).toEqual([1]);
  });
  it("a refused write is a warning, not a failure", async () => {
    const lines: string[] = [];
    const gh: Gh = async (args) => {
      const key = args.join(" ");
      if (/^issue list .*needs-orchestrator/.test(key)) return ok([]);
      return /^issue list/.test(key) ? ok([tried(1)]) : { code: 1, stdout: "", stderr: "denied" };
    };
    await requeue({ repo: "o/r" }, { gh, sleep: async () => {}, log: (l) => lines.push(l) }, now);
    expect(lines).toEqual(["::warning::#1: re-queue refused"]);
  });
});

describe("sweep without a merge queue", () => {
  it("a null mergeQueue reads as an empty queue", async () => {
    const gh: Gh = async (args) => {
      const key = args.join(" ");
      if (/^issue list/.test(key) || /^pr list/.test(key)) return ok([]);
      if (/^api graphql/.test(key)) return ok({ data: { repository: { mergeQueue: null } } });
      return { code: 1, stdout: "", stderr: `unexpected ${key}` };
    };
    const out = await sweep({ repo: "o/r", issue: "", closed: "" }, { gh, sleep: async () => {}, log: () => {} });
    expect(out.refs).toEqual([]);
  });
});
