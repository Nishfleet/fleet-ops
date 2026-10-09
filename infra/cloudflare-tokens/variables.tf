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
  description = "The VPS's addresses, used to IP-lock a token whose jobs all run on the VPS self-hosted runners."
  type        = list(string)
  default = [
    "159.195.212.168/32",
    "2a0a:4cc0:c4:d5e:a8cb:f5ff:feb3:ed15/128",
  ]
}
