import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { type Gh, type GhResult, redRework, runLive, sweep } from "../src/sweep.ts";

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
const no = (stderr: string) => ({ code: 1, stdout: "", stderr });
const issue = (number: number, created_at: string, labels: string[], extra: object = {}) => ({
  number,
  created_at,
  state: "open",
  issue_dependencies_summary: { blocked_by: 0 },
  labels: labels.map((name) => ({ name })),
  ...extra,
});
const claimPr = (number: number, issueNo: number, extra: object = {}) => ({
  number,
  headRefName: `claim/issue-${issueNo}`,
  isDraft: false,
  isCrossRepository: false,
  mergeable: "MERGEABLE",
  autoMergeRequest: {},
  labels: [],
  ...extra,
});
const red = [{ name: "ci", status: "COMPLETED", conclusion: "FAILURE", completedAt: "2026-10-09T00:00:00Z", startedAt: "2026-10-09T00:00:00Z" }];
const EMPTY_QUEUE = { data: { repository: { mergeQueue: { entries: { nodes: [] } } } } };

const quiet = { sleep: async () => {}, log: () => {} };

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
    if (/^issue view 9502 /.test(key)) return no("GraphQL: Could not resolve to an issue or pull request with the number of 9502.");
    if (/^issue view /.test(key)) return ok({ comments: [] });
    if (/^pr view 7001 /.test(key)) return ok({ headRefName: "claim/issue-7001", mergeStateStatus: "CLEAN", statusCheckRollup: [] });
    if (/^pr view 8001 /.test(key)) return ok({ headRefName: "claim/issue-7003", mergeStateStatus: "CLEAN", statusCheckRollup: red });
    if (/^pr view 8002 /.test(key)) return ok({ headRefName: "claim/issue-9502", mergeStateStatus: "CLEAN", statusCheckRollup: red });
    if (/^api graphql/.test(key)) return ok(EMPTY_QUEUE);
    if (/^api repos\/o\/r\/issues\/9502$/.test(key)) {
      const body = '{"message":"This issue was deleted","documentation_url":"https://docs.github.com/rest","status":"410"}';
      return { code: 1, stdout: bodyOnStdout ? body : "", stderr: "gh: This issue was deleted (HTTP 410)" };
    }
    if (/^api repos\/o\/r\/issues\/7001$/.test(key)) return ok(issue(7001, "2026-10-01T00:00:00Z", ["agent-ready"]));
    if (/^api repos\/o\/r\/issues\/7002$/.test(key)) return ok(issue(7002, "2026-10-02T00:00:00Z", ["agent-ready"]));
    if (/^api repos\/o\/r\/issues\/7003$/.test(key)) return ok(issue(7003, "2026-10-03T00:00:00Z", ["agent-in-progress"], { body: "y".repeat(140_000) }));
    return no(`fake gh: unexpected call: ${key}`);
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
      args.join(" ") === "api repos/o/r/issues/5" ? ok(issue(5, "2026-10-01T00:00:00Z", ["agent-ready", "needs-split"])) : no("unexpected");
    const out = await sweep({ repo: "o/r", issue: "5", closed: "" }, { gh, ...quiet });
    expect(out.refs).toEqual([]);
  });

  it("an issue read that is not a 404 or 410 aborts the sweep", async () => {
    const gh: Gh = async () => no("gh: Server Error (HTTP 502)");
    await expect(sweep({ repo: "o/r", issue: "5", closed: "" }, { gh, ...quiet })).rejects.toThrow(/issue read failed/);
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
      if (/^api graphql/.test(key)) return ok(EMPTY_QUEUE);
      if (/^api repos\/o\/r\/issues\/1$/.test(key)) return ok(issue(1, "2026-10-01T00:00:00Z", ["agent-ready"]));
      if (/^api repos\/o\/r\/issues\/2$/.test(key)) return ok(issue(2, "2026-10-02T00:00:00Z", ["agent-ready", "priority-now"]));
      return no(`unexpected ${key}`);
    };
    const out = await sweep({ repo: "o/r", issue: "", closed: "" }, { gh, ...quiet });
    expect(out.refs).toEqual(["claim/issue-2", "claim/issue-1"]);
    expect(out.stalledRefs).toEqual(["claim/issue-11-miss-review"]);
    expect(calls).toContain("issue edit 11 -R o/r --remove-label agent-in-progress --add-label agent-ready");
  });

  it("a null mergeQueue reads as an empty queue", async () => {
    const gh: Gh = async (args) => {
      const key = args.join(" ");
      if (/^issue list/.test(key) || /^pr list/.test(key)) return ok([]);
      if (/^api graphql/.test(key)) return ok({ data: { repository: { mergeQueue: null } } });
      return no(`unexpected ${key}`);
    };
    expect((await sweep({ repo: "o/r", issue: "", closed: "" }, { gh, ...quiet })).refs).toEqual([]);
  });
});

