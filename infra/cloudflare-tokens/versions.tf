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

# The GitHub login that writes the secrets is read from GITHUB_TOKEN.
provider "github" {
  owner = var.github_owner
}
