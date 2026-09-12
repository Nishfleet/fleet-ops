// repair-queue-jump.mjs — fleet-ops#5810: a red-main repair PR must not
// self-deadlock behind the merge-queue entries whose group builds fail on
// the very bug it fixes. Live evidence 2026-09-12: FleetMainRed fired
// 04:07Z; the repair lane opened 0509#3191 at 04:58Z (green, mergeable) and
// armed auto-merge, which appended it to the END of a 14-entry merge queue
// whose every group build failed on the bug #3191 fixes. It sat for 57
// minutes until a human jumped it by hand (GraphQL dequeue + re-enqueue
// with jump:true at 05:55Z). That hand step is this file's job.
//
// Two entry points, one shared guard:
//
//   1. ARM TIME (reusable-auto-merge-arm.yml): when the PR being armed
//      carries a `repair:`-prefixed label (e.g. `repair:main-red`) and the
//      repo has a merge queue, arm via GraphQL enqueuePullRequest
//      (jump:true) instead of `gh pr merge --auto`. Non-queue repos and
//      non-repair PRs take the plain auto-merge path unchanged.
//   2. SWEEP SAFEGUARD (enqueue-green-prs.mjs backstop pass): when the
//      merge-queue HEAD entry has waited > 30 minutes and a repair-labelled
//      PR is queued behind it, jump the repair PR to the head. This covers
//      the `gh pr merge --auto` path (workers and other callers) that this
//      module cannot interpose on, plus any repair PR that entered the
//      queue before its `repair:` label stuck.
//
// Hard guarantees (the issue's `required:` bullets):
//   - ONLY repair-labelled PRs may jump. `isRepairPr` matches exactly the
//     `repair:` label prefix; nothing else is ever selected.
//   - jump:true NEVER bypasses required checks: it only moves the PR to the
//     front of the queue. The merge decision still runs the group build —
//     required checks and the branch-protection ruleset gate it exactly as
//     before.
//   - GraphQL budget is respected: one read query per repair-labelled PR
//     (the CLI's batched enqueue reads PR + queue in a single query) and
//     one mutation per actual jump; the sweep only enters this code for
//     repos that have at least one repair-labelled PR in the list it
//     already fetched.
//
// Environments (all seams overridable for tests):
//   GH            gh binary (default `gh`)
//   REPAIR_JUMP_DRY_RUN   set to 1 to resolve + log without mutating

import { execFileSync } from "node:child_process";

const REPAIR_LABEL_PREFIX = "repair:";
export const HEAD_WAIT_MS_DEFAULT = 30 * 60_000; // fleet-ops#5810: > 30 min

