import { describe, expect, it } from "vitest";
import {
  REDACTED_PREFIX,
  TOKEN_SHAPES,
  TOKEN_SHAPE_IDS,
  redactJson,
  redactText,
  shapeRegex,
} from "../src/shapes.ts";

const FAKE = {
  github: "ghp_" + "CANARYNOTREAL0000000000",
  githubOauth: "gho_" + "CANARYNOTREAL1111111111",
  githubApp: "ghs_" + "CANARYNOTREAL2222222222",
  githubUserToServer: "ghu_" + "CANARYNOTREAL3333333333",
  githubRefresh: "ghr_" + "CANARYNOTREAL4444444444",
  fineGrained: "github_pat_" + "CANARYNOTREAL" + "_5555555555555555",
  anthropic: "sk-ant-" + "CANARY" + "NOTREAL6666666666666666",
  gitlab: "glpat-" + "CANARYNOTREAL7777777777",
  slack: "xoxb-" + "CANARY" + "NOTREAL" + "8888888888",
  npm: "npm_" + "CANARYNOTREAL999999999999999999999999",
  githubWords: "ghp_" + "FAKE_TEST_TOKEN_DO_NOT_USE_0000000000",
};

const EVERY = Object.values(FAKE);

describe("token shapes", () => {
  it("every shape id is unique", () => {
    expect(new Set(TOKEN_SHAPE_IDS).size).toBe(TOKEN_SHAPE_IDS.length);
  });

  it("every shape has keywords, a label and a non-empty token pattern", () => {
    for (const shape of TOKEN_SHAPES) {
      expect(shape.label.length).toBeGreaterThan(0);
      expect(shape.keywords.length).toBeGreaterThan(0);
      expect(shape.token).not.toMatch(/[()\\]/);
      expect(shape.chars).not.toMatch(/[()\\]/);
      expect(shapeRegex(shape).test("")).toBe(false);
    }
  });

  it("the placeholder never matches a shape", () => {
    const all = TOKEN_SHAPES.map((shape) => `${REDACTED_PREFIX}${shape.id}]`).join(" ");
    expect(redactText(all)).toBe(all);
  });
});

describe("redactText", () => {
  it("replaces each fake token with its shape id", () => {
    for (const token of EVERY) {
      const out = redactText(`before ${token} after`);
      expect(out).not.toContain(token);
      expect(out.startsWith("before ")).toBe(true);
      expect(out.endsWith(" after")).toBe(true);
    }
  });

  it("names the shape it removed", () => {
    expect(redactText(`token=${FAKE.github}`)).toBe(`token=${REDACTED_PREFIX}store-github-token]`);
    expect(redactText(`key=${FAKE.anthropic}`)).toBe(`key=${REDACTED_PREFIX}store-anthropic-key]`);
    expect(redactText(`pat=${FAKE.fineGrained}`)).toBe(
      `pat=${REDACTED_PREFIX}store-github-fine-grained-pat]`,
    );
    expect(redactText(`npm=${FAKE.npm}`)).toBe(`npm=${REDACTED_PREFIX}store-npm-token]`);
  });

  it("replaces every occurrence, not the first", () => {
    const text = `${FAKE.github} and ${FAKE.anthropic} and ${FAKE.github}`;
    const out = redactText(text);
    expect(out).not.toContain(FAKE.github);
    expect(out).not.toContain(FAKE.anthropic);
    expect(out.match(/store-github-token/g)?.length).toBe(2);
  });

  it("leaves text with no shape untouched", () => {
    const text = "the task- list said risk- 3, and sk-ant is not a key on its own";
    expect(redactText(text)).toBe(text);
  });

  it("redacts a token that starts the string", () => {
    const out = redactText(FAKE.github);
    expect(out).toBe(`${REDACTED_PREFIX}store-github-token]`);
  });

  it("redacts a token a JSONL escape puts in front of another character", () => {
    const line = JSON.stringify({ text: `first line\n${FAKE.github}` });
    expect(line).toContain(`\\n${FAKE.github}`);
    expect(redactText(line)).not.toContain(FAKE.github);
  });

  it("redacts a slack token an underscore follows", () => {
    const out = redactText(`${FAKE.slack}_tail`);
    expect(out).not.toContain(FAKE.slack);
    expect(out).toBe(`${REDACTED_PREFIX}store-slack-token]`);
  });

  it("redacts two tokens that sit next to each other with no separator", () => {
    const out = redactText(`${FAKE.github}${FAKE.anthropic}`);
    expect(out).not.toContain(FAKE.github);
    expect(out).not.toContain(FAKE.anthropic);
  });

  it("does not redact a prefix that is part of a longer word", () => {
    const text = "xsk-ant-" + "A".repeat(30);
    expect(redactText(text)).toBe(text);
  });

  it("keeps the character in front of the token", () => {
    const out = redactText(`"${FAKE.github}"`);
    expect(out).toBe(`"${REDACTED_PREFIX}store-github-token]"`);
  });

  it("handles an empty string and a string with no match", () => {
    expect(redactText("")).toBe("");
    expect(redactText("ghp_short")).toBe("ghp_short");
  });

  it("redacts a token-shaped fake that uses words and underscores", () => {
    const out = redactText(FAKE.githubWords);
    expect(out).toBe(`${REDACTED_PREFIX}store-github-token]`);
  });

  it("redacts inside a JSON string without breaking it", () => {
    const line = JSON.stringify({ text: `export GH_TOKEN=${FAKE.github}` });
    const out = redactText(line);
    expect(out).not.toContain(FAKE.github);
    expect(JSON.parse(out).text).toBe(`export GH_TOKEN=${REDACTED_PREFIX}store-github-token]`);
  });
});

describe("redactJson", () => {
  it("redacts string values, array items and object keys", () => {
    const out = redactJson({
      list: [FAKE.github, "plain"],
      nested: { deep: FAKE.anthropic },
      [FAKE.npm]: "value",
      count: 3,
      nothing: null,
    });
    expect(JSON.stringify(out)).not.toContain(FAKE.github);
    expect(JSON.stringify(out)).not.toContain(FAKE.anthropic);
    expect(JSON.stringify(out)).not.toContain(FAKE.npm);
    expect(out).toEqual({
      list: [`${REDACTED_PREFIX}store-github-token]`, "plain"],
      nested: { deep: `${REDACTED_PREFIX}store-anthropic-key]` },
      [`${REDACTED_PREFIX}store-npm-token]`]: "value",
      count: 3,
      nothing: null,
    });
  });

  it("passes scalars through", () => {
    expect(redactJson(7)).toBe(7);
    expect(redactJson(true)).toBe(true);
    expect(redactJson(null)).toBe(null);
    expect(redactJson(undefined)).toBe(undefined);
  });
});
