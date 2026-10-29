import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export const DEFAULT_SENDERS = ["muse", "instinct", "tether", "hermes"];

export const NEVER_REPO = "fleet-ops";

export const DEFAULT_REPO_ROOT = join(
  homedir(),
  "workspaces/tooling/fleet-ops-deploy-clone",
);

export const INTAKE_PATH = "config/intake-repos.json";

export const DEFAULT_MAX_PER_DAY = 10;

const REPO_NAME = /^[A-Za-z0-9._-]+$/;

export interface IntakeEntry {
  name?: unknown;
  product?: unknown;
}

export const parseIntake = (raw: string): string[] => {
  const doc = JSON.parse(raw) as { repos?: unknown };
  const repos = Array.isArray(doc.repos) ? (doc.repos as IntakeEntry[]) : [];
  return repos.flatMap((entry) => {
    const name = typeof entry?.name === "string" ? entry.name.trim() : "";
    if (entry?.product !== true) return [];
    if (name === "" || name === NEVER_REPO || !REPO_NAME.test(name)) return [];
    return [name];
  });
};

export const loadIntake = async (repoRoot: string): Promise<string[]> =>
  parseIntake(await readFile(join(repoRoot, INTAKE_PATH), "utf8"));

export const sendersFrom = (env: Record<string, string | undefined>): string[] => {
  const raw = env.ISSUE_DESK_SENDERS ?? DEFAULT_SENDERS.join(",");
  return raw
    .split(",")
    .map((sender) => sender.trim())
    .filter((sender) => sender !== "");
};

export const repoRootFrom = (env: Record<string, string | undefined>): string => {
  const raw = env.ISSUE_DESK_REPO_ROOT?.trim();
  return raw !== undefined && raw !== "" ? raw : DEFAULT_REPO_ROOT;
};

export const maxPerDayFrom = (env: Record<string, string | undefined>): number => {
  const raw = Number.parseInt(env.ISSUE_DESK_MAX_PER_DAY ?? "", 10);
  return Number.isFinite(raw) && raw > 0 ? raw : DEFAULT_MAX_PER_DAY;
};

export const stateDirFrom = (
  env: Record<string, string | undefined>,
  cwd: string,
): string => {
  for (const candidate of [env.ISSUE_DESK_STATE_DIR, env.STATE_DIRECTORY]) {
    const trimmed = candidate?.trim();
    if (trimmed !== undefined && trimmed !== "") return trimmed;
  }
  return cwd;
};
