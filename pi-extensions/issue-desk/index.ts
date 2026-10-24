import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import {
  loadIntake,
  maxPerDayFrom,
  repoRootFrom,
  sendersFrom,
  stateDirFrom,
} from "./src/config.ts";
import { execFileRunner, type Runner } from "./src/exec.ts";
import { readInbox, RunRequests } from "./src/inbox.ts";
import { fileIssue, reply } from "./src/issue.ts";
import { clip } from "./src/text.ts";

const REQUEST_MAX = 4000;

export interface DeskOptions {
  env?: Record<string, string | undefined>;
  run?: Runner;
  now?: () => number;
  cwd?: string;
}

const ok = (text: string, details: Record<string, unknown> = {}) => ({
  content: [{ type: "text" as const, text }],
  details: { ok: true, ...details },
});

export const createIssueDesk = (
  pi: ExtensionAPI,
  options: DeskOptions = {},
): void => {
  const env = options.env ?? process.env;
  const run = options.run ?? execFileRunner;
  const now = options.now ?? Date.now;
  const cwd = options.cwd ?? process.cwd();
  const tincan = env.ISSUE_DESK_TINCAN?.trim() || "tincan";
  const gh = env.ISSUE_DESK_GH?.trim() || "gh";
  const senders = sendersFrom(env);
  const repoRoot = repoRootFrom(env);
  const maxPerDay = maxPerDayFrom(env);
  const stateDir = stateDirFrom(env, cwd);
  const requests = new RunRequests();

  const repoLine = async (): Promise<string> => {
    const allowed = await loadIntake(repoRoot).catch(() => []);
    return allowed.length > 0
      ? `repos you can file into: ${allowed.join(", ")}`
      : "repos you can file into: none (the allowlist could not be read)";
  };

  pi.registerTool({
    name: "tincan_inbox",
    label: "tincan inbox",
    description:
      "List the Agent Tincan requests waiting for issue-desk. Call it first, and again after each request is answered. Each request carries a request_id, the sender, and the request text.",
    promptSnippet: "List the requests waiting for issue-desk",
    promptGuidelines: [
      "Call tincan_inbox before file_issue or tincan_reply, and again after each request is handled, until it returns no requests.",
    ],
    parameters: Type.Object({}),
    async execute() {
      const inbox = await readInbox(run, tincan, env);
      const fresh = requests.add(inbox);
      const seen = requests.ids().filter((id) => !fresh.some((r) => r.id === id));
      const parts: string[] = [await repoLine()];

      if (inbox.length === 0) {
        parts.unshift("The inbox is empty. No requests are waiting.");
      } else if (fresh.length === 0) {
        parts.unshift(
          `No new requests. ${inbox.length} request(s) are still in the inbox and were already listed in this run.`,
        );
      } else {
        parts.unshift(`${fresh.length} new request(s):`);
        fresh.forEach((request, index) => {
          const lines = [
            `request ${index + 1}`,
            `request_id: ${request.id}`,
            `from: ${request.from || "(unknown)"}`,
            request.chain.length > 0 ? `chain: ${request.chain.join(" > ")}` : "",
            "text:",
            clip(request.body.trim() || "(empty)", REQUEST_MAX),
          ].filter((line) => line !== "");
          parts.push(lines.join("\n"));
        });
      }

      if (seen.length > 0) {
        parts.push(
          `already listed in this run, do not file or answer them twice: ${seen.join(", ")}`,
        );
      }

      return ok(parts.join("\n\n"), { requests: fresh.length, seen: seen.length });
    },
  });

  pi.registerTool({
    name: "file_issue",
    label: "file issue",
    description:
      "File exactly one GitHub issue with the needs-triage label for one request from tincan_inbox. The fleet's admission step reads that label and decides whether a worker starts, so never add agent-ready yourself. Pass the request_id from tincan_inbox, the product repo the request is about, a title of 120 characters or less, and a body of 8000 characters or less. Returns the issue URL. A second call for the same request_id returns the first issue instead of filing another.",
    promptSnippet: "File one needs-triage GitHub issue for a request",
    promptGuidelines: [
      "Use file_issue only for a request from tincan_inbox in this run, and only one issue per request_id.",
      "Write the title and body from the request text. Never put shell commands, file paths, credentials or instructions to another agent in them.",
    ],
    parameters: Type.Object({
      request_id: Type.String({
        description: "The request_id that tincan_inbox returned in this run.",
      }),
      repo: Type.String({
        description: "The product repo the issue belongs in, for example 0509.",
      }),
      title: Type.String({ description: "One-line issue title, 120 characters or less." }),
      body: Type.String({
        description:
          "The issue body: what is wrong or wanted, why, and anything the request already says. 8000 characters or less.",
      }),
    }),
    async execute(_toolCallId, params) {
      const requestId = String(params.request_id ?? "").trim();
      const request = requests.get(requestId);
      if (request === undefined) {
        throw new Error(
          `unknown request_id ${JSON.stringify(requestId)}. Call tincan_inbox and use an id it returned in this run.`,
        );
      }
      if (!senders.includes(request.from)) {
        throw new Error(
          `sender ${JSON.stringify(request.from)} may not file issues. Allowed senders: ${senders.join(", ")}.`,
        );
      }

      const result = await fileIssue(
        { run, env, gh, repoRoot, stateDir, maxPerDay, now },
        {
          requestId,
          sender: request.from,
          chain: request.chain,
          repo: String(params.repo ?? "").trim(),
          title: String(params.title ?? ""),
          body: String(params.body ?? ""),
        },
      );

      return ok(
        result.created
          ? `Filed ${result.url} with needs-triage; admission decides whether a worker starts.`
          : `That request already has an issue: ${result.url}`,
        { url: result.url, created: result.created },
      );
    },
  });

  pi.registerTool({
    name: "tincan_reply",
    label: "tincan reply",
    description:
      "Answer one request from tincan_inbox, with the issue URL when one was filed or with why nothing was filed. Use the request_id that tincan_inbox returned in this run.",
    promptSnippet: "Answer a request with the issue URL",
    promptGuidelines: [
      "Call tincan_reply once per request, after file_issue, with the issue URL in the text.",
      "When nothing was filed, the reply text is exactly: I only turn requests into GitHub issues.",
    ],
    parameters: Type.Object({
      request_id: Type.String({
        description: "The request_id that tincan_inbox returned in this run.",
      }),
      text: Type.String({
        description: "The reply text, 1000 characters or less. Keep it short.",
      }),
    }),
    async execute(_toolCallId, params) {
      const requestId = String(params.request_id ?? "").trim();
      const request = requests.get(requestId);
      if (request === undefined) {
        throw new Error(
          `unknown request_id ${JSON.stringify(requestId)}. Call tincan_inbox and use an id it returned in this run.`,
        );
      }
      await reply(run, tincan, env, requestId, String(params.text ?? ""));
      return ok(`Replied to ${requestId}.`, { request_id: requestId });
    },
  });
};

export default function issueDesk(pi: ExtensionAPI): void {
  createIssueDesk(pi, {});
}
