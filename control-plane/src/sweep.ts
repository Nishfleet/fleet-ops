import { execFile } from "node:child_process";
import { appendFileSync } from "node:fs";

export interface GhResult {
  code: number;
  stdout: string;
  stderr: string;
}
export type Gh = (args: string[]) => Promise<GhResult>;

export const ghCli: Gh = (args) =>
  new Promise((resolve) => {
    execFile("gh", args, { maxBuffer: 64 * 1024 * 1024, encoding: "utf8" }, (error, stdout, stderr) => {
      const code = error === null ? 0 : typeof error.code === "number" ? error.code : 1;
      resolve({ code, stdout, stderr: stderr || error?.message || "" });
    });
  });

const SKIP_LABELS = ["agent-blocked", "needs-split", "needs-orchestrator", "needs-nish-decision", "epic"];
const FAILED = ["FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"];
const LIVE = ["queued", "in_progress", "waiting", "pending", "requested"];

interface Check {
  status?: string | null;
  state?: string | null;
  conclusion?: string | null;
  completedAt?: string | null;
  startedAt?: string | null;
}
interface Pr {
  headRefName?: string;
  mergeStateStatus?: string;
  statusCheckRollup?: Check[] | null;
}
interface Label {
  name: string;
}
interface Issue {
  number: number;
  state?: string;
  created_at?: string;
  labels: Label[];
  issue_dependencies_summary?: { blocked_by?: number };
}
interface Comment {
  body: string;
  createdAt: string;
}
interface RunView {
  status?: string;
  jobs?: { name: string; status: string }[];
}

const isPending = (c: Check): boolean => (c.status != null && c.status !== "COMPLETED") || c.state === "PENDING";
const isFailed = (c: Check): boolean => FAILED.includes(c.conclusion ?? "") || ["FAILURE", "ERROR"].includes(c.state ?? "");

export function runLive(rv: RunView, ref: string): boolean {
  const work = (rv.jobs ?? []).filter((j) => j.name.endsWith("/ work"));
  const mine = work.filter((j) => j.name.includes(`(${ref})`));
  const jobs = mine.length > 0 ? mine : work;
  return jobs.length > 0 ? jobs.some((j) => LIVE.includes(j.status)) : LIVE.includes(rv.status ?? "");
}

export function redRework(input: { pr: Pr; issue: Issue; comments: Comment[] }): { reason: string; run: string } {
  const { pr, issue, comments } = input;
  const checks = pr.statusCheckRollup ?? [];
  const stamps = checks
    .filter(isFailed)
    .map((c) => c.completedAt ?? c.startedAt)
    .filter((t): t is string => typeof t === "string")
    .map((t) => Date.parse(t) / 1000);
  const failedAt = stamps.length > 0 ? Math.max(...stamps) : null;
  const infra = comments
    .filter((c) => c.body.startsWith("agent run infra-failed: "))
    .map((c) => c.body.slice("agent run infra-failed: ".length));
  const started = comments.filter(
    (c) => c.body.startsWith("agent run started: ") && !infra.includes(c.body.slice("agent run started: ".length)),
  );
  const newest = started.at(-1);
  let reason: string;
  if (failedAt === null) reason = "not-red";
  else if (checks.some(isPending)) reason = "pending";
  else if (pr.mergeStateStatus === "DIRTY") reason = "conflicting";
  else if (issue.state !== "open") reason = "closed";
  else if ((issue.issue_dependencies_summary?.blocked_by ?? 0) !== 0) reason = "blocked";
  else if (issue.labels.some((l) => SKIP_LABELS.includes(l.name))) reason = "label";
  else if (newest !== undefined && Date.parse(newest.createdAt) / 1000 >= failedAt) reason = "run-after-failure";
  else reason = "go";
  return { reason, run: newest?.body ?? "" };
}

export interface Env {
  repo: string;
  issue: string;
  closed: string;
  output?: string;
}
export interface Deps {
  gh: Gh;
  sleep: (ms: number) => Promise<void>;
  log: (line: string) => void;
}

const sweepGone = Symbol("gone");

