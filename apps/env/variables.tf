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

variable "cf_zone_id" {
  type        = string
  description = "Cloudflare zone of koklo.dev."
  default     = ""
}
