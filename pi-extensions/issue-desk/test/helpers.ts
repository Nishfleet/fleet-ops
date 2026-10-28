import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { ExecResult, Runner } from "../src/exec.ts";

export interface Call {
  file: string;
  args: string[];
}

export interface Scripted {
  calls: Call[];
  run: Runner;
}

export type Answer = (file: string, args: string[]) => Partial<ExecResult> | undefined;

export const combine =
  (...answers: Answer[]): Answer =>
  (file, args) => {
    for (const answer of answers) {
      const result = answer(file, args);
      if (result !== undefined) return result;
    }
    return undefined;
  };

export const tempRoot = (): Promise<string> => mkdtemp(join(tmpdir(), "issue-desk-"));

export const writeIntake = async (
  root: string,
  repos: Array<{ name: string; product?: boolean }>,
): Promise<string> => {
  await mkdir(join(root, "config"), { recursive: true });
  await writeFile(
    join(root, "config", "intake-repos.json"),
    JSON.stringify({ repos }),
    "utf8",
  );
  return root;
};

export const scripted = (answer: Answer): Scripted => {
  const calls: Call[] = [];
  const run: Runner = async (file, args) => {
    const list = [...args];
    calls.push({ file, args: list });
    const result = answer(file, list);
    if (result === undefined) {
      return {
        code: 1,
        stdout: "",
        stderr: `unexpected call: ${file} ${list.join(" ")}`,
      };
    }
    return { code: 0, stdout: "", stderr: "", ...result };
  };
  return { calls, run };
};

export const ghCreate =
  (url: string): Answer =>
  (file, args) =>
    args[0] === "issue" && args[1] === "create"
      ? { code: 0, stdout: `${url}\n` }
      : undefined;

export const ghList =
  (issues: Array<{ url: string; body: string }>): Answer =>
  (file, args) =>
    args[0] === "issue" && args[1] === "list"
      ? { code: 0, stdout: JSON.stringify(issues) }
      : undefined;

export const tincanInbox =
  (requests: unknown[]): Answer =>
  (file, args) =>
    args[0] === "inbox"
      ? { code: 0, stdout: JSON.stringify({ requests }) }
      : undefined;

export const tincanReply =
  (code = 0, stderr = ""): Answer =>
  (file, args) =>
    args[0] === "reply" ? { code, stderr, stdout: "" } : undefined;

export interface Tool {
  name: string;
  label: string;
  description: string;
  parameters: unknown;
  execute: (
    toolCallId: string,
    params: Record<string, unknown>,
    signal?: AbortSignal,
    onUpdate?: unknown,
    ctx?: unknown,
  ) => Promise<{ content: Array<{ type: string; text: string }>; details: unknown }>;
}

export const fakePi = (): {
  pi: ExtensionAPI;
  tools: Map<string, Tool>;
} => {
  const tools = new Map<string, Tool>();
  const pi = {
    registerTool: (tool: Tool) => {
      tools.set(tool.name, tool);
    },
  } as unknown as ExtensionAPI;
  return { pi, tools };
};

export const textOf = (result: {
  content: Array<{ type: string; text: string }>;
}): string => result.content.map((part) => part.text).join("\n");
