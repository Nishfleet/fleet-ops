variable "account_id" {
  description = "Cloudflare account that owns the Workers, D1, Queues and Pages projects the repos deploy."
  type        = string
  default     = "f670a698e17bf160c8e4679823e68916"
}

variable "github_owner" {
  description = "GitHub organisation that owns the repos."
  type        = string
  default     = "Nishfleet"
}

variable "rotation_days" {
  description = "Days before a token is replaced. Replacement happens on the first apply after this many days."
  type        = number
  default     = 30
}

variable "expiry_days" {
  description = "Days a token lives. Keep it longer than rotation_days: the gap is the grace period if an apply is late."
  type        = number
  default     = 45

  validation {
    condition     = var.expiry_days > var.rotation_days
    error_message = "expiry_days must be longer than rotation_days, or a token expires before its replacement exists."
  }
}

variable "vps_cidrs" {
  description = "The VPS's addresses, used to IP-lock a token whose jobs all run on the VPS self-hosted runners. Not kept in git: set it in a gitignored *.tfvars file before turning vps_only on for any token."
  type        = list(string)
  default     = []
}

variable "github_app_id" {
  description = "The nishfleet-secrets GitHub App, which writes the repo secrets (Secrets and Environments write only)."
  type        = string
  default     = "5509997"
}

variable "github_app_installation_id" {
  description = "Its installation on the org, limited to the repos in main.tf."
  type        = string
  default     = "176168389"
}

variable "github_app_pem" {
  description = "The App's private key contents. Set as TF_VAR_github_app_pem by the unit; never in a file in the repo."
  type        = string
  sensitive   = true
}
