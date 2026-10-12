# Dates only. Token values are never an output.
output "token_expires_on" {
  description = "When each token stops working."
  value       = { for k, t in cloudflare_api_token.token : k => t.expires_on }
}

output "next_rotation" {
  description = "When each token is replaced by the next apply."
  value       = { for k, r in time_rotating.token : k => r.rotation_rfc3339 }
}
