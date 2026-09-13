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
//   1. ENTRY JUMP (`enqueue` subcommand): a repair-labelled PR
//      (`repair:` prefix, e.g. `repair:main-red`) on a merge-queue repo is
//      enqueued with jump:true — at the head — instead of plain
//      `gh pr merge --auto` tail-append. Repair workers run this after
//      arming (the alert-repair packet instructs it); the heartbeat queue
//      pass runs it after arming a labelled PR; a human can run it by hand.
//      If the PR is already queued mid-queue it is dequeued and re-enqueued
//      at the head — the exact hand step run on #3191.
//   2. SWEEP SAFEGUARD (`sweep` subcommand, run by fleet-heartbeat-tier1
//      block 2b): when the merge-queue HEAD entry has waited > 30 minutes
//      and a repair-labelled PR is queued behind it, jump the repair PR to
//      the head. Covers every arm path this module cannot interpose on
//      (the lean inlined auto-merge-arm.yml on consumer repos, a plain
//      `gh pr merge --auto` by hand, a label that landed after queueing).
//      The same sweep directly enqueues a green repair PR that is not yet
//      in the queue (the issue's primary path, reconciler-side).
//
// Hard guarantees (the issue's `required:` bullets):
//   - ONLY repair-labelled PRs may jump. `isRepairPr` matches exactly the
//     `repair:` label prefix; `blocked-by-judge` and `no-auto-merge` (and
//     `[no-merge]` titles) are refused even when a repair label is present.
//   - jump:true NEVER bypasses required checks: it only moves the PR to the
//     front of the queue. The merge decision still runs the group build —
//     required checks and the branch-protection ruleset gate it exactly as
//     before.
//   - GraphQL budget is respected: the sweep spends one `gh pr list` read
//     per repo per tick and only touches the merge-queue endpoint when a
//     repair-labelled open PR exists; one read + at most two mutations per
//     jumped PR.
//
// Environments (all seams overridable for tests):
//   GH            gh binary (default `gh`)
//   REPAIR_JUMP_DRY_RUN   set to 1 to resolve + log without mutating
//   REPAIR_JUMP_NOW_MS    fixed "now" (epoch ms) for the sweep head-age check

import { execFileSync } from "node:child_process";

const REPAIR_LABEL_PREFIX = "repair:";
// Labels that forbid a jump even on a repair-labelled PR: a judge block must
// never be jumped past (fleet-ops#4557 teeth) and no-auto-merge is the
// standing arm opt-out.
const JUMP_BLOCK_LABELS = new Set(["blocked-by-judge", "no-auto-merge"]);
export const HEAD_WAIT_MS_DEFAULT = 30 * 60_000; // fleet-ops#5810: > 30 min
// Queue-entry states that mean "still waiting to merge" — repositionable.
// UNMERGEABLE needs a code fix, not a jump; MERGEABLE/LOCKED are already at
// the merge step.
const WAITING_STATES = new Set(["QUEUED", "AWAITING_CHECKS"]);

