export const firstLine = (value: string): string =>
  value
    .split("\n")
    .map((line) => line.trim())
    .find((line) => line !== "") ?? "";

export const singleLine = (value: string): string => value.replace(/\s+/g, " ").trim();

export const clip = (value: string, max: number): string =>
  value.length <= max ? value : `${value.slice(0, Math.max(0, max - 1))}…`;

export const plain = (value: string): string =>
  value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "");

// The body text is model-written, so a crafted line could hand commands to the
// fleet's own tooling, which parses colon-prefixed markers on issue bodies and
// comments. Every such prefix found in .github/workflows/agent-dispatch.yml,
// .github/workflows/agent.yml and prompts/worker.md is quoted out below before
// the body reaches GitHub: due:, blocked-on:, decision-resolved:, park:,
// opus-vet:, attempt-cap reset:, agent run started:, agent run infra-failed:,
// agent run failed:, stuck-pr:, red-main:, red-main-run:. tincan-request:,
// requested-by:, relayed-by: and chain: are this extension's own footer lines
// and stay out of the model-written text too.
const DECORATION = "[>#*_\\-`+|\\s]";

const NUMBERED = "\\d{1,3}[.)]";

const COMMAND =
  "due|blocked-on|decision-resolved|park|opus-vet|attempt-cap reset|agent run started|agent run infra-failed|agent run failed|stuck-pr|red-main|red-main-run|tincan-request|requested-by|relayed-by|chain";

export const AUTHORITY_LINE = new RegExp(
  `^${DECORATION}{0,32}(?:${NUMBERED}${DECORATION}{0,32})?(?:${COMMAND})\\s*:`,
  "i",
);

export const quoteAuthority = (value: string): string =>
  value
    .split("\n")
    .map((line) => (AUTHORITY_LINE.test(line) ? `[quoted] ${line.trim()}` : line))
    .join("\n");