export async function sweep(env: Env, deps: Deps): Promise<{ refs: string[]; stalledRefs: string[] }> {
  const { gh, sleep, log } = deps;
  const { repo } = env;

  const json = async <T>(args: string[]): Promise<T> => {
    const r = await gh(args);
    if (r.code !== 0) throw new Error(`gh ${args.slice(0, 3).join(" ")} failed: ${r.stderr.trim()} ${r.stdout.trim()}`);
    return JSON.parse(r.stdout) as T;
  };
  const issueJson = async (n: string | number): Promise<Issue | typeof sweepGone> => {
    const r = await gh(["api", `repos/${repo}/issues/${n}`]);
    if (r.code === 0) return JSON.parse(r.stdout) as Issue;
    let status = "";
    try {
      status = String((JSON.parse(r.stdout) as { status?: unknown }).status ?? "");
    } catch {
      status = "";
    }
    if (/^(404|410)$/.test(status) || /\(HTTP (404|410)\)/.test(r.stderr)) return sweepGone;
    throw new Error(`#${n}: issue read failed: ${r.stderr.trim()} ${r.stdout.trim()}`);
  };
  const runOf = async (body: string): Promise<RunView | null> => {
    const id = /actions\/runs\/([0-9]+)/.exec(body)?.[1];
    return id === undefined ? null : json<RunView>(["run", "view", id, "-R", repo, "--json", "status,jobs"]);
  };
  const startedBody = async (n: string | number): Promise<string> => {
    const view = await json<{ comments: Comment[] }>(["issue", "view", String(n), "-R", repo, "--json", "comments"]);
    return view.comments.map((c) => c.body).filter((b) => b.startsWith("agent run started:")).at(-1) ?? "";
  };
  const prView = (n: number | string, fields: string) => json<Pr>(["pr", "view", String(n), "-R", repo, "--json", fields]);
  const labelNames = (x: { labels: Label[] }): string[] => x.labels.map((l) => l.name);

  const stalled: string[] = [];
  let nums: (string | number)[] = [];
  let prs: string[] = [];

  if (env.issue !== "") {
    nums = [env.issue];
  } else if (env.closed !== "") {
    const blocking = async (n: string | number) =>
      (await json<{ number: number; state: string }[]>(["api", `repos/${repo}/issues/${n}/dependencies/blocking`]))
        .filter((i) => i.state === "open")
        .map((i) => i.number);
    nums = await blocking(env.closed);
    let c: string | number = env.closed;
    for (;;) {
      const up = await gh(["api", `repos/${repo}/issues/${c}/parent`]);
      if (up.code !== 0) break;
      const p = (JSON.parse(up.stdout) as { number: number }).number;
      const pr = await gh(["api", `repos/${repo}/issues/${p}`]);
      if (pr.code !== 0) break;
      const parent = JSON.parse(pr.stdout) as Issue & { sub_issues_summary: { total: number; completed: number } };
      const names = labelNames(parent);
      if (parent.state !== "open" || parent.sub_issues_summary.total - parent.sub_issues_summary.completed !== 0) break;
      if (names.includes("critical-path") || names.includes("epic")) break;
      const closeRes = await gh(["issue", "close", String(p), "-R", repo, "-r", "completed", "-c", `every sub-issue is closed, the last was #${c}; closing the parent`]);
      if (closeRes.code !== 0) throw new Error(`closing parent #${p} failed: ${closeRes.stderr.trim()}`);
      nums.push(...(await blocking(p)));
      c = p;
    }
  } else {
    const inProgress = (await json<{ number: number }[]>(["issue", "list", "-R", repo, "-l", "agent-in-progress", "-L", "1000", "--json", "number"])).map((i) => i.number);
    for (const n of inProgress) {
      const open = await json<unknown[]>(["pr", "list", "-R", repo, "--head", `claim/issue-${n}`, "--state", "open", "--json", "number"]);
      if (open.length !== 0) continue;
      const body = await startedBody(n);
      if (!/actions\/runs\/[0-9]+/.test(body)) continue;
      let rv: RunView | null;
      try {
        rv = await runOf(body);
      } catch {
        log(`::warning::#${n}: run read failed, skip`);
        continue;
      }
      if (rv !== null && !runLive(rv, `claim/issue-${n}`)) {
        const edit = await gh(["issue", "edit", String(n), "-R", repo, "--remove-label", "agent-in-progress", "--add-label", "agent-ready"]);
        if (edit.code !== 0) throw new Error(`requeue of #${n} failed: ${edit.stderr.trim()}`);
        log(`requeued #${n}: claimed with no live run and no claim PR`);
        stalled.push(`claim/issue-${n}-miss-review`);
      }
    }
    nums = (await json<{ number: number }[]>(["issue", "list", "-R", repo, "-l", "agent-ready", "-L", "1000", "--json", "number"])).map((i) => i.number);

    type ClaimPr = { number: number; headRefName: string; autoMergeRequest: unknown; isDraft: boolean; isCrossRepository: boolean; mergeable: string; labels: Label[] };
    const all = (await json<ClaimPr[]>(["pr", "list", "-R", repo, "-L", "1000", "--json", "number,headRefName,autoMergeRequest,isDraft,isCrossRepository,mergeable,labels"])).filter(
      (p) => p.headRefName.startsWith("claim/issue-") && !p.isDraft,
    );
    const [owner, name] = repo.split("/");
    const q = await gh(["api", "graphql", "-f", `query=query{repository(owner:"${owner}",name:"${name}"){mergeQueue{entries(first:100){nodes{pullRequest{headRefName}}}}}}`]);
    if (q.code !== 0) {
      log("::warning::merge-queue read failed; skipping all claim-PR re-dispatch this run");
    } else {
      const nodes = (JSON.parse(q.stdout) as { data: { repository: { mergeQueue: { entries: { nodes?: { pullRequest?: { headRefName?: string } }[] } } } } }).data.repository.mergeQueue.entries.nodes ?? [];
      const queued = nodes.map((x) => x.pullRequest?.headRefName).filter((r): r is string => r !== undefined);
      const armed = all.filter((p) => p.autoMergeRequest != null);
      const unarmed = all.filter((p) => p.autoMergeRequest == null && !labelNames(p).includes("needs-coordinator")).map((p) => p.headRefName);

      const conflicted: string[] = [];
      for (const p of armed.filter((x) => x.mergeable !== "MERGEABLE")) {
        let v = await prView(p.number, "headRefName,mergeable") as Pr & { mergeable: string };
        for (let i = 1; i < 3 && v.mergeable === "UNKNOWN"; i++) {
          await sleep(10_000);
          v = (await prView(p.number, "headRefName,mergeable")) as Pr & { mergeable: string };
        }
        if (v.mergeable === "CONFLICTING") conflicted.push(v.headRefName as string);
      }

      const missing: string[] = [];
      for (const p of armed) {
        const v = await prView(p.number, "headRefName,statusCheckRollup,mergeStateStatus");
        const checks = v.statusCheckRollup ?? [];
        if (v.mergeStateStatus === "BLOCKED" && !checks.some(isPending) && !checks.some(isFailed)) missing.push(v.headRefName as string);
      }

      const inprog = new Set(inProgress);
      const orphans: string[] = [];
      for (const p of all) {
        const n = /^claim\/issue-([0-9]+)$/.exec(p.headRefName)?.[1];
        if (n === undefined || labelNames(p).includes("needs-coordinator") || !inprog.has(Number(n))) continue;
        const body = await startedBody(n);
        if (body === "") {
          orphans.push(`claim/issue-${n}`);
          continue;
        }
        const rv = await runOf(body);
        if (rv === null) throw new Error(`agent run started comment on #${n} has no run id`);
        if (!runLive(rv, `claim/issue-${n}`)) orphans.push(`claim/issue-${n}`);
      }

      const red: string[] = [];
      for (const p of all.filter((x) => !x.isCrossRepository && /^claim\/issue-[0-9]+$/.test(x.headRefName))) {
        const v = await prView(p.number, "headRefName,statusCheckRollup,mergeStateStatus");
        const ref = v.headRefName as string;
        if (queued.includes(ref)) continue;
        const n = ref.slice("claim/issue-".length);
        const issue = await issueJson(n);
        if (issue === sweepGone) {
          log(`#${n}: issue gone, skipping claim PR ${p.number}`);
          continue;
        }
        const comments = (await json<{ comments: Comment[] }>(["issue", "view", n, "-R", repo, "--json", "comments"])).comments;
        const verdict = redRework({ pr: v, issue, comments });
        if (verdict.reason !== "go") continue;
        const rv = await runOf(verdict.run);
        if (rv !== null && runLive(rv, ref)) {
          log(`#${n}: run live, skip`);
          continue;
        }
        red.push(ref);
      }

      prs = [...new Set([...unarmed, ...conflicted, ...missing, ...orphans, ...red])].filter((r) => !queued.includes(r));
      log(`claim PRs missing required checks: ${JSON.stringify(missing)}`);
      log(`claim PRs with a dead agent run: ${JSON.stringify(orphans)}`);
      log(`claim PRs red with no rework since: ${JSON.stringify(red)}`);
      log(`claim PRs picked by the sweep: ${JSON.stringify(prs)}`);
    }
  }

  const pages: Issue[] = [];
  for (const n of new Set(nums)) {
    const i = await issueJson(n);
    if (i === sweepGone) log(`#${n}: issue gone, skipping`);
    else pages.push(i);
  }
  const rank = (i: Issue) => (labelNames(i).includes("priority-now") ? 0 : 1);
  const first = pages
    .filter((i) => i.issue_dependencies_summary?.blocked_by === 0 && labelNames(i).includes("agent-ready"))
    .filter((i) => !labelNames(i).some((l) => SKIP_LABELS.includes(l)))
    .sort((a, b) => rank(a) - rank(b) || (a.created_at ?? "").localeCompare(b.created_at ?? ""))
    .map((i) => `claim/issue-${i.number}`);
  const refs = [...first, ...prs.filter((r) => !first.includes(r))].slice(0, 256);
  return { refs, stalledRefs: stalled };
}

if (import.meta.main) {
  const repo = process.env.GITHUB_REPOSITORY ?? "";
  const out = await sweep(
    { repo, issue: process.env.ISSUE ?? "", closed: process.env.CLOSED ?? "" },
    { gh: ghCli, sleep: (ms) => new Promise((r) => setTimeout(r, ms)), log: (l) => console.log(l) },
  );
  appendFileSync(process.env.GITHUB_OUTPUT ?? (() => { throw new Error("GITHUB_OUTPUT is not set"); })(), `refs=${JSON.stringify(out.refs)}\nstalled_refs=${JSON.stringify(out.stalledRefs)}\n`);
}
