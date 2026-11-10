import { execFileSync } from "node:child_process";
import { chmodSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { createAppAuth } from "@octokit/auth-app";
import { request } from "@octokit/request";

const { APP_ID, APP_KEY, GITHUB_API_URL, TOKEN_PERMISSIONS, TOKEN_REPOSITORIES } = process.env;

// A Hermes restart pulls its token unit in. Leave a login younger than 15 min
// alone, so a restart costs no API call; stock systemd has no file-age
// condition, so the minter checks before it mints.
if (process.env.GH_HOSTS === "1") {
  try {
    if (Date.now() - statSync(`${process.env.RUNTIME_DIRECTORY}/hosts.yml`).mtimeMs < 15 * 60 * 1000) {
      process.stderr.write("the minted login is younger than 15 min, nothing to mint\n");
      process.exit(0);
    }
  } catch {
    // No hosts.yml yet: mint one.
  }
}

const github = request.defaults({ baseUrl: GITHUB_API_URL });
const auth = createAppAuth({ appId: APP_ID, privateKey: readFileSync(APP_KEY, "utf8"), request: github });
const app = await auth({ type: "app" });
const { data: installation } = await github("GET /repos/{owner}/{repo}/installation", {
  owner: "Nishfleet",
  repo: "fleet-ops",
  headers: { authorization: `bearer ${app.token}` },
});
const { token } = await auth({
  type: "installation",
  installationId: installation.id,
  permissions: JSON.parse(TOKEN_PERMISSIONS),
  ...(TOKEN_REPOSITORIES ? { repositoryNames: TOKEN_REPOSITORIES.split(",") } : {}),
});

// Replace a file atomically: a reader sees either the old file or the complete
// new one, never a partial write. The mode is 0600, inside a 0700 runtime dir.
function writeToken(file, body) {
  writeFileSync(`${file}.new`, body, { mode: 0o600 });
  chmodSync(`${file}.new`, 0o600);
  renameSync(`${file}.new`, file);
}

// Grafana reads a file, so the token lands there. `GH_TOKEN_FILE` keeps the
// token out of stdout, where StandardOutput= would otherwise put it.
if (process.env.GH_TOKEN_FILE) writeToken(process.env.GH_TOKEN_FILE, token);

// Hermes' gh login is the same token in the hosts.yml git reads. `GH_HOSTS=1`
// selects it; the file is built here so the unit needs no shell.
if (process.env.GH_HOSTS === "1") {
  writeToken(
    `${process.env.RUNTIME_DIRECTORY}/hosts.yml`,
    `github.com:\n    user: nishfleet-worker\n    oauth_token: ${token}\n    git_protocol: https\n`,
  );
}

if (!process.env.GH_TOKEN_FILE && process.env.GH_HOSTS !== "1") process.stdout.write(token);

// Grafana freezes $__file{} when it loads the alerting config. Reload it only
// when the token Grafana loaded is 40 minutes old: one mint interval of slack,
// and half the reloads of a reload at every mint. The ledger holds the mtime of
// the token at the last reload. A missing ledger means reload on this mint; a
// Grafana that is not active skips the reload (the next start reads the file);
// a real HTTP failure fails the unit.
if (process.env.GH_RELOAD === "1") {
  let active = false;
  try {
    execFileSync("/usr/bin/systemctl", ["--user", "is-active", "--quiet", "fleet-grafana.service"], { stdio: "ignore" });
    active = true;
  } catch {
    active = false;
  }
  if (!active) {
    process.stderr.write("Grafana is not active; skipped the provisioning reload\n");
  } else {
    const ledger = process.env.GH_LOADED_FILE;
    let loaded = 0;
    try {
      loaded = Math.floor(Number(readFileSync(ledger, "utf8")));
    } catch {
      loaded = 0;
    }
    if (!Number.isFinite(loaded) || loaded <= Math.floor(Date.now() / 1000) - 2400) {
      const password = readFileSync(process.env.GH_ADMIN_PASSWORD_FILE, "utf8").trim();
      const basic = Buffer.from(`admin:${password}`).toString("base64");
      let response;
      try {
        response = await fetch(process.env.GH_RELOAD_URL, {
          method: "POST",
          headers: { authorization: `Basic ${basic}` },
          signal: AbortSignal.timeout(30_000),
        });
      } catch (error) {
        // Grafana stopped between the check and the POST: the next start reads
        // the fresh file, so skip the reload but keep the ledger old and retry.
        if (error.cause?.code === "ECONNREFUSED") {
          process.stderr.write("Grafana is not listening; skipped the provisioning reload\n");
        } else {
          throw error;
        }
      }
      if (response) {
        if (!response.ok) throw new Error(`Grafana provisioning reload failed: HTTP ${response.status}`);
        writeToken(ledger, String(Math.floor(statSync(process.env.GH_TOKEN_FILE).mtimeMs / 1000)));
      }
    }
  }
}

process.stderr.write("minted a GitHub App token, valid one hour\n");
