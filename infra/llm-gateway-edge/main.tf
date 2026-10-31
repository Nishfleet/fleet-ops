# The edge guard of the gh-aw pilot gateway, managed here so a change shows up
# in review instead of in the dashboard (fleet-ops#11371, finding 2). The
# connector checks the Access JWT itself (config/cloudflared/llm-gateway.yml,
# originRequest.access), and its pinned AUD tag must equal the aud output
# below; tests/test_llm_gateway_tunnel.py fails CI when they drift.

data "cloudflare_zone" "pilot_zone" {
  filter = {
    name = var.zone_name
  }
}

data "cloudflare_zero_trust_access_service_token" "pilot" {
  account_id = var.account_id
  filter = {
    name = var.service_token_name
  }
}

resource "cloudflare_zero_trust_access_application" "pilot_gateway" {
  account_id = var.account_id
  name       = var.access_app_name
  type       = "self_hosted"
  domain     = var.hostname

  # gh-aw sends exactly one auth header (ADR-35694), so Access reads the
  # service token as one JSON value from Authorization.
  read_service_tokens_from_header = "Authorization"
  app_launcher_visible            = false

  policies = [{
    id         = cloudflare_zero_trust_access_policy.service_auth.id
    precedence = 1
  }]
}

resource "cloudflare_zero_trust_access_policy" "service_auth" {
  account_id = var.account_id
  name       = "Service Auth: ${var.service_token_name} only"
  decision   = "non_identity"

  include = [{
    service_token = {
      token_id = data.cloudflare_zero_trust_access_service_token.pilot.id
    }
  }]
}

resource "cloudflare_ruleset" "pilot_key_transform" {
  zone_id     = data.cloudflare_zone.pilot_zone.id
  name        = "gh-aw pilot gateway: set the router key"
  description = "Replaces whatever key the caller sent with the pilot router key, so only the pilot key reaches the router through this hostname (fleet-ops#11311)."
  kind        = "zone"
  phase       = "http_request_late_transform"

  rules = [{
    action     = "rewrite"
    expression = "(http.host eq \"${var.hostname}\")"
    enabled    = true

    action_parameters = {
      headers = {
        x-litellm-api-key = {
          operation = "set"
          value     = var.pilot_router_key
        }
      }
    }
  }]
}

output "access_aud" {
  description = "The Access app's AUD tag. Pin it as originRequest.access.audTag in config/cloudflared/llm-gateway.yml."
  value       = cloudflare_zero_trust_access_application.pilot_gateway.aud
}