function triageGh(unlabelled: number[], refuse: number[]): { gh: Gh; edits: string[] } {
  const edits: string[] = [];
  const gh: Gh = async (args) => {
    const key = args.join(" ");
    if (/^issue list -R o\/r -S no:label -L 5 /.test(key)) return ok(unlabelled.map((number) => ({ number })));
    if (/^issue edit /.test(key)) {
      edits.push(key);
      const n = Number(key.split(" ")[2]);
      return refuse.includes(n) ? no("denied") : ok("");
    }
    if (/^issue list/.test(key) || /^pr list/.test(key)) return ok([]);
    if (/^api graphql/.test(key)) return ok(EMPTY_QUEUE);
    return no(`unexpected ${key}`);
  };
  return { gh, edits };
}

describe("sweep triage", () => {
  it("labels the five oldest unlabelled issues in every repo that runs it", async () => {
    const { gh, edits } = triageGh([31, 32, 33, 34, 35], []);
    const lines: string[] = [];
    await sweep({ repo: "o/r", issue: "", closed: "" }, { gh, sleep: async () => {}, log: (l) => lines.push(l) });
    expect(edits).toEqual([31, 32, 33, 34, 35].map((n) => `issue edit ${n} -R o/r --add-label needs-triage`));
    expect(lines.filter((l) => l.startsWith("::warning::"))).toEqual([]);
  });

  it("a refused triage label is a warning, never a failed sweep", async () => {
    const { gh } = triageGh([31], [31]);
    const lines: string[] = [];
    const out = await sweep({ repo: "o/r", issue: "", closed: "" }, { gh, sleep: async () => {}, log: (l) => lines.push(l) });
    expect(lines.filter((l) => l.startsWith("::warning::"))).toEqual(["::warning::#31: triage label refused"]);
    expect(out.refs).toEqual([]);
  });

  it("a search that fails only warns", async () => {
    const lines: string[] = [];
    const gh: Gh = async (args) => {
      const key = args.join(" ");
      if (/^issue list -R o\/r -S no:label/.test(key)) return no("search unavailable");
      if (/^issue list/.test(key) || /^pr list/.test(key)) return ok([]);
      if (/^api graphql/.test(key)) return ok(EMPTY_QUEUE);
      return no(`unexpected ${key}`);
    };
    await sweep({ repo: "o/r", issue: "", closed: "" }, { gh, sleep: async () => {}, log: (l) => lines.push(l) });
    expect(lines.filter((l) => l.startsWith("::warning::"))).toEqual(["::warning::triage labelling failed"]);
  });
});

function claimGh(head: GhResult): { gh: Gh; edits: string[] } {
  const edits: string[] = [];
  const gh: Gh = async (args) => {
    const key = args.join(" ");
    if (/^issue list .*agent-in-progress/.test(key)) return ok([{ number: 11 }]);
    if (/^issue list/.test(key)) return ok([]);
    if (/^pr list .*--head/.test(key)) return head;
    if (/^pr list/.test(key)) return ok([]);
    if (/^issue view 11 /.test(key)) return ok({ comments: [{ body: "agent run started: https://github.com/o/r/actions/runs/99", createdAt: "x" }] });
    if (/^run view 99 /.test(key)) return ok({ status: "completed", jobs: [] });
    if (/^issue edit /.test(key)) {
      edits.push(key);
      return ok("");
    }
    if (/^api graphql/.test(key)) return ok(EMPTY_QUEUE);
    return no(`unexpected ${key}`);
  };
  return { gh, edits };
}

