import type { Runner } from "./exec.ts";
import { firstLine } from "./text.ts";

export interface InboxRequest {
  id: string;
  from: string;
  chain: string[];
  body: string;
  claimed: boolean;
}

const asStrings = (value: unknown): string[] =>
  Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];

export const parseInbox = (stdout: string): InboxRequest[] => {
  const text = stdout.trim();
  if (text === "") return [];
  const doc = JSON.parse(text) as { requests?: unknown };
  const requests = Array.isArray(doc.requests) ? doc.requests : [];
  return requests.flatMap((entry) => {
    const request = entry as Record<string, unknown> | null;
    const id = typeof request?.id === "string" ? request.id.trim() : "";
    if (id === "") return [];
    return [
      {
        id,
        from: typeof request?.from === "string" ? request.from : "",
        chain: asStrings(request?.chain),
        body: typeof request?.body === "string" ? request.body : "",
        claimed: request?.claimed === true,
      },
    ];
  });
};

export const readInbox = async (
  run: Runner,
  tincan: string,
  env: Record<string, string | undefined>,
): Promise<InboxRequest[]> => {
  const result = await run(tincan, ["inbox", "--json"], { env });
  if (result.code !== 0) {
    throw new Error(
      `tincan inbox failed (exit ${result.code}): ${firstLine(result.stderr) || "no output"}`,
    );
  }
  return parseInbox(result.stdout);
};

export class RunRequests {
  readonly #seen = new Map<string, InboxRequest>();

  add(requests: readonly InboxRequest[]): InboxRequest[] {
    const fresh = requests.filter((request) => !this.#seen.has(request.id));
    for (const request of fresh) this.#seen.set(request.id, request);
    return fresh;
  }

  get(id: string): InboxRequest | undefined {
    return this.#seen.get(id);
  }

  ids(): string[] {
    return [...this.#seen.keys()];
  }

  get size(): number {
    return this.#seen.size;
  }
}
