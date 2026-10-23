export interface TokenShape {
  readonly id: string;
  readonly label: string;
  readonly keywords: readonly string[];
  readonly token: string;
  readonly chars: string;
}

export const REDACTED_PREFIX = "[REDACTED:";

export const TOKEN_SHAPES: readonly TokenShape[] = [
  {
    id: "store-github-token",
    label: "GitHub token",
    keywords: ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"],
    token: "gh[pousr]_[A-Za-z0-9_]{20,}",
    chars: "A-Za-z0-9_",
  },
  {
    id: "store-github-fine-grained-pat",
    label: "GitHub fine-grained token",
    keywords: ["github_pat_"],
    token: "github_pat_[A-Za-z0-9_]{20,}",
    chars: "A-Za-z0-9_",
  },
  {
    id: "store-anthropic-key",
    label: "Anthropic API key",
    keywords: ["sk-ant-"],
    token: "sk-ant-[A-Za-z0-9_-]{20,}",
    chars: "A-Za-z0-9_-",
  },
  {
    id: "store-gitlab-token",
    label: "GitLab token",
    keywords: ["glpat-"],
    token: "glpat-[A-Za-z0-9_-]{20,}",
    chars: "A-Za-z0-9_-",
  },
  {
    id: "store-slack-token",
    label: "Slack token",
    keywords: ["xoxb-", "xoxa-", "xoxp-", "xoxr-", "xoxs-"],
    token: "xox[baprs]-[A-Za-z0-9-]{10,}",
    chars: "A-Za-z0-9_-",
  },
  {
    id: "store-npm-token",
    label: "npm token",
    keywords: ["npm_"],
    token: "npm_[A-Za-z0-9_]{30,}",
    chars: "A-Za-z0-9_",
  },
];

export const TOKEN_SHAPE_IDS: readonly string[] = TOKEN_SHAPES.map((shape) => shape.id);

interface CompiledShape {
  readonly id: string;
  readonly regex: RegExp;
}

const COMPILED: readonly CompiledShape[] = TOKEN_SHAPES.map((shape) => ({
  id: shape.id,
  regex: new RegExp(`(?<![${shape.chars}])(${shape.token})(?![${shape.chars}])`, "g"),
}));

export const redactText = (text: string): string => {
  if (typeof text !== "string" || text.length === 0) {
    return text;
  }
  let result = text;
  for (const shape of COMPILED) {
    result = result.replace(shape.regex, `${REDACTED_PREFIX}${shape.id}]`);
  }
  return result;
};

export const redactJson = (value: unknown): unknown => {
  if (typeof value === "string") {
    return redactText(value);
  }
  if (Array.isArray(value)) {
    return value.map((item) => redactJson(item));
  }
  if (value !== null && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value)) {
      out[redactText(key)] = redactJson(item);
    }
    return out;
  }
  return value;
};
