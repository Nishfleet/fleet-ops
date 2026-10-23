import type { ExtensionAPI, MessageEndEvent, ToolResultEvent } from "@earendil-works/pi-coding-agent";
import { redactJson, redactText } from "./src/shapes.ts";

const OFF = new Set(["0", "false", "no", "off"]);

export interface TokenRedactOptions {
  env?: Record<string, string | undefined>;
}

type Block = Record<string, unknown>;

const isBlock = (value: unknown): value is Block =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const redactBlock = (block: unknown): unknown => {
  if (!isBlock(block)) {
    return block;
  }
  if (block.type === "text" && typeof block.text === "string") {
    return { ...block, text: redactText(block.text) };
  }
  if (block.type === "thinking" && typeof block.thinking === "string") {
    return { ...block, thinking: redactText(block.thinking) };
  }
  if (block.type === "toolCall") {
    const out: Block = { ...block };
    if (isBlock(out.arguments)) {
      out.arguments = redactJson(out.arguments) as Block;
    }
    if (typeof out.argumentsError === "string") {
      out.argumentsError = redactText(out.argumentsError);
    }
    return out;
  }
  return block;
};

const redactContent = (content: unknown): unknown => {
  if (typeof content === "string") {
    return redactText(content);
  }
  if (Array.isArray(content)) {
    return content.map((block) => redactBlock(block));
  }
  return content;
};

const sameJson = (a: unknown, b: unknown): boolean => {
  try {
    return JSON.stringify(a) === JSON.stringify(b);
  } catch {
    return false;
  }
};

export const createTokenRedact = (pi: ExtensionAPI, options: TokenRedactOptions = {}): void => {
  const env = options.env ?? process.env;
  const switchValue = (env.TOKEN_REDACT ?? "").trim().toLowerCase();
  if (OFF.has(switchValue)) {
    return;
  }

  pi.on("tool_result", (event: ToolResultEvent) => {
    const result: Record<string, unknown> = {};
    const content = redactContent(event.content);
    if (!sameJson(content, event.content)) {
      result.content = content;
    }
    if (event.structuredContent !== undefined) {
      const structured = redactJson(event.structuredContent);
      if (!sameJson(structured, event.structuredContent)) {
        result.structuredContent = structured;
      }
    }
    if (event.details !== undefined) {
      const details = redactJson(event.details);
      if (!sameJson(details, event.details)) {
        result.details = details;
      }
    }
    return Object.keys(result).length > 0 ? result : undefined;
  });

  pi.on("message_end", (event: MessageEndEvent) => {
    const message = event.message as unknown as Block;
    const content = redactContent(message.content);
    if (sameJson(content, message.content)) {
      return undefined;
    }
    return { message: { ...message, content } as unknown as MessageEndEvent["message"] };
  });
};

export default function tokenRedact(pi: ExtensionAPI): void {
  createTokenRedact(pi, {});
}
