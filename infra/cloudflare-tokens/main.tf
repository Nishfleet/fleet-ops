# One narrow Cloudflare token per GitHub repo (and per job family in 0509), each
# written into that repo's existing Actions secret name, plus the one token
# whose consumer is not a GitHub Actions job (the VPS analytics file), each
# replaced every rotation_days. The inventory behind every permission list is in
# README.md.

locals {
  # Key           = name used in the token title and in state addresses.
  # repo          = GitHub repo that receives the secret; null for the token that
  #                 is written to a VPS file instead (file below).
  # environment   = set when the workflow reads the secret from a GitHub
  #                 Environment (0509 deploy); null writes a repo-level secret.
  # secret_name   = the name the workflows already read, so no workflow changes.
  # file          = 0600 file on the VPS that receives the token value, for the
  #                 one consumer that is not a GitHub Actions job (Grafana's
  #                 Cloudflare data source); null writes a GitHub secret.
  # account/zone  = permission group NAMES, resolved to ids below (account-scoped
  #                 groups apply to the account, zone-scoped groups to every zone
  #                 in the account).
  # vps_only      = true only when every job that reads the token runs on the VPS
  #                 self-hosted runners. GitHub-hosted runners have no fixed
  #                 address (an IP-locked deploy token failed there with error
  #                 9109), so a repo token is false: its consumer job runs on
  #                 ubuntu-latest. vps_only = true needs vps_cidrs, and the
  #                 precondition below fails closed without it.
  tokens = {
    drive = {
      repo        = "drive"
      environment = null
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write", "D1 Write", "Queues Write", "Account Settings Read"]
      zone        = []
      vps_only    = false
    }
    "0509-deploy" = {
      repo        = "0509"
      environment = "production"
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write", "D1 Write", "Queues Write", "Account Settings Read"]
      zone        = ["Zone Read", "Workers Routes Write"]
      vps_only    = false
    }
    "0509-reports" = {
      repo        = "0509"
      environment = null
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["D1 Read", "Workers Scripts Read", "Account Analytics Read"]
      zone        = []
      vps_only    = false
    }
    "0509-settings" = {
      repo        = "0509"
      environment = null
      secret_name = "CLOUDFLARE_SETTINGS_TOKEN"
      file        = null
      account     = ["Workers R2 Storage Write"]
      zone        = ["Zone Read", "Email Routing Rules Write"]
      vps_only    = false
    }
    "0509-support-inbox" = {
      repo        = "mailbox" # renamed from 0509-support-inbox; the key stays so the token is not replaced
      environment = null
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write", "Account Settings Read"]
      zone        = []
      vps_only    = false
    }
    "siterep-public" = {
      repo        = "siterep-public"
      environment = null
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write", "Account Settings Read"]
      zone        = ["Zone Read", "Workers Routes Write"]
      vps_only    = false
    }
    "TinyStudio.io-public" = {
      repo        = "TinyStudio.io-public"
      environment = null
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write", "Workers R2 Storage Write", "Account Settings Read"]
      zone        = ["Zone Read", "Workers Routes Write"]
      vps_only    = false
    }
    "inish-site" = {
      repo        = "inish-site"
      environment = null
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write", "Account Settings Read"]
      zone        = ["Zone Read", "Workers Routes Write"]
      vps_only    = false
    }
    "aiconverter-app" = {
      repo        = "aiconverter-app"
      environment = null
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Pages Write", "Account Settings Read"]
      zone        = []
      vps_only    = false
    }
    "seo-fix-kit" = {
      repo        = "seo-fix-kit"
      environment = null
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write", "D1 Write", "Queues Write", "Account Settings Read"]
      zone        = ["Zone Read", "Workers Routes Write"]
      vps_only    = false
    }
    # Already applied by hand on 2026-10-20 under this key, so the key stays: a
    # new key would destroy the live repo secret when the old state entry goes.
    "fleet_console" = {
      repo        = "fleet-console-worker"
      environment = null
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write", "Account Settings Read"]
      zone        = ["Zone Read", "Workers Routes Write"]
      vps_only    = false
    }
    # The only consumer that is not a GitHub Actions job (fleet-ops#10169):
    # Grafana's Cloudflare data source reads this token from the 0600 env file
    # below, which ansible/host.yml renders into the grafana-cloudflare-api-token
    # Podman secret (the apply republishes it on each rotation). It replaces the
    # hand-made deploy-ci user token, which has no
    # expiry, is not IP-locked and is wider than the one read-only group the
    # spend watch needs. The value never enters a GitHub secret and never enters
    # argv: OpenTofu writes it straight to the file, mode 0600.
    "vps-grafana" = {
      repo        = null
      environment = null
      secret_name = null
      file        = "~/.config/cloudflare/deploy-ci.env"
      account     = ["Account Analytics Read"]
      zone        = []
      vps_only    = true
    }
  }

  repo_secrets = { for k, v in local.tokens : k => v if v.environment == null && v.repo != null }
  file_secrets = { for k, v in local.tokens : k => v if v.file != null }
  env_secrets  = { for k, v in local.tokens : k => v if v.environment != null }

  # Name -> id, one map per scope. A name Cloudflare does not know is an
  # "Invalid index" error at plan time, so a typo or a renamed group fails
  # closed instead of minting a token with fewer permissions.
  account_group_ids = { for g in data.cloudflare_api_token_permission_groups_list.account.result : g.name => g.id if g.is_selectable }
  zone_group_ids    = { for g in data.cloudflare_api_token_permission_groups_list.zone.result : g.name => g.id if g.is_selectable }
}

