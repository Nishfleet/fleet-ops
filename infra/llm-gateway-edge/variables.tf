variable "account_id" {
  description = "Cloudflare account that owns the Zero Trust Access app and policy."
  type        = string
  default     = "f670a698e17bf160c8e4679823e68916"
}

variable "zone_name" {
  description = "Zone that carries the pilot hostname; the zone data source resolves its id."
  type        = string
  default     = "nish.sh"
}

variable "hostname" {
  description = "The pilot hostname the Access app and the transform rule guard."
  type        = string
  default     = "llm.nish.sh"
}

variable "access_app_name" {
  description = "Name of the Access application the connector's check is pinned to."
  type        = string
  default     = "gh-aw pilot gateway"
}

variable "service_token_name" {
  description = "The one Access service token the policy admits."
  type        = string
  default     = "gh-aw-pilot"
}

variable "pilot_router_key" {
  description = "The LiteLLM virtual key the late-transform rule sets as x-litellm-api-key. Set as TF_VAR_pilot_router_key at plan and apply, read from the live rule; never a file in the repo."
  type        = string
  sensitive   = true
}
