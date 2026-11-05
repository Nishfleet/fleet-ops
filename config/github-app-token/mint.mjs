import { readFileSync } from "node:fs";
import { createAppAuth } from "@octokit/auth-app";
import { request } from "@octokit/request";

const { APP_ID, APP_KEY, GITHUB_API_URL, TOKEN_PERMISSIONS, TOKEN_REPOSITORIES } = process.env;
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
process.stdout.write(token);
