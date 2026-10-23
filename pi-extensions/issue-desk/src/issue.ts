import { countRecent, withStateLock } from "./cap.ts";
import { loadIntake, NEVER_REPO } from "./config.ts";
import type { Runner } from "./exec.ts";
import { clip, firstLine, plain, quoteAuthority, singleLine } from "./text.ts";

export const TITLE_MAX = 120;
export const BODY_MAX = 8000;

export const INTAKE_LABEL = "needs-triage";

export const ISSUE_URL = /https:\/\/github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\/issues\/\d+/;

export const RELAYED_BY = "relayed-by: issue-desk (not written by Nish)";

export const footerFor = (
  requestId: string,
  sender: string,
  chain: readonly string[],
): string => {
  const trail = chain.length > 0 ? chain.join(" > ") : sender;
  return [
    "",
    "---",
    "",
    `tincan-request: ${requestId}`,
    `requested-by: ${sender}`,
    RELAYED_BY,
    `chain: ${trail}`,
  ].join("\n");
};

export const composeBody = (
  body: string,
  requestId: string,
  sender: string,
  chain: readonly string[],
): string => `${quoteAuthority(plain(body)).trim()}\n${footerFor(requestId, sender, chain)}`;

export const issueUrlFrom = (stdout: string): string => {
  const match = stdout.match(ISSUE_URL);
  if (match === null) {
    throw new Error(
      `gh issue create did not return an issue URL: ${clip(firstLine(stdout), 200) || "no output"}`,
    );
  }
  return match[0];
};

export const hasMarker = (body: string, requestId: string): boolean => {
  const lines = body.trimEnd().split("\n");
  const last = lines.slice(-4);
  return (
    last.length === 4 &&
    last[0].trim() === `tincan-request: ${requestId}` &&
    last[1].trim().startsWith("requested-by: ") &&
    last[2].trim() === RELAYED_BY &&
    last[3].trim().startsWith("chain: ")
  );
};

export interface FileIssueDeps {
  run: Runner;
  env: Record<string, string | undefined>;
  gh: string;
  repoRoot: string;
  stateDir: string;
  maxPerDay: number;
  now: () => number;
}

export interface FileIssueInput {
  requestId: string;
  sender: string;
  chain: readonly string[];
  repo: string;
  title: string;
  body: string;
}

export interface FileIssueResult {
  url: string;
  created: boolean;
}

const assertAllowedRepo = async (repoRoot: string, repo: string): Promise<void> => {
  if (repo === NEVER_REPO) {
    throw new Error(
      `${NEVER_REPO} is never accepted: this desk files product issues only, and control-plane work enters as a scoped packet.`,
    );
  }
  const allowed = await loadIntake(repoRoot);
  if (!allowed.includes(repo)) {
    throw new Error(
      `repo ${JSON.stringify(repo)} is not on the allowlist. Use exactly one of: ${allowed.join(", ")}.`,
    );
  }
};

const existing = async (
  deps: FileIssueDeps,
  repo: string,
  requestId: string,
): Promise<string | null> => {
  const result = await deps.run(
    deps.gh,
    [
      "issue",
      "list",
      "--repo",
      `Nishfleet/${repo}`,
      "--state",
      "all",
      "--search",
      `${requestId} in:body`,
      "--json",
      "number,url,body",
      "--limit",
      "20",
    ],
    { env: deps.env },
  );
  if (result.code !== 0) {
    throw new Error(
      `could not check ${repo} for an existing issue (gh exit ${result.code}): ${clip(firstLine(result.stderr), 300) || "no output"}`,
    );
  }
  const found = JSON.parse(result.stdout || "[]") as Array<{
    url?: unknown;
    body?: unknown;
  }>;
  const hit = found.find(
    (issue) => typeof issue.body === "string" && hasMarker(issue.body, requestId),
  );
  return typeof hit?.url === "string" ? hit.url : null;
};

const create = async (
  deps: FileIssueDeps,
  input: FileIssueInput,
  title: string,
  body: string,
): Promise<string> => {
  const result = await deps.run(
    deps.gh,
    [
      "issue",
      "create",
      "--repo",
      `Nishfleet/${input.repo}`,
      "--label",
      INTAKE_LABEL,
      "--title",
      title,
      "--body",
      body,
    ],
    { env: deps.env },
  );
  if (result.code !== 0) {
    throw new Error(
      `gh issue create failed (exit ${result.code}): ${clip(firstLine(result.stderr), 300) || "no output"}`,
    );
  }
  return issueUrlFrom(result.stdout);
};

export const fileIssue = async (
  deps: FileIssueDeps,
  input: FileIssueInput,
): Promise<FileIssueResult> => {
  await assertAllowedRepo(deps.repoRoot, input.repo);

  const title = singleLine(input.title);
  if (title === "") throw new Error("title is empty. Write a one-line title.");
  if (title.length > TITLE_MAX) {
    throw new Error(
      `title is ${title.length} characters and the limit is ${TITLE_MAX}. Shorten it and call file_issue again.`,
    );
  }

  if (plain(input.body).trim() === "") {
    throw new Error("body is empty. Write what is wrong or wanted, and why.");
  }

  const body = composeBody(input.body, input.requestId, input.sender, input.chain);
  if (body.length > BODY_MAX) {
    throw new Error(
      `the issue body would be ${body.length} characters and the limit is ${BODY_MAX}. Shorten it and call file_issue again.`,
    );
  }

  return withStateLock(deps.stateDir, async (state) => {
    const known = state.records
      .filter((record) => record.request_id === input.requestId)
      .at(-1);
    if (known !== undefined) {
      if (known.url === "") {
        throw new Error(
          `an earlier attempt to file request ${input.requestId} in Nishfleet/${known.repo} did not finish, so it is unknown whether the issue exists. Do not file it again; tell the sender a person must check Nishfleet/${known.repo} first.`,
        );
      }
      return { url: known.url, created: false };
    }

    const found = await existing(deps, input.repo, input.requestId);
    if (found !== null) {
      await state.append({
        at: new Date(deps.now()).toISOString(),
        request_id: input.requestId,
        repo: input.repo,
        url: found,
      });
      return { url: found, created: false };
    }

    const used = countRecent(state.records, deps.now());
    if (used >= deps.maxPerDay) {
      throw new Error(
        `daily cap reached: ${used} issues filed in the last 24 hours and the limit is ${deps.maxPerDay}. File nothing more; reply to the request with this refusal.`,
      );
    }

    await state.append({
      at: new Date(deps.now()).toISOString(),
      request_id: input.requestId,
      repo: input.repo,
      url: "",
    });
    const url = await create(deps, input, title, body);
    await state.append({
      at: new Date(deps.now()).toISOString(),
      request_id: input.requestId,
      repo: input.repo,
      url,
    });
    return { url, created: true };
  });
};

export const reply = async (
  run: Runner,
  tincan: string,
  env: Record<string, string | undefined>,
  requestId: string,
  text: string,
): Promise<void> => {
  const message = text.trim();
  if (message === "") throw new Error("reply text is empty.");
  const result = await run(tincan, ["reply", requestId, "--", message], { env });
  if (result.code !== 0) {
    throw new Error(
      `tincan reply failed (exit ${result.code}): ${clip(firstLine(result.stderr), 300) || "no output"}`,
    );
  }
};
