import { describe, expect, it } from "vitest";
import indexSource from "../index.ts?raw";
import { REDACTED_PREFIX } from "../src/shapes.ts";
import { load, messageEndEvent, toolResultEvent } from "./helpers.ts";

const GITHUB = "ghp_" + "CANARYNOTREAL0000000000";
const ANTHROPIC = "sk-ant-" + "CANARY" + "NOTREAL6666666666666666";
const NPM = "npm_" + "CANARYNOTREAL999999999999999999999999";

describe("loading", () => {
  it("registers the two persistence hooks and nothing else", () => {
    const handlers = load();
    expect(handlers.tool_result.length).toBe(1);
    expect(handlers.message_end.length).toBe(1);
  });

  it("registers no tool, command or flag", () => {
    for (const name of ["registerTool", "registerCommand", "registerFlag", "registerShortcut"]) {
      expect(indexSource).not.toContain(`pi.${name}`);
    }
  });

  for (const value of ["off", "OFF", "0", "false", "no", " off "]) {
    it(`registers nothing when TOKEN_REDACT=${JSON.stringify(value)}`, () => {
      const handlers = load({ TOKEN_REDACT: value });
      expect(handlers.tool_result.length).toBe(0);
      expect(handlers.message_end.length).toBe(0);
    });
  }

  for (const value of ["", "on", "1", "true", "yes", undefined]) {
    it(`registers both hooks when TOKEN_REDACT=${JSON.stringify(value)}`, () => {
      const handlers = load({ TOKEN_REDACT: value });
      expect(handlers.tool_result.length).toBe(1);
      expect(handlers.message_end.length).toBe(1);
    });
  }
});

describe("tool_result", () => {
  it("redacts a token in the text content", () => {
    const handlers = load();
    const out = handlers.tool_result[0](toolResultEvent({ content: [{ type: "text", text: GITHUB }] })) as {
      content: { type: string; text: string }[];
    };
    expect(out.content[0].text).toBe(`${REDACTED_PREFIX}store-github-token]`);
  });

  it("redacts structuredContent and details together with the content", () => {
    const handlers = load();
    const out = handlers.tool_result[0](
      toolResultEvent({
        content: [{ type: "text", text: `set ${ANTHROPIC}` }],
        structuredContent: { key: ANTHROPIC, nested: [ANTHROPIC] },
        details: { command: `curl -H ${GITHUB}`, ok: true },
      }),
    ) as {
      content: { type: string; text: string }[];
      structuredContent: Record<string, unknown>;
      details: Record<string, unknown>;
    };
    expect(out.content[0].text).toBe(`set ${REDACTED_PREFIX}store-anthropic-key]`);
    expect(JSON.stringify(out.structuredContent)).not.toContain(ANTHROPIC);
    expect(JSON.stringify(out.details)).not.toContain(GITHUB);
    expect(out.details.ok).toBe(true);
  });

  it("keeps structuredContent when only the text changed", () => {
    const handlers = load();
    const out = handlers.tool_result[0](
      toolResultEvent({
        content: [{ type: "text", text: GITHUB }],
        structuredContent: { ok: true },
      }),
    ) as Record<string, unknown>;
    expect(out.structuredContent).toEqual({ ok: true });
    expect(out.content).toBeDefined();
  });

  it("keeps structuredContent when only the details changed", () => {
    const handlers = load();
    const out = handlers.tool_result[0](
      toolResultEvent({
        content: [{ type: "text", text: "ok" }],
        structuredContent: { ok: true },
        details: { command: `curl -H ${GITHUB}` },
      }),
    ) as Record<string, unknown>;
    expect(out.structuredContent).toEqual({ ok: true });
    expect(out.content).toBeUndefined();
    expect(JSON.stringify(out.details)).not.toContain(GITHUB);
  });

  it("returns nothing when the result holds no shape", () => {
    const handlers = load();
    expect(handlers.tool_result[0](toolResultEvent())).toBeUndefined();
  });

  it("leaves an image block alone", () => {
    const handlers = load();
    const image = { type: "image", data: "AAAA", mimeType: "image/png" };
    expect(handlers.tool_result[0](toolResultEvent({ content: [image] }))).toBeUndefined();
  });
});

