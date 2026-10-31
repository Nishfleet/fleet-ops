terraform {
  required_version = ">= 1.8.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.27"
    }
  }

  # State holds the pilot router key inside the transform rule, so it lives
  # outside the repo with the rest of this host's secrets, encrypted the same
  # way as infra/cloudflare-tokens (README.md, "State"). A backend block cannot
  # read variables or "~", hence the absolute path.
  backend "local" {
    path = "/home/nish/.local/state/fleet-ops/llm-gateway-edge/terraform.tfstate"
  }
}

# The API token comes from the environment variable CLOUDFLARE_API_TOKEN; the
# permissions it needs and the mint gate are in README.md ("Apply").
provider "cloudflare" {}