describe("sweep requeue of a dead claim", () => {
  it("a draft claim PR counts as no claim PR", async () => {
    const { gh, edits } = claimGh(ok([{ isDraft: false }]));
    await sweep({ repo: "o/r", issue: "", closed: "" }, { gh, ...quiet });
    expect(edits).toEqual([]);
  });

  it("only drafts left means the claim PR is gone", async () => {
    const { gh, edits } = claimGh(ok([{ isDraft: true }]));
    const out = await sweep({ repo: "o/r", issue: "", closed: "" }, { gh, ...quiet });
    expect(edits).toEqual(["issue edit 11 -R o/r --remove-label agent-in-progress --add-label agent-ready"]);
    expect(out.stalledRefs).toEqual(["claim/issue-11-miss-review"]);
  });

  it("a claim-PR read that fails skips the issue instead of aborting", async () => {
    const { gh, edits } = claimGh(no("gh: rate limited (HTTP 403)"));
    const out = await sweep({ repo: "o/r", issue: "", closed: "" }, { gh, ...quiet });
    expect(edits).toEqual([]);
    expect(out.stalledRefs).toEqual([]);
  });
});

function closedGh(dependents: Record<number, { labels: string[]; blocked_by: number }>): { gh: Gh; writes: string[]; logins: boolean[] } {
  const writes: string[] = [];
  const logins: boolean[] = [];
  const gh: Gh = async (args, opts) => {
    const key = args.join(" ");
    if (/\/dependencies\/blocking$/.test(key)) return ok([{ number: 2, state: "open" }, { number: 3, state: "closed" }]);
    if (/\/parent$/.test(key)) return no("no parent");
    const n = Number(/issues\/([0-9]+)$/.exec(key)?.[1] ?? "0");
    if (/^api repos\/o\/r\/issues\//.test(key)) {
      const d = dependents[n];
      if (d === undefined) return no("unexpected read");
      return ok(issue(n, "2026-10-27T00:00:00Z", d.labels, { issue_dependencies_summary: { blocked_by: d.blocked_by } }));
    }
    if (/^issue edit /.test(key)) {
      writes.push(key);
      logins.push(opts?.runnerLogin === true);
      return ok("");
    }
    return no(`unexpected ${key}`);
  };
  return { gh, writes, logins };
}

describe("sweep after a blocker closes", () => {
  it("re-fires the unblocked hand-off on the runner login, remove then add", async () => {
    const { gh, writes, logins } = closedGh({ 2: { labels: ["needs-orchestrator"], blocked_by: 0 } });
    await sweep({ repo: "o/r", issue: "", closed: "1" }, { gh, ...quiet });
    expect(writes).toEqual([
      "issue edit 2 -R o/r --remove-label needs-orchestrator",
      "issue edit 2 -R o/r --add-label needs-orchestrator",
    ]);
    expect(logins).toEqual([true, true]);
  });

  it("leaves a dependent that is still blocked alone", async () => {
    const { gh, writes } = closedGh({ 2: { labels: ["needs-orchestrator"], blocked_by: 3 } });
    await sweep({ repo: "o/r", issue: "", closed: "1" }, { gh, ...quiet });
    expect(writes).toEqual([]);
  });

  it("leaves an unblocked dependent with no parked label alone", async () => {
    const { gh, writes } = closedGh({ 2: { labels: ["agent-ready"], blocked_by: 0 } });
    const out = await sweep({ repo: "o/r", issue: "", closed: "1" }, { gh, ...quiet });
    expect(writes).toEqual([]);
    expect(out.refs).toEqual(["claim/issue-2"]);
  });

  it("a refused re-fire is a warning, never a failed sweep", async () => {
    const lines: string[] = [];
    const gh: Gh = async (args) => {
      const key = args.join(" ");
      if (/\/dependencies\/blocking$/.test(key)) return ok([{ number: 2, state: "open" }]);
      if (/\/parent$/.test(key)) return no("no parent");
      if (key === "api repos/o/r/issues/2") return ok(issue(2, "2026-10-27T00:00:00Z", ["needs-orchestrator"]));
      if (/^issue edit /.test(key)) return no("denied");
      return no(`unexpected ${key}`);
    };
    await sweep({ repo: "o/r", issue: "", closed: "1" }, { gh, sleep: async () => {}, log: (l) => lines.push(l) });
    expect(lines).toEqual(["::warning::#2: re-fire refused", "::warning::#2: re-fire refused"]);
  });
});
