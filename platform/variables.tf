variable "dokploy_endpoint" {
  type        = string
  description = "Base URL of the Dokploy panel."
  default     = "https://dokploy.ops.koklo.dev"
}

variable "enable_docker_cleanup" {
  type        = bool
  description = "Dokploy daily Docker cleanup on the manager. On in the live server when adopted (2026-10-04); stopped containers kept as rollback survived it."
  default     = true
}

variable "lets_encrypt_email" {
  type        = string
  description = "Contact address of the Let's Encrypt account of the Dokploy host."
  default     = ""
}

# Backups ---------------------------------------------------------------------
# One bucket and one token per environment: an R2 token is scoped to whole
# buckets, so staging credentials can never read or delete production dumps.

variable "r2_endpoint" {
  type        = string
  description = "R2 S3 endpoint (same account as the state bucket)."
}

variable "r2_backup_buckets" {
  type        = map(string)
  description = "Backup bucket per environment."
  default = {
    production = "koklo-db-backups"
    staging    = "koklo-db-backups-staging"
  }
}

variable "r2_backup_credentials" {
  type = map(object({
    access_key        = string
    secret_access_key = string
  }))
  description = "R2 token per environment, keys matching r2_backup_buckets. Write-only: never stored in the state."
  sensitive   = true
}

variable "r2_backup_credentials_version" {
  type        = number
  description = "Bump to push rotated r2_backup_credentials to Dokploy."
  default     = 1
}

variable "dokploy_backup_keep" {
  type        = number
  description = "Number of daily backups of the Dokploy instance to keep."
  default     = 14
}

# Registry --------------------------------------------------------------------

variable "ghcr_username" {
  type        = string
  description = "GitHub user that pulls private GHCR images. Empty disables the registry record."
  default     = ""
}

variable "ghcr_token" {
  type        = string
  description = "Token with read:packages for ghcr_username."
  default     = ""
  sensitive   = true
}

# Nodes -----------------------------------------------------------------------

variable "node_ssh_public_key" {
  type        = string
  description = "Public key Dokploy uses to reach remote nodes (installed by the dokploy-node Ansible role)."
  default     = ""
}

variable "node_ssh_private_key" {
  type        = string
  description = "Private half of node_ssh_public_key. Write-only."
  default     = ""
  sensitive   = true
}