data "cloudflare_api_token_permission_groups_list" "account" {
  scope = "com.cloudflare.api.account"
}

data "cloudflare_api_token_permission_groups_list" "zone" {
  scope = "com.cloudflare.api.account.zone"
}

# Starts the rotation clock. After rotation_days the next apply replaces this
# resource, which replaces the token (replace_triggered_by below), which
# rewrites the GitHub secret or the VPS file.
resource "time_rotating" "token" {
  for_each      = local.tokens
  rotation_days = var.rotation_days
}

resource "cloudflare_api_token" "token" {
  for_each = local.tokens

  # The date keeps names unique, so the new token can exist beside the old one
  # while the secret is rewritten (create_before_destroy). `gha-` marks a token
  # this config writes into a GitHub Actions secret, so the README's lost-state
  # cleanup matches exactly those and never the host-only one, which keeps its
  # own `vps-` key name.
  name       = "${each.value.file == null ? "gha-" : ""}${each.key}-${formatdate("YYYYMMDD", time_rotating.token[each.key].rfc3339)}"
  expires_on = timeadd(time_rotating.token[each.key].rfc3339, "${var.expiry_days * 24}h")

  policies = concat(
    [{
      effect            = "allow"
      permission_groups = [for n in each.value.account : { id = local.account_group_ids[n] }]
      resources         = jsonencode({ "com.cloudflare.api.account.${var.account_id}" = "*" })
    }],
    length(each.value.zone) == 0 ? [] : [{
      effect            = "allow"
      permission_groups = [for n in each.value.zone : { id = local.zone_group_ids[n] }]
      resources = jsonencode({
        "com.cloudflare.api.account.${var.account_id}" = { "com.cloudflare.api.account.zone.*" = "*" }
      })
    }],
  )

  condition = each.value.vps_only ? { request_ip = { in = var.vps_cidrs } } : null

  lifecycle {
    create_before_destroy = true
    replace_triggered_by  = [time_rotating.token[each.key]]

    precondition {
      condition     = !each.value.vps_only || length(var.vps_cidrs) > 0
      error_message = "vps_only is set for this token but vps_cidrs is empty. Set vps_cidrs in a gitignored *.tfvars file."
    }
  }
}

# The VPS token is written to the file its consumer reads, not to a GitHub
# secret: no workflow reads it and the host has no GitHub secret for it. The
# file is 0600 and the value is sensitive, so it is not printed by plan.
resource "local_sensitive_file" "token" {
  for_each = local.file_secrets

  filename             = pathexpand(each.value.file)
  content              = "CLOUDFLARE_API_TOKEN=${cloudflare_api_token.token[each.key].value}\n"
  file_permission      = "0600"
  directory_permission = "0700"
}

resource "github_actions_secret" "repo" {
  for_each = local.repo_secrets

  repository      = each.value.repo
  secret_name     = each.value.secret_name
  plaintext_value = cloudflare_api_token.token[each.key].value
}

resource "github_actions_environment_secret" "env" {
  for_each = local.env_secrets

  repository      = each.value.repo
  environment     = each.value.environment
  secret_name     = each.value.secret_name
  plaintext_value = cloudflare_api_token.token[each.key].value
}

# fleet-console-worker also holds its own copy of the account id (an identifier,
# not a credential), written by hand-applied config on 2026-10-20 and adopted here.
resource "github_actions_secret" "account_id_fleet_console" {
  repository      = "fleet-console-worker"
  secret_name     = "CLOUDFLARE_ACCOUNT_ID"
  plaintext_value = var.account_id
}
