import type { ExtensionAPI, MessageEndEvent, ToolResultEvent } from "@earendil-works/pi-coding-agent";
import { createTokenRedact } from "../index.ts";

type Handlers = {
  tool_result: ((event: ToolResultEvent) => unknown)[];
  message_end: ((event: MessageEndEvent) => unknown)[];
};

export const fakePi = (): { api: ExtensionAPI; handlers: Handlers } => {
  const handlers: Handlers = { tool_result: [], message_end: [] };
  const api = {
    on(event: "tool_result" | "message_end", handler: (value: never) => unknown) {
      handlers[event].push(handler as never);
      return () => undefined;
    },
  } as unknown as ExtensionAPI;
  return { api, handlers };
};

export const load = (env: Record<string, string | undefined> = {}) => {
  const { api, handlers } = fakePi();
  createTokenRedact(api, { env });
  return handlers;
};

export const toolResultEvent = (over: Partial<ToolResultEvent> = {}): ToolResultEvent =>
  ({
    type: "tool_result",
    toolCallId: "call-1",
    toolName: "bash",
    input: { command: "echo" },
    content: [{ type: "text", text: "ok" }],
    isError: false,
    ...over,
  }) as ToolResultEvent;

export const messageEndEvent = (message: unknown): MessageEndEvent =>
  ({ type: "message_end", message }) as MessageEndEvent;
