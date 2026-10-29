terraform {
  required_version = ">= 1.8.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.27"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
    # Writes the one token whose value belongs in a 0600 file on the VPS instead
    # of a GitHub secret (main.tf, "vps-grafana").
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # State holds every token value in plain text, so it lives outside the repo
  # with the rest of this host's secrets: a 0700 directory under the home dir.
  # A backend block cannot read variables or "~", hence the absolute path. See
  # README.md ("State").
  backend "local" {
    path = "/home/nish/.local/state/fleet-ops/cloudflare-tokens/terraform.tfstate"
  }
}

# The key-making key (the minter token) is read from the environment variable
# CLOUDFLARE_API_TOKEN, loaded from ~/.config/cloudflare/token-minter.env. It is
# never a Terraform variable, so it cannot land in a plan file or in state.
provider "cloudflare" {}

# The secrets are written by the nishfleet-secrets GitHub App (Secrets and Environments write, metadata read,
# installed only on the repos in main.tf), never a person's login (fleet-ops#10601).
# The key's contents arrive as the sensitive variable github_app_pem (TF_VAR_github_app_pem, set by the unit).
provider "github" {
  owner = var.github_owner
  app_auth {
    id              = var.github_app_id
    installation_id = var.github_app_installation_id
    pem_file        = var.github_app_pem
  }
}