describe("message_end", () => {
  it("redacts a user message written as a plain string", () => {
    const handlers = load();
    const out = handlers.message_end[0](messageEndEvent({ role: "user", content: GITHUB })) as {
      message: { role: string; content: string };
    };
    expect(out.message.role).toBe("user");
    expect(out.message.content).toBe(`${REDACTED_PREFIX}store-github-token]`);
  });

  it("redacts assistant text and thinking", () => {
    const handlers = load();
    const out = handlers.message_end[0](
      messageEndEvent({
        role: "assistant",
        content: [
          { type: "thinking", thinking: `the key is ${ANTHROPIC}` },
          { type: "text", text: `I read ${GITHUB}` },
        ],
      }),
    ) as { message: { role: string; content: Record<string, string>[] } };
    expect(out.message.role).toBe("assistant");
    expect(out.message.content[0].thinking).toBe(`the key is ${REDACTED_PREFIX}store-anthropic-key]`);
    expect(out.message.content[1].text).toBe(`I read ${REDACTED_PREFIX}store-github-token]`);
  });

  it("redacts a toolCall parse error text and leaves its arguments alone", () => {
    const handlers = load();
    const toolArgs = { command: `echo ${NPM}` };
    const out = handlers.message_end[0](
      messageEndEvent({
        role: "assistant",
        content: [
          {
            type: "toolCall",
            id: "call-1",
            name: "bash",
            arguments: toolArgs,
            argumentsError: `the model sent ${GITHUB}`,
          },
        ],
      }),
    ) as { message: { content: Record<string, unknown>[] } };
    const call = out.message.content[0];
    expect(call.arguments).toBe(toolArgs);
    expect(call.argumentsError).toBe(`the model sent ${REDACTED_PREFIX}store-github-token]`);
  });

  it("leaves a toolCall with parseable arguments untouched", () => {
    const handlers = load();
    const toolArgs = { command: `echo ${GITHUB}` };
    const out = handlers.message_end[0](
      messageEndEvent({
        role: "assistant",
        content: [{ type: "toolCall", id: "call-1", name: "bash", arguments: toolArgs }],
      }),
    ) as { message: { content: Record<string, unknown>[] } } | undefined;
    expect(out).toBeUndefined();
  });

  it("redacts a toolResult message", () => {
    const handlers = load();
    const out = handlers.message_end[0](
      messageEndEvent({
        role: "toolResult",
        toolCallId: "call-1",
        toolName: "bash",
        content: [{ type: "text", text: `stdout: ${GITHUB}` }],
        isError: false,
      }),
    ) as { message: { role: string; content: { text: string }[] } };
    expect(out.message.role).toBe("toolResult");
    expect(out.message.content[0].text).toBe(`stdout: ${REDACTED_PREFIX}store-github-token]`);
  });

  it("redacts a system message written as a plain string", () => {
    const handlers = load();
    const out = handlers.message_end[0](messageEndEvent({ role: "system", content: ANTHROPIC })) as {
      message: { role: string; content: string };
    };
    expect(out.message.content).toBe(`${REDACTED_PREFIX}store-anthropic-key]`);
  });

  it("keeps every other field of the message", () => {
    const handlers = load();
    const out = handlers.message_end[0](
      messageEndEvent({
        role: "assistant",
        model: "claude-opus-5-5",
        usage: { input: 1, output: 2 },
        stopReason: "stop",
        content: [{ type: "text", text: GITHUB }],
      }),
    ) as { message: Record<string, unknown> };
    expect(out.message.model).toBe("claude-opus-5-5");
    expect(out.message.stopReason).toBe("stop");
    expect(out.message.usage).toEqual({ input: 1, output: 2 });
  });

  it("returns nothing when the message holds no shape", () => {
    const handlers = load();
    expect(handlers.message_end[0](messageEndEvent({ role: "user", content: "hello" }))).toBeUndefined();
    expect(handlers.message_end[0](messageEndEvent({ role: "assistant", content: [] }))).toBeUndefined();
  });
});