export function gh(args) {
  return execFileSync(process.env.GH || "gh", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

// isRepairPr LABELS — true only when a label name starts with `repair:`.
// This is the ONLY gate into a jump; any change to the acceptable set
// loosens the `required:` rule and must be reviewed as such.
export function isRepairPr(labels) {
  if (!labels) return false;
  const names = Array.isArray(labels)
    ? labels.map((l) => (typeof l === "string" ? l : l && l.name))
    : labels.nodes && labels.nodes.map((n) => n.name);
  if (!names) return false;
  return names.some((n) => typeof n === "string" && n.startsWith(REPAIR_LABEL_PREFIX));
}

// selectRepairJumps QUEUE_SNAPSHOT — pure. Given a merge-queue entries
// snapshot in the shape
//   { nodes: [ { state, enqueuedAt, pullRequest: { id, number,
//       labels: { nodes: [{ name }] } } } ] }
// (the GraphQL shape: `mergeQueue(branch:"main"){ entries(first:100)
//   { nodes{ state enqueuedAt pullRequest{ id number labels(first:20)
//   { nodes{ name } } } } } }`, returned head-first),
// return the repair-labelled QUEUED entries that must be re-enqueued with
// jump:true:
//   - the head of the queue has waited > 30 min (state waitedMs), AND
//   - the repair PR is queued BEHIND the head (jumping the head itself is a
//     no-op that burns a mutation), AND
//   - the repair PR itself has not already merged.
// Every queued repair-labelled entry behind a stale head is selected, in
// queue order; the caller must only jump ones that are still open.
export function selectRepairJumps(snapshot, { nowMs = Date.now(), headWaitMs = HEAD_WAIT_MS_DEFAULT } = {}) {
  const nodes = snapshot && snapshot.nodes ? snapshot.nodes : [];
  if (nodes.length === 0) return [];
  const head = nodes[0];
  const headEnqueued = head && head.enqueuedAt ? Date.parse(head.enqueuedAt) : NaN;
  const headWaited = Number.isFinite(headEnqueued) && nowMs - headEnqueued > headWaitMs;
  if (!headWaited) {
    return { jumped: [], waitedMs: Number.isFinite(headEnqueued) ? nowMs - headEnqueued : null, reason: "head-wait-within-budget" };
  }
  const headId = head && head.pullRequest && head.pullRequest.id;
  const jumped = [];
  for (const e of nodes.slice(1)) {
    if (!e || e.state !== "QUEUED") continue;
    const pr = e.pullRequest;
    if (!pr || !pr.id || pr.id === headId || pr.state === "MERGED") continue;
    if (!isRepairPr(pr.labels)) continue;
    jumped.push({ number: pr.number, id: pr.id });
  }
  return { jumped, waitedMs: nowMs - headEnqueued, reason: jumped.length ? "head-stale-jumping-repair" : "head-stale-no-repair" };
}

// REPAIR_JUMP_MUTATION — sent with the pullRequestId variable. jump:true
// only re-positions the PR at the head of the queue; the group build and
// the ruleset's required checks still gate the actual merge.
export const REPAIR_JUMP_MUTATION =
  'mutation($prId:ID!){ enqueuePullRequest(input:{pullRequestId:$prId, jump:true}){ clientMutationId } }';

// REPAIR_DEQUEUE_MUTATION — plain dequeue; GitHub errors when the PR is not
// in the queue, so the caller only issues this after observing the PR
// inside the queue snapshot.
export const REPAIR_DEQUEUE_MUTATION =
  'mutation($prId:ID!){ dequeuePullRequest(input:{pullRequestId:$prId}){ clientMutationId } }';

// PR_AND_QUEUE_QUERY — one read for both the PR node id + labels and the
// repo's merge-queue snapshot (GraphQL budget: 1 query per repair PR).
export const PR_AND_QUEUE_QUERY = `
query($owner:String!,$repo:String!,$branch:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){
    mergeQueue(branch:$branch){
      entries(first:100){ nodes{ state enqueuedAt pullRequest{ id number labels(first:20){ nodes{ name } } } } }
    }
    pullRequest(number:$pr){
      id
      labels(first:20){ nodes{ name } }
    }
  }
}`;

function ghJson(args) {
  return JSON.parse(gh(args) || "{}");
}

// enqueueRepairJump --repo OWNER/NAME --pr N [--branch main] [--dry-run]
//
// CLI used by the arm workflow (step "Arm auto-merge", repair branch) and
// reusable in drills. Resolves, evaluates, and performs the jump:
//   exit 0  jump performed (or resolved in --dry-run)
//   exit 3  PR is not repair-labelled -> caller must fall back to plain
//           auto-merge arming (never a silent skip: stderr says which)
//   exit 4  repo has no merge queue -> caller must fall back to plain
//           auto-merge arming
//   exit 1  PR already merged -> nothing to do (caller falls back to the
//           plain path, which exits cleanly when the PR is gone)
//   exit 2  gh/query failure (loud; do not fall back on this)
export function parseEnqueueArgs(argv) {
  const opts = { repo: null, pr: null, branch: "main", dryRun: process.env.REPAIR_JUMP_DRY_RUN === "1" || process.argv.includes("--dry-run") };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--repo") opts.repo = argv[++i];
    else if (argv[i] === "--pr") opts.pr = parseInt(argv[++i], 10);
    else if (argv[i] === "--branch") opts.branch = argv[++i];
    else if (argv[i] === "--apply") opts.dryRun = false;
    else if (argv[i] === "--dry-run") opts.dryRun = true;
    else if (argv[i] === "-h" || argv[i] === "--help") {
      console.error("usage: repair-queue-jump.mjs enqueue --repo OWNER/NAME --pr N [--branch main] [--apply|--dry-run]");
      process.exit(0);
    }
  }
  return opts;
}

export function enqueueRepairJump(opts) {
  if (!opts.repo || !opts.pr) {
    throw new Error("enqueueRepairJump requires --repo OWNER/NAME and --pr N");
  }
  const [owner, repo] = opts.repo.split("/");
  const raw = ghJson(["api", "graphql", "-f", `query=${PR_AND_QUEUE_QUERY}`, "-f", `owner=${owner}`, "-f", `repo=${repo}`, "-f", `branch=${opts.branch}`, "-F", `pr=${opts.pr}`]);
  const repository = raw && raw.data && raw.data.repository;
  if (!repository) {
    if (raw && raw.errors) process.stderr.write(`repair-queue-jump: query errors: ${JSON.stringify(raw.errors)}\n`);
    throw new Error("repository lookup failed");
  }
  const pr = repository.pullRequest;
  if (!pr) throw new Error(`${opts.repo}#${opts.pr} not found`);
  if (!isRepairPr(pr.labels)) {
    process.stderr.write(`repair-queue-jump: ${opts.repo}#${opts.pr} is not repair-labelled; falling back to plain auto-merge\n`);
    return { action: "fallback-no-repair-label", code: 3 };
  }
  const snapshot = repository.mergeQueue;
  if (!snapshot) {
    process.stderr.write(`repair-queue-jump: ${opts.repo} has no merge queue on ${opts.branch}; falling back to plain auto-merge\n`);
    return { action: "fallback-no-queue", code: 4 };
  }
  const nodes = snapshot.entries && snapshot.entries.nodes ? snapshot.entries.nodes : [];
  // Arm-time semantics: a repair-labelled PR is ALWAYS re-enqueued at the
  // head with jump:true (the #3191 deadlock is independent of head age —
  // a 14-entry queue that fails groups on the bug it fixes is a dead wait
  // from minute 0). Jump = dequeue-if-queued + enqueue(jump:true), exactly
  // the hand step the orchestrator ran on #3191 at 05:55Z. The 30-min
  // safeguard rides separately on the sweep (selectRepairJumps).
  const prId = pr.id;
  const inQueue = nodes.some((n) => n && n.pullRequest && n.pullRequest.id === prId && n.state === "QUEUED");
  if (pr.state === "MERGED") {
    // state moved elsewhere (_merged or left the queue) — nothing to do.
    process.stderr.write(`repair-queue-jump: ${opts.repo}#${opts.pr} already merged; nothing to do\n`);
    return { action: "nothing", code: 1 };
  }
  if (opts.dryRun) {
    process.stdout.write(`repair-queue-jump: dry-run ${inQueue ? "dequeue+" : ""}enqueue(jump:true) ${opts.repo}#${opts.pr} (id ${prId})\n`);
    return { action: "jumped-dry-run", code: 0, inQueue };
  }
  if (inQueue) {
    gh(["api", "graphql", "-f", `query=${REPAIR_DEQUEUE_MUTATION}`, "-f", `prId=${prId}`]);
  }
  gh(["api", "graphql", "-f", `query=${REPAIR_JUMP_MUTATION}`, "-f", `prId=${prId}`]);
  process.stdout.write(`repair-queue-jump: ${inQueue ? "dequeue + re-" : ""}enqueued ${opts.repo}#${opts.pr} at the head of the ${opts.branch} merge queue (jump:true) — required checks still gate the merge\n`);
  return { action: "jumped", code: 0, inQueue };
}

export function main() {
  const opts = parseEnqueueArgs(process.argv.slice(2));
  try {
    const r = enqueueRepairJump(opts);
    process.exit(r.code);
  } catch (e) {
    process.stderr.write(`repair-queue-jump FAILED: ${e.message}\n`);
    process.exit(2);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
