import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import {
  DEFAULT_MAX_PER_DAY,
  DEFAULT_REPO_ROOT,
  DEFAULT_SENDERS,
  NEVER_REPO,
  loadIntake,
  maxPerDayFrom,
  parseIntake,
  repoRootFrom,
  sendersFrom,
  stateDirFrom,
} from "../src/config.ts";
import { tempRoot, writeIntake } from "./helpers.ts";

describe("parseIntake", () => {
  it("keeps only product repos", () => {
    const raw = JSON.stringify({
      repos: [
        { name: "0509", product: true },
        { name: "tether", product: true },
        { name: "inish-site", product: false },
        { name: "no-flag" },
      ],
    });
    expect(parseIntake(raw)).toEqual(["0509", "tether"]);
  });

  it("drops fleet-ops even when a config marks it product", () => {
    const raw = JSON.stringify({
      repos: [
        { name: "fleet-ops", product: true },
        { name: "0509", product: true },
      ],
    });
    expect(parseIntake(raw)).toEqual(["0509"]);
  });

  it("drops names that are not a bare repo name", () => {
    const raw = JSON.stringify({
      repos: [
        { name: "Nishfleet/0509", product: true },
        { name: "../etc", product: true },
        { name: "  ", product: true },
        { name: "0509", product: true },
      ],
    });
    expect(parseIntake(raw)).toEqual(["0509"]);
  });

  it("treats a missing repos list as no repos", () => {
    expect(parseIntake("{}")).toEqual([]);
    expect(parseIntake(JSON.stringify({ repos: "0509" }))).toEqual([]);
  });

  it("never admits fleet-ops or a non-product repo from the real config", async () => {
    const real = await readFile(
      new URL("../../../config/intake-repos.json", import.meta.url),
      "utf8",
    );
    const repos = parseIntake(real);
    expect(repos.length).toBeGreaterThan(0);
    expect(repos).not.toContain(NEVER_REPO);
    expect(repos).not.toContain("inish-site");
    expect(repos).toContain("0509");
    for (const repo of repos) expect(repo).toMatch(/^[A-Za-z0-9._-]+$/);
  });
});

describe("loadIntake", () => {
  it("reads the allowlist from the install tree", async () => {
    const root = await tempRoot();
    await writeIntake(root, [
      { name: "0509", product: true },
      { name: "fleet-ops", product: true },
    ]);
    expect(await loadIntake(root)).toEqual(["0509"]);
  });

  it("throws when the config is missing, so a bad install files nothing", async () => {
    const root = await tempRoot();
    await expect(loadIntake(root)).rejects.toThrow();
  });
});

describe("environment", () => {
  it("defaults the senders to muse, instinct, tether and hermes", () => {
    expect(sendersFrom({})).toEqual([...DEFAULT_SENDERS]);
    expect(DEFAULT_SENDERS).toEqual(["muse", "instinct", "tether", "hermes"]);
  });

  it("takes the senders from ISSUE_DESK_SENDERS", () => {
    expect(sendersFrom({ ISSUE_DESK_SENDERS: " muse , ,hermes " })).toEqual([
      "muse",
      "hermes",
    ]);
  });

  it("defaults and overrides the daily cap", () => {
    expect(maxPerDayFrom({})).toBe(DEFAULT_MAX_PER_DAY);
    expect(maxPerDayFrom({ ISSUE_DESK_MAX_PER_DAY: "3" })).toBe(3);
    expect(maxPerDayFrom({ ISSUE_DESK_MAX_PER_DAY: "0" })).toBe(DEFAULT_MAX_PER_DAY);
    expect(maxPerDayFrom({ ISSUE_DESK_MAX_PER_DAY: "many" })).toBe(
      DEFAULT_MAX_PER_DAY,
    );
  });

  it("defaults and overrides the repo root", () => {
    expect(repoRootFrom({})).toBe(DEFAULT_REPO_ROOT);
    expect(repoRootFrom({ ISSUE_DESK_REPO_ROOT: "/srv/fleet-ops" })).toBe(
      "/srv/fleet-ops",
    );
    expect(repoRootFrom({ ISSUE_DESK_REPO_ROOT: "  " })).toBe(DEFAULT_REPO_ROOT);
  });

  it("takes the state dir from ISSUE_DESK_STATE_DIR, then STATE_DIRECTORY, then cwd", () => {
    expect(stateDirFrom({}, "/work")).toBe("/work");
    expect(stateDirFrom({ STATE_DIRECTORY: "/state" }, "/work")).toBe("/state");
    expect(
      stateDirFrom(
        { STATE_DIRECTORY: "/state", ISSUE_DESK_STATE_DIR: "/explicit" },
        "/work",
      ),
    ).toBe("/explicit");
  });
});
