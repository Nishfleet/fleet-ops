import { execFile } from "node:child_process";

export interface ExecOptions {
  env?: Record<string, string | undefined>;
  cwd?: string;
  timeoutMs?: number;
}

export interface ExecResult {
  stdout: string;
  stderr: string;
  code: number;
}

export type Runner = (
  file: string,
  args: readonly string[],
  options?: ExecOptions,
) => Promise<ExecResult>;

export const execFileRunner: Runner = (file, args, options = {}) =>
  new Promise((resolve) => {
    execFile(
      file,
      [...args],
      {
        shell: false,
        timeout: options.timeoutMs ?? 120_000,
        maxBuffer: 8 * 1024 * 1024,
        encoding: "utf8",
        env: options.env ?? process.env,
        cwd: options.cwd,
      },
      (error, stdout, stderr) => {
        const raw = error as { code?: unknown; message?: string } | null;
        const code =
          raw === null ? 0 : typeof raw.code === "number" ? raw.code : 1;
        const message = String(stderr ?? "") || (raw?.message ?? "");
        resolve({ stdout: String(stdout ?? ""), stderr: message, code });
      },
    );
  });
