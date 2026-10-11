variable "dokploy_endpoint" {
  type        = string
  description = "URL of the Dokploy panel (DOKPLOY_URL)."
}

variable "state_bucket" {
  type        = string
  description = "R2 bucket holding the OpenTofu states (TF_STATE_BUCKET)."
}

variable "manifest_path" {
  type        = string
  description = "Path to the app's .deploy/manifest.yaml."
}

variable "app_root" {
  type        = string
  description = "Root of the app repository (compose.file is relative to it). Defaults to the parent of .deploy/."
  default     = null
}

variable "environment" {
  type        = string
  description = "Environment to deploy, a key of manifest.environments."
}

variable "image_tag" {
  type        = string
  description = "Image tag to deploy (git short sha). Re-run with an older tag to roll back."
}

variable "secrets_json" {
  type        = string
  description = "JSON object of secret values (the GitHub environment secrets). Only the names listed in manifest.secrets are used."
  default     = "{}"
  sensitive   = true
}

variable "cf_account_id" {
  type        = string
  description = "Cloudflare account whose zones hold the domains (CF_ACCOUNT_ID). Empty: every zone the token sees."
  default     = ""
}

variable "cf_zone_id" {
  type        = string
  description = "Deprecated (CF_ZONE_ID): zone used for a host that no zone of the account covers."
  default     = ""
}

variable "resend_api_key" {
  type        = string
  description = "Resend API key with full access (RESEND_ADMIN_API_KEY): issues the sending keys of the add-on mail."
  default     = ""
  sensitive   = true
}

variable "dns_imports" {
  type        = map(string)
  description = "Records carrying our comment that the state lacks, as key => \"zone_id/record_id\" (set by scripts/deploy-app.sh from scripts/check-dns.py)."
  default     = {}
}

variable "project_state_exists" {
  type        = bool
  description = "False only in a plan-only run before apps/project was ever applied (set by scripts/deploy-app.sh)."
  default     = true
}

variable "email_verified" {
  type        = list(string)
  description = "Confirmed Email Routing mailboxes of the account (set by scripts/deploy-app.sh from scripts/ensure-email-destinations.py). A rule towards any other is not created yet. null: no filter."
  default     = null
}
