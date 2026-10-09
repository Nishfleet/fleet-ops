# One narrow Cloudflare token per GitHub repo (and per job family in 0509), each
# written into that repo's existing Actions secret name, replaced every
# rotation_days. The inventory behind every permission list is in README.md.

locals {
  # Key           = name used in the token title and in state addresses.
  # repo          = GitHub repo that receives the secret.
  # environment   = set when the workflow reads the secret from a GitHub
  #                 Environment (0509 deploy); null writes a repo-level secret.
  # secret_name   = the name the workflows already read, so no workflow changes.
  # account/zone  = permission group NAMES, resolved to ids below (account-scoped
  #                 groups apply to the account, zone-scoped groups to every zone
  #                 in the account).
  # vps_only      = true only when every job that reads the secret runs on the VPS
  #                 self-hosted runners. GitHub-hosted runners have no fixed
  #                 address (an IP-locked deploy token failed there with error
  #                 9109), so every token below is false: every consumer job runs
  #                 on ubuntu-latest.
  tokens = {
    drive = {
      repo        = "drive"
      environment = null
      secret_name = "CLOUDFLARE_API_TOKEN"
      account     = ["Workers Scripts Write", "D1 Write", "Queues Write", "Account Settings Read"]
      zone        = []
      vps_only    = false
    }
    "0509-deploy" = {
      repo        = "0509"
      environment = "production"
      secret_name = "CLOUDFLARE_API_TOKEN"
      account     = ["Workers Scripts Write", "D1 Write", "Queues Write", "Account Settings Read"]
      zone        = ["Zone Read", "Workers Routes Write"]
      vps_only    = false
    }
    "0509-reports" = {
      repo        = "0509"
      environment = null
      secret_name = "CLOUDFLARE_API_TOKEN"
      account     = ["D1 Read", "Workers Scripts Read", "Account Analytics Read"]
      zone        = []
      vps_only    = false
    }
    "0509-settings" = {
      repo        = "0509"
      environment = null
      secret_name = "CLOUDFLARE_SETTINGS_TOKEN"
      account     = ["Workers R2 Storage Write"]
      zone        = ["Zone Read", "Email Routing Rules Write"]
      vps_only    = false
    }
    "0509-support-inbox" = {
      repo        = "0509-support-inbox"
      environment = null
      secret_name = "CLOUDFLARE_API_TOKEN"
      account     = ["Workers Scripts Write", "Account Settings Read"]
      zone        = []
      vps_only    = false
    }
    "siterep-public" = {
      repo        = "siterep-public"
      environment = null
      secret_name = "CLOUDFLARE_API_TOKEN"
      account     = ["Workers Scripts Write", "Account Settings Read"]
      zone        = ["Zone Read", "Workers Routes Write"]
      vps_only    = false
    }
    "TinyStudio.io-public" = {
      repo        = "TinyStudio.io-public"
      environment = null
      secret_name = "CLOUDFLARE_API_TOKEN"
      account     = ["Workers Scripts Write", "Account Settings Read"]
      zone        = ["Zone Read", "Workers Routes Write"]
      vps_only    = false
    }
    "inish-site" = {
      repo        = "inish-site"
      environment = null
      secret_name = "CLOUDFLARE_API_TOKEN"
      account     = ["Workers Scripts Write", "Account Settings Read"]
      zone        = ["Zone Read", "Workers Routes Write"]
      vps_only    = false
    }
    "aiconverter-app" = {
      repo        = "aiconverter-app"
      environment = null
      secret_name = "CLOUDFLARE_API_TOKEN"
      account     = ["Pages Write", "Account Settings Read"]
      zone        = []
      vps_only    = false
    }
    "tinystudio-in" = {
      repo        = "tinystudio-in"
      environment = null
      secret_name = "CLOUDFLARE_API_TOKEN"
      account     = ["Pages Write", "Account Settings Read"]
      zone        = []
      vps_only    = false
    }
  }

  repo_secrets = { for k, v in local.tokens : k => v if v.environment == null }
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
# rewrites the GitHub secret.
resource "time_rotating" "token" {
  for_each      = local.tokens
  rotation_days = var.rotation_days
}

resource "cloudflare_api_token" "token" {
  for_each = local.tokens

  # The date keeps names unique, so the new token can exist beside the old one
  # while the secret is rewritten (create_before_destroy).
  name       = "gha-${each.key}-${formatdate("YYYYMMDD", time_rotating.token[each.key].rfc3339)}"
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
  }
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
