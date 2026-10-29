# The TinyStudio email-signups D1 database is gone from the fleet account

**Date:** 2026-10-29
**Issue:** fleet-ops#10830

## What was asked

The stock D1 export API answers HTTP 404 for `tinystudio_email_signups`, so that database
has no weekly backup. Three questions had to be answered before the fleet could act:

1. Which account owns `tinystudio_email_signups`?
2. If it is a second account, the backup needs an export credential for that account, and
   drive's single matrix cannot reach it.
3. If the database was deleted and recreated under a new id, `wrangler.jsonc` in
   TinyStudio.io-public and TinyStudio.io both carry the stale id, and the worker is binding
   a database that no longer exists.

## Answer

1. No account owns it. The database is not in the fleet account, and the fleet holds no
   credential for any other account.
2. Not applicable. There is no second account, so no export credential is missing and
   drive's single matrix is not the problem.
3. It was deleted and never recreated. Both repos still carry the stale id, and the worker
   binds a database that does not exist.

## Why there is no second account

`infra/cloudflare-tokens/main.tf` builds every token the fleet holds against one account
resource, and narrows the zone permissions to the zones inside that same account:

```hcl
resources = jsonencode({ "com.cloudflare.api.account.${var.account_id}" = "*" })
```

`var.account_id` has one default in `variables.tf`, and `.gitignore` keeps `*.tfvars` out of
the repo, so an override is not visible. What each token may do inside that account is in
the table in `infra/cloudflare-tokens/README.md`.

The default is also the account the export runs against, because the same database id
resolves under two unrelated tokens. `0509` and `siterep_payments` both export successfully
against the account id in the issue, and the deploys of 0509 and siterep-public both
succeed on `main` today, each with its own token, each resolving the same id in its own
account. One database id cannot be in two accounts, so the deploy account and the export
account are the same one. One Cloudflare account is therefore the whole reachable surface,
and the 404 cannot mean "it lives somewhere else".

## Why it was deleted rather than moved

The export 404 and the deploy failure come from two different tokens, and they agree:

- drive's export token runs `d1-export.yml` and answers 404 for the id that
  `wrangler.jsonc` declares.
- TinyStudio.io-public's deploy token holds no D1 permission at all, and its
  `deploy-production.yml` runs only `npx wrangler deploy`. That deploy resolves the D1
  binding inside the same single account, and it answers `[code: 10181]` with "Verify the
  database exists in your account".

A database that had moved to another account would still resolve for the deploy token,
because the deploy token is scoped to the same account. Two independent tokens, scoped to
one account, both failing to find the same id, leaves deletion as the only cause that fits.

## When it went

The window is bounded by two runs of TinyStudio.io-public's `deploy-production.yml` on
`main`:

