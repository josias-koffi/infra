variable "config_path" {
  type        = string
  description = "The zones configuration."
  default     = "zones.yaml"
}

variable "cf_account_id" {
  type        = string
  description = "Cloudflare account whose zones hold the domains (CF_ACCOUNT_ID). Empty: every zone the token sees."
  default     = ""
}

variable "resend_api_key" {
  type        = string
  description = "Resend API key with full access (RESEND_ADMIN_API_KEY): creates the sending domains."
  default     = ""
  sensitive   = true
}
