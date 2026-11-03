# Two narrow Cloudflare tokens per GitHub repo: the deploy token, written as a
# secret of the repo's `production` environment (deployment branches: main only),
# and a preview token holding only the right a PR preview upload needs, written
# as a secret of its `preview` environment. A PR job cannot read the production
# secret, because GitHub releases an environment secret only to a job that
# declares that environment and passes its branch policy
# (https://docs.github.com/en/actions/deployment/targeting-different-environments/managing-environments-for-deployment).
# Plus the one token
# whose consumer is not a GitHub Actions job (the VPS analytics file), each
# replaced every rotation_days. The inventory behind every permission list is in
# README.md.

locals {
  # Key           = name used in the token title and in state addresses.
  # repo          = GitHub repo that receives the secret; null for the token that
  #                 is written to a VPS file instead (file below).
  # environment   = the GitHub Environment that holds the secret: "production"
  #                 for deploy tokens, "preview" for preview tokens. The
  #                 environments and their branch policies are repo settings
  #                 (README.md, "Environments"); this config writes only the
  #                 secrets. null only for the token written to a VPS file.
  # secret_name   = the name the workflows already read.
  # file          = 0600 file on the VPS that receives the token value, for the
  #                 one consumer that is not a GitHub Actions job (Grafana's
  #                 Cloudflare data source); null writes a GitHub secret.
  # account/zone  = permission group NAMES, resolved to ids below (account-scoped
  #                 groups apply to the account, zone-scoped groups to the zones
  #                 listed in `zones`).
  # zones         = zone names the zone groups apply to: the zones the repo's
  #                 wrangler routes and custom domains name. Cloudflare scopes a
  #                 zone-level group to one zone
  #                 (https://developers.cloudflare.com/fundamentals/api/how-to/create-via-api/).
  # vps_only      = true only when every job that reads the token runs on the VPS
  #                 self-hosted runners. GitHub-hosted runners have no fixed
  #                 address (an IP-locked deploy token failed there with error
  #                 9109), so a repo token is false: its consumer job runs on
  #                 ubuntu-latest. vps_only = true needs vps_cidrs, and the
  #                 precondition below fails closed without it.
  tokens = {
    drive = {
      repo        = "drive"
      environment = "production"
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write", "D1 Write", "Queues Write", "Account Settings Read"]
      zone        = []
      zones       = []
      vps_only    = false
    }
    "0509-deploy" = {
      repo        = "0509"
      environment = "production"
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write", "D1 Write", "Queues Write", "Account Settings Read"]
      zone        = ["Zone Read", "Workers Routes Write"]
      zones       = ["0509.io"]
      vps_only    = false
    }
    # 0509's preview token: ci.yml's preview upload (`cf workers versions
    # create`) needs Workers Scripts Write and nothing else. The key keeps its
    # old name so the token is not replaced; its secret moves from the repo to
    # the `preview` environment. The reader of CLOUDFLARE_SETTINGS_TOKEN was
    # deleted (0509 a66d6243e), so that entry is gone and the next apply revokes
    # it and deletes the secret.
    "0509-reports" = {
      repo        = "0509"
      environment = "preview"
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write"]
      zone        = []
      zones       = []
      vps_only    = false
    }
    "0509-support-inbox" = {
      repo        = "mailbox" # renamed from 0509-support-inbox; the key stays so the token is not replaced
      environment = "production"
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write", "Account Settings Read"]
      zone        = []
      zones       = []
      vps_only    = false
    }
    "siterep-public" = {
      repo        = "siterep-public"
      environment = "production"
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write", "D1 Write", "Account Settings Read"]
      zone        = ["Zone Read", "Workers Routes Write"]
      zones       = ["siterep.net"]
      vps_only    = false
    }
    "TinyStudio.io-public" = {
      repo        = "TinyStudio.io-public"
      environment = "production"
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write", "Workers R2 Storage Write", "D1 Write", "Account Settings Read"]
      zone        = ["Zone Read", "Workers Routes Write"]
      zones       = ["tinystudio.io"]
      vps_only    = false
    }
    "inish-site" = {
      repo        = "inish-site"
      environment = "production"
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write", "Account Settings Read"]
      zone        = ["Zone Read", "Workers Routes Write"]
      zones       = ["nish.sh", "inish.in"]
      vps_only    = false
    }
    "aiconverter-app" = {
      repo        = "aiconverter-app"
      environment = "production"
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Pages Write", "D1 Write", "Account Settings Read"]
      zone        = []
      zones       = []
      vps_only    = false
    }
    # Made by hand on 2026-11-01 with no expiry; this entry puts it on the
    # same 30-day rotation. Same groups as the hand-made one: `wrangler
    # preview` and `wrangler deploy` on workers.dev, with D1 migrations.
    "rera-report-card" = {
      repo        = "rera-report-card"
      environment = "production"
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write", "D1 Write", "Account Settings Read"]
      zone        = []
      zones       = []
      vps_only    = false
    }
    "seo-fix-kit" = {
      repo        = "seo-fix-kit"
      environment = "production"
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write", "D1 Write", "Queues Write", "Account Settings Read"]
      zone        = ["Zone Read", "Workers Routes Write"]
      zones       = ["seofixkit.com"]
      vps_only    = false
    }
    # Already applied by hand on 2026-10-20 under this key, so the key stays: a
    # new key would destroy the live repo secret when the old state entry goes.
    "fleet_console" = {
      repo        = "fleet-console-worker"
      environment = "production"
      secret_name = "CLOUDFLARE_API_TOKEN"
      file        = null
      account     = ["Workers Scripts Write", "Account Settings Read"]
      zone        = ["Zone Read", "Workers Routes Write"]
      zones       = ["nish.sh"]
      vps_only    = false
    }
    # Preview tokens: each PR preview job uploads a Worker version or preview
    # (wrangler preview, cf previews deploy), which needs Workers Scripts Write
    # only. aiconverter-app previews are Pages branch deploys, so its preview
    # token holds Pages Write only.
    "drive-preview"                = { repo = "drive", environment = "preview", secret_name = "CLOUDFLARE_API_TOKEN", file = null, account = ["Workers Scripts Write"], zone = [], zones = [], vps_only = false }
    "mailbox-preview"              = { repo = "mailbox", environment = "preview", secret_name = "CLOUDFLARE_API_TOKEN", file = null, account = ["Workers Scripts Write"], zone = [], zones = [], vps_only = false }
    "siterep-public-preview"       = { repo = "siterep-public", environment = "preview", secret_name = "CLOUDFLARE_API_TOKEN", file = null, account = ["Workers Scripts Write"], zone = [], zones = [], vps_only = false }
    "TinyStudio.io-public-preview" = { repo = "TinyStudio.io-public", environment = "preview", secret_name = "CLOUDFLARE_API_TOKEN", file = null, account = ["Workers Scripts Write"], zone = [], zones = [], vps_only = false }
    "inish-site-preview"           = { repo = "inish-site", environment = "preview", secret_name = "CLOUDFLARE_API_TOKEN", file = null, account = ["Workers Scripts Write"], zone = [], zones = [], vps_only = false }
    "aiconverter-app-preview"      = { repo = "aiconverter-app", environment = "preview", secret_name = "CLOUDFLARE_API_TOKEN", file = null, account = ["Pages Write"], zone = [], zones = [], vps_only = false }
    "rera-report-card-preview"     = { repo = "rera-report-card", environment = "preview", secret_name = "CLOUDFLARE_API_TOKEN", file = null, account = ["Workers Scripts Write"], zone = [], zones = [], vps_only = false }
    "seo-fix-kit-preview"          = { repo = "seo-fix-kit", environment = "preview", secret_name = "CLOUDFLARE_API_TOKEN", file = null, account = ["Workers Scripts Write"], zone = [], zones = [], vps_only = false }

    # The only consumer that is not a GitHub Actions job (fleet-ops#10169):
    # Grafana's Cloudflare data source reads this token from the 0600 env file
    # below, which ansible/host.yml renders into the grafana-cloudflare-api-token
    # Podman secret (the apply starts the host-config run that republishes it). It replaces the
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
      zones       = []
      vps_only    = true
    }
  }

  file_secrets = { for k, v in local.tokens : k => v if v.file != null }
  env_secrets  = { for k, v in local.tokens : k => v if v.environment != null }

  # Zone ids are identifiers, not credentials. The minter token cannot read
  # zones, so they are listed here instead of looked up.
  zone_ids = {
    "0509.io"       = "ff6dcd042f7b15f41e47ad456bad8665"
    "inish.in"      = "973f1715b51a583905250b6cbf602257"
    "nish.sh"       = "4506e88fbf1c3abd29b4bbc47874586a"
    "seofixkit.com" = "7cc99ce6d9d3e3d9b0055e2bd51cc8b5"
    "siterep.net"   = "1c982d78c2877499467b164d93af9d0e"
    "tinystudio.io" = "5f7ea6931ee49300d68e6102cbf497ef"
  }

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
      resources         = jsonencode({ for z in each.value.zones : "com.cloudflare.api.account.zone.${local.zone_ids[z]}" => "*" })
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