| Run | Started (UTC) | Result |
|---|---|---|
| [38303951628](https://github.com/Nishfleet/TinyStudio.io-public/actions/runs/38303951628) | 2026-10-12 20:23:57 | success, so the binding resolved and the database was in the account |
| [39808354150](https://github.com/Nishfleet/TinyStudio.io-public/actions/runs/39808354150) | 2026-10-22 15:48:59 | failure on the D1 binding, so it was gone |

The window is not tighter than that. The six runs in between, at 2026-10-12 22:24,
2026-10-14 05:38 and 07:11, and 2026-10-15 10:22, 15:26 and 16:38, all failed earlier on an
R2 authentication error, before the deploy reached the D1 binding check. That R2 error is a
separate fault, and it hid this one until 2026-10-22.

## What it breaks

- The weekly backup. drive's `d1-export.yml` on branch `fleet-product-db-backups` holds a
  row for this database, and that job is red on every run.
- The deploy. Every run of TinyStudio.io-public's `deploy-production.yml` on `main` has
  failed since 2026-10-12, and since 2026-10-22 every one of them failed on the D1 binding,
  so the repository cannot ship.
- The worker. `wrangler.jsonc` binds `DB` to a database that does not exist, in both
  TinyStudio.io-public and TinyStudio.io. TinyStudio.io is archived, so its copy of the
  stale id is frozen.

## What must happen next

The database has to be created again in the fleet account, then TinyStudio.io's
`migrations/` applied, then `wrangler.jsonc` in TinyStudio.io-public pointed at the new id,
then drive's matrix row corrected. No token that belongs to this product can do the first
two steps, so the recreation is an owner action, not a worker action.

Two gaps this incident exposed sit outside this issue's scope and are filed as follow-ups:

- `config/grafana/provisioning/alerting/deploy-failed.yaml` watches eight repositories and
  not TinyStudio.io-public, so 16 days of red deploys raised no alert.
- drive's `d1-export.yml` matrix on branch `fleet-product-db-backups` has no open pull
  request, so the stopgap for the four product databases is not scheduled anywhere.

## Proof

The export 404, from the two drive runs named in the issue:

```
$ gh run view 40837984986 -R Nishfleet/drive --log-failed
curl: (22) The requested URL returned error: 404

$ gh run view 40838390369 -R Nishfleet/drive --log-failed
curl: (22) The requested URL returned error: 404
```

The same call succeeds for `siterep_payments`, `aiconverter` and `0509` in those runs, so
the token and the endpoint are right and only this id is missing.

The deploy failure, from a different token in the same account:

```
$ gh run view 40833014182 -R Nishfleet/TinyStudio.io-public --log-failed
✘ [ERROR] A request to the Cloudflare API (/accounts/***/workers/scripts/tinystudio-io-public/versions) failed.
  D1 binding 'DB' references database 'ff360a55-14fc-468c-895f-893c89e0db79' which was not found. Verify the database exists in your account and that the database_id in your configuration is correct. [code: 10181]
```

The R2 authentication error that hid it, from a run inside the window:

```
$ gh run view 38719760911 -R Nishfleet/TinyStudio.io-public --log-failed
✘ [ERROR] A request to the Cloudflare API (/accounts/***/r2/buckets/tinystudio-records) failed.
  Authentication error [code: 10000]
```

The window, from the run list on `main`:

```
$ gh run list -R Nishfleet/TinyStudio.io-public --workflow deploy-production.yml --limit 25 \
    --json databaseId,conclusion,createdAt --jq '.[]|"\(.databaseId)\t\(.conclusion)\t\(.createdAt)"'
40833014182	failure	2026-10-29T07:03:44Z
40754445494	failure	2026-10-28T19:27:19Z
40721444154	failure	2026-10-28T15:59:09Z
40717960686	failure	2026-10-28T15:38:13Z
40525411436	failure	2026-10-27T14:52:52Z
40074360436	failure	2026-10-24T07:29:53Z
39970078637	failure	2026-10-23T14:29:34Z
39939242197	failure	2026-10-23T10:27:32Z
39912293139	failure	2026-10-23T06:34:12Z
39822298845	failure	2026-10-22T17:23:48Z
39808354150	failure	2026-10-22T15:48:59Z
38770718037	failure	2026-10-15T16:38:39Z
38769081649	failure	2026-10-15T15:26:59Z
38719760911	failure	2026-10-15T10:22:08Z
38526747629	failure	2026-10-14T07:11:37Z
38517680602	failure	2026-10-14T05:38:03Z
38316494622	failure	2026-10-12T22:24:42Z
38303951628	success	2026-10-12T20:23:57Z
38290331817	success	2026-10-12T18:21:15Z
38269014920	success	2026-10-12T15:16:23Z
38259453923	success	2026-10-12T13:58:05Z
38259078807	success	2026-10-12T13:55:00Z
38255309377	failure	2026-10-12T13:23:04Z
38245020936	success	2026-10-12T11:48:22Z
37924765102	success	2026-10-09T11:36:22Z
```

The stale id, still declared by the worker's config on `main`:

```
$ gh api repos/Nishfleet/TinyStudio.io-public/contents/wrangler.jsonc --jq .content | base64 -d | grep -A5 d1_databases
  "d1_databases": [
    {
      "binding": "DB",
      "database_name": "tinystudio_email_signups",
      "database_id": "ff360a55-14fc-468c-895f-893c89e0db79",
      "preview_database_id": "478f4a89-8936-4a57-bdd0-5f273090b2e5"
```