export function gh(args) {
  return execFileSync(process.env.GH || "gh", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

function ghJson(args) {
  return JSON.parse(gh(args) || "{}");
}

function labelNames(labels) {
  if (!labels) return [];
  if (Array.isArray(labels)) {
    return labels.map((l) => (typeof l === "string" ? l : l && l.name)).filter((n) => typeof n === "string");
  }
  if (labels.nodes) return labels.nodes.map((n) => n.name).filter((n) => typeof n === "string");
  return [];
}

// isRepairPr LABELS — true only when a label name starts with `repair:`.
// This is the ONLY gate into a jump; any change to the acceptable set
// loosens the `required:` rule and must be reviewed as such.
export function isRepairPr(labels) {
  return labelNames(labels).some((n) => n.startsWith(REPAIR_LABEL_PREFIX));
}

// isJumpBlocked LABELS — a repair-labelled PR carrying a block label must
// NOT jump. Same posture as the queue pass: a block has teeth.
export function isJumpBlocked(labels) {
  return labelNames(labels).some((n) => JUMP_BLOCK_LABELS.has(n));
}

// selectRepairJumps QUEUE_SNAPSHOT — pure. Given a merge-queue entries
// snapshot in the shape
//   { nodes: [ { state, enqueuedAt, pullRequest: { id, number, state,
//       labels: { nodes: [{ name }] } } } ] }
// (the GraphQL shape: `mergeQueue(branch:"main"){ entries(first:100)
//   { nodes{ state enqueuedAt pullRequest{ id number state labels(first:20)
//   { nodes{ name } } } } } }`, returned head-first),
// return the repair-labelled waiting entries that must be re-enqueued with
// jump:true:
//   - the head of the queue has waited > headWaitMs (default 30 min), AND
//   - the repair PR is queued BEHIND the head (jumping the head itself is a
//     no-op that burns a mutation), AND
//   - the repair PR's entry is in a waiting state (QUEUED or
//     AWAITING_CHECKS — not UNMERGEABLE/MERGEABLE/LOCKED), AND
//   - the PR is still OPEN and carries no jump-block label.
// Always returns { jumped, waitedMs, reason }.
export function selectRepairJumps(snapshot, { nowMs = Date.now(), headWaitMs = HEAD_WAIT_MS_DEFAULT } = {}) {
  const nodes = snapshot && snapshot.nodes ? snapshot.nodes : [];
  if (nodes.length === 0) return { jumped: [], waitedMs: null, reason: "queue-empty" };
  const head = nodes[0];
  const headEnqueued = head && head.enqueuedAt ? Date.parse(head.enqueuedAt) : NaN;
  const headWaited = Number.isFinite(headEnqueued) && nowMs - headEnqueued > headWaitMs;
  if (!headWaited) {
    return { jumped: [], waitedMs: Number.isFinite(headEnqueued) ? nowMs - headEnqueued : null, reason: "head-wait-within-budget" };
  }
  const headId = head && head.pullRequest && head.pullRequest.id;
  const jumped = [];
  for (const e of nodes.slice(1)) {
    if (!e || !WAITING_STATES.has(e.state)) continue;
    const pr = e.pullRequest;
    if (!pr || !pr.id || pr.id === headId) continue;
    if (pr.state && pr.state !== "OPEN") continue;
    if (!isRepairPr(pr.labels) || isJumpBlocked(pr.labels)) continue;
    jumped.push({ number: pr.number, id: pr.id, state: e.state });
  }
  return {
    jumped,
    waitedMs: nowMs - headEnqueued,
    reason: jumped.length ? "head-stale-jumping-repair" : "head-stale-no-repair",
  };
}

// REPAIR_JUMP_MUTATION — sent with the pullRequestId variable. jump:true
// only re-positions the PR at the head of the queue; the group build and
// the ruleset's required checks still gate the actual merge. Field names
// verified against the live schema 2026-09-12: EnqueuePullRequestInput
// carries pullRequestId + jump; DequeuePullRequestInput carries `id`.
export const REPAIR_JUMP_MUTATION =
  'mutation($prId:ID!){ enqueuePullRequest(input:{pullRequestId:$prId, jump:true}){ clientMutationId } }';

// REPAIR_DEQUEUE_MUTATION — plain dequeue; GitHub errors when the PR is not
// in the queue, so the caller only issues this after observing the PR
// inside the queue snapshot. The input field is `id` (the pull-request node
// id), NOT pullRequestId — verified 2026-09-12 against DequeuePullRequestInput.
export const REPAIR_DEQUEUE_MUTATION =
  'mutation($prId:ID!){ dequeuePullRequest(input:{id:$prId}){ clientMutationId } }';

// PR_AND_QUEUE_QUERY — one read for both the PR node id + state + labels
// and the repo's merge-queue snapshot (GraphQL budget: 1 query per PR).
export const PR_AND_QUEUE_QUERY = `
query($owner:String!,$repo:String!,$branch:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){
    mergeQueue(branch:$branch){
      entries(first:100){ nodes{ state enqueuedAt position pullRequest{ id number state labels(first:20){ nodes{ name } } } } }
    }
    pullRequest(number:$pr){
      id
      state
      labels(first:20){ nodes{ name } }
    }
  }
}`;

// QUEUE_SNAPSHOT_QUERY — the sweep's read: queue entries only. One per repo
// per tick, spent ONLY when an open repair-labelled PR exists.
export const QUEUE_SNAPSHOT_QUERY = `
query($owner:String!,$repo:String!,$branch:String!){
  repository(owner:$owner,name:$repo){
    mergeQueue(branch:$branch){
      entries(first:100){ nodes{ state enqueuedAt position pullRequest{ id number state labels(first:20){ nodes{ name } } } } }
    }
  }
}`;

function splitRepo(repo) {
  const [owner, name] = String(repo || "").split("/");
  if (!owner || !name) throw new Error(`--repo must be OWNER/NAME, got "${repo}"`);
  return { owner, name };
}

// All repair-labelled open PRs on a repo (any head branch — repair PRs are
// opened on fix/*, revert/*, claim/* alike). One REST list call.
export function listRepairPrs(repo) {
  const raw = ghJson([
    "pr", "list", "--repo", repo, "--state", "open", "--limit", "100",
    "--json", "number,title,isDraft,labels",
  ]);
  const prs = Array.isArray(raw) ? raw : [];
  return prs.filter(
    (pr) => isRepairPr(pr.labels) && !isJumpBlocked(pr.labels) && !pr.isDraft
      && !(pr.title && pr.title.includes("[no-merge]")),
  );
}

// prChecksGreen — every check bucket must be pass (block-2 parity). No
// checks at all is NOT green (a repair PR on a queue repo always has them).
function prChecksGreen(repo, prNumber) {
  let raw;
  try {
    raw = ghJson(["pr", "checks", String(prNumber), "--repo", repo, "--json", "name,bucket,state"]);
  } catch {
    return { green: false, error: "gh pr checks failed" };
  }
  if (!Array.isArray(raw) || raw.length === 0) return { green: false, error: "no checks" };
  const failing = raw.filter((c) => c.bucket === "fail");
  const pending = raw.filter((c) => c.bucket === "pending");
  return { green: failing.length === 0 && pending.length === 0, failing: failing.length, pending: pending.length };
}

// queueEntryFor — the PR's own merge-queue entry in a snapshot, if any.
function queueEntryFor(snapshot, prId) {
  const nodes = snapshot && snapshot.entries && snapshot.entries.nodes ? snapshot.entries.nodes : [];
  return nodes.find((n) => n && n.pullRequest && n.pullRequest.id === prId) || null;
}

// jumpPr — dequeue-if-queued + enqueue(jump:true). The exact hand step the
// orchestrator ran on #3191 at 05:55Z. dry-run logs instead of mutating.
function jumpPr(repo, pr, entry, opts) {
  const inQueue = entry && WAITING_STATES.has(entry.state);
  if (opts.dryRun) {
    process.stdout.write(`repair-queue-jump: dry-run ${inQueue ? "dequeue+" : ""}enqueue(jump:true) ${repo}#${pr.number} (id ${pr.id})\n`);
    return { action: "jumped-dry-run", inQueue: Boolean(inQueue) };
  }
  if (inQueue) {
    gh(["api", "graphql", "-f", `query=${REPAIR_DEQUEUE_MUTATION}`, "-f", `prId=${pr.id}`]);
  }
  gh(["api", "graphql", "-f", `query=${REPAIR_JUMP_MUTATION}`, "-f", `prId=${pr.id}`]);
  process.stdout.write(`repair-queue-jump: ${inQueue ? "dequeue + re-" : ""}enqueued ${repo}#${pr.number} at the head of the merge queue (jump:true) — required checks still gate the merge\n`);
  return { action: "jumped", inQueue: Boolean(inQueue) };
}

// enqueueRepairJump --repo OWNER/NAME --pr N [--branch main] [--dry-run]
//
// Arm-time/entry jump. Resolves the PR + queue in one read, then:
//   exit 0  jump performed (or already at head / merging — nothing to do),
//           or resolved in --dry-run
//   exit 1  PR already merged — nothing to do
//   exit 3  PR is not repair-labelled — caller takes the plain arm path
//   exit 4  repo has no merge queue — caller takes the plain arm path
//   exit 5  jump not applicable right now (enqueue rejected: not ready /
//           blocked label) — caller takes the plain arm path
//   exit 2  gh/query failure (loud; do not silently fall back on this)
export function enqueueRepairJump(opts) {
  if (!opts.repo || !opts.pr) {
    throw new Error("enqueueRepairJump requires --repo OWNER/NAME and --pr N");
  }
  const { owner, name } = splitRepo(opts.repo);
  const raw = ghJson(["api", "graphql", "-f", `query=${PR_AND_QUEUE_QUERY}`, "-f", `owner=${owner}`, "-f", `repo=${name}`, "-f", `branch=${opts.branch}`, "-F", `pr=${opts.pr}`]);
  const repository = raw && raw.data && raw.data.repository;
  if (!repository) {
    if (raw && raw.errors) process.stderr.write(`repair-queue-jump: query errors: ${JSON.stringify(raw.errors)}\n`);
    throw new Error("repository lookup failed");
  }
  const pr = repository.pullRequest;
  if (!pr || !pr.id) throw new Error(`${opts.repo}#${opts.pr} not found`);
  if (pr.state === "MERGED" || pr.state === "CLOSED") {
    process.stderr.write(`repair-queue-jump: ${opts.repo}#${opts.pr} already ${String(pr.state).toLowerCase()}; nothing to do\n`);
    return { action: "nothing", code: 1 };
  }
  if (!isRepairPr(pr.labels)) {
    process.stderr.write(`repair-queue-jump: ${opts.repo}#${opts.pr} is not repair-labelled; falling back to plain auto-merge\n`);
    return { action: "fallback-no-repair-label", code: 3 };
  }
  if (isJumpBlocked(pr.labels)) {
    process.stderr.write(`repair-queue-jump: ${opts.repo}#${opts.pr} carries a jump-block label (blocked-by-judge / no-auto-merge); not jumping\n`);
    return { action: "fallback-jump-blocked", code: 5 };
  }
  const snapshot = repository.mergeQueue;
  if (!snapshot) {
    process.stderr.write(`repair-queue-jump: ${opts.repo} has no merge queue on ${opts.branch}; falling back to plain auto-merge\n`);
    return { action: "fallback-no-queue", code: 4 };
  }
  const entry = queueEntryFor(snapshot, pr.id);
  if (entry && !WAITING_STATES.has(entry.state)) {
    // MERGEABLE/LOCKED: already at the merge step. UNMERGEABLE: a jump does
    // not fix it — it needs code work. Either way there is nothing to do.
    process.stderr.write(`repair-queue-jump: ${opts.repo}#${opts.pr} queue entry is ${entry.state}; nothing to do\n`);
    return { action: `in-queue-${String(entry.state).toLowerCase()}`, code: 0 };
  }
  if (entry && entry.position === 1) {
    process.stderr.write(`repair-queue-jump: ${opts.repo}#${opts.pr} is already at the head; nothing to do\n`);
    return { action: "already-head", code: 0 };
  }
  try {
    const r = jumpPr(opts.repo, { number: opts.pr, id: pr.id }, entry, opts);
    return { ...r, code: 0 };
  } catch (e) {
    // The enqueue/dequeue was refused (checks pending, unmergeable, rate
    // limit). The caller's plain auto-merge arm is the correct floor —
    // report the reason and let it proceed. The hourly sweep retries.
    const why = (e.stderr && String(e.stderr).trim()) || e.message;
    process.stderr.write(`repair-queue-jump: ${opts.repo}#${opts.pr} enqueue refused: ${why}; falling back to plain auto-merge\n`);
    return { action: "fallback-enqueue-refused", code: 5 };
  }
}

// sweepRepairQueue --repo OWNER/NAME [--branch main] [--apply|--dry-run]
//
// fleet-ops#5810 second safeguard, reconciler-side (fleet-heartbeat-tier1
// block 2b). Per repo per tick:
//   1. List open repair-labelled PRs (any head). None -> no queue query at
//      all (the App rate-limit budget bullet).
//   2. Snapshot the merge queue once. Repair-labelled entries queued behind
//      a head that has waited > 30 min are jumped (dequeue + enqueue
//      jump:true).
//   3. A repair-labelled PR that is NOT in the queue but has all-green
//      checks is enqueued directly with jump:true — the issue's primary
//      path ("enqueued with jump:true once its own checks are green").
// Returns a report; exit code is 2 only when the queue could not be read at
// all (loud for the heartbeat log), 0 otherwise.
export function sweepRepairQueue(opts) {
  const { owner, name } = splitRepo(opts.repo);
  const report = { repo: opts.repo, jumped: [], skipped: [], notes: [] };
  const repairPrs = listRepairPrs(opts.repo);
  report.repairPrs = repairPrs.map((p) => p.number);
  if (repairPrs.length === 0) {
    report.notes.push("no repair-labelled open PRs — queue untouched");
    return report;
  }
  const raw = ghJson(["api", "graphql", "-f", `query=${QUEUE_SNAPSHOT_QUERY}`, "-f", `owner=${owner}`, "-f", `repo=${name}`, "-f", `branch=${opts.branch}`]);
  const repository = raw && raw.data && raw.data.repository;
  if (!repository) {
    if (raw && raw.errors) process.stderr.write(`repair-queue-jump sweep: query errors: ${JSON.stringify(raw.errors)}\n`);
    throw new Error("repository lookup failed");
  }
  const snapshot = repository.mergeQueue;
  if (!snapshot) {
    report.notes.push("no merge queue — nothing to sweep");
    return report;
  }
  const nowMs = process.env.REPAIR_JUMP_NOW_MS ? Number(process.env.REPAIR_JUMP_NOW_MS) : Date.now();
  const result = selectRepairJumps(snapshot.entries, { nowMs });
  report.headWaitedMs = result.waitedMs;
  report.reason = result.reason;
  const byPrId = new Map();
  for (const entry of snapshot.entries && snapshot.entries.nodes ? snapshot.entries.nodes : []) {
    if (entry && entry.pullRequest && entry.pullRequest.id) byPrId.set(entry.pullRequest.id, entry);
  }
  for (const j of result.jumped || []) {
    try {
      const r = jumpPr(opts.repo, j, byPrId.get(j.id) || { state: j.state }, opts);
      report.jumped.push({ pr: j.number, action: r.action });
    } catch (e) {
      report.skipped.push({ pr: j.number, reason: `jump-failed: ${(e.stderr && String(e.stderr).trim()) || e.message}` });
    }
  }
  // Primary path: a green repair PR that never made it into the queue gets
  // enqueued at the head directly.
  const queuedIds = new Set((snapshot.entries && snapshot.entries.nodes ? snapshot.entries.nodes : [])
    .map((n) => n && n.pullRequest && n.pullRequest.id).filter(Boolean));
  for (const pr of repairPrs) {
    const detail = ghJson(["pr", "view", String(pr.number), "--repo", opts.repo, "--json", "id,state"]);
    if (!detail || !detail.id || detail.state !== "OPEN") continue;
    if (queuedIds.has(detail.id)) {
      if (!(result.jumped || []).some((j) => j.number === pr.number)) {
        report.skipped.push({ pr: pr.number, reason: result.reason });
      }
      continue;
    }
    const checks = prChecksGreen(opts.repo, pr.number);
    if (!checks.green) {
      report.skipped.push({ pr: pr.number, reason: `not-green: ${checks.error || `fail=${checks.failing} pending=${checks.pending}`}` });
      continue;
    }
    try {
      const r = jumpPr(opts.repo, { number: pr.number, id: detail.id }, null, opts);
      report.jumped.push({ pr: pr.number, action: r.action, via: "enqueue-green" });
    } catch (e) {
      report.skipped.push({ pr: pr.number, reason: `enqueue-refused: ${(e.stderr && String(e.stderr).trim()) || e.message}` });
    }
  }
  return report;
}

export function parseArgs(argv) {
  const opts = { command: null, repo: null, pr: null, branch: "main", dryRun: process.env.REPAIR_JUMP_DRY_RUN === "1" };
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--repo") opts.repo = argv[++i];
    else if (argv[i] === "--pr") opts.pr = parseInt(argv[++i], 10);
    else if (argv[i] === "--branch") opts.branch = argv[++i];
    else if (argv[i] === "--apply") opts.dryRun = false;
    else if (argv[i] === "--dry-run") opts.dryRun = true;
    else if (argv[i] === "-h" || argv[i] === "--help") {
      console.error("usage: repair-queue-jump.mjs enqueue --repo OWNER/NAME --pr N [--branch main] [--apply|--dry-run]\n       repair-queue-jump.mjs sweep   --repo OWNER/NAME [--branch main] [--apply|--dry-run]");
      process.exit(0);
    } else positional.push(argv[i]);
  }
  opts.command = positional[0] || "enqueue";
  return opts;
}

export function main() {
  const opts = parseArgs(process.argv.slice(2));
  try {
    if (opts.command === "sweep") {
      if (!opts.repo) throw new Error("sweep requires --repo OWNER/NAME");
      const report = sweepRepairQueue(opts);
      process.stdout.write(`${JSON.stringify(report)}\n`);
      process.exit(0);
    }
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
