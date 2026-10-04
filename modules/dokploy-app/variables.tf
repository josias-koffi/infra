variable "app" {
  type        = string
  description = "App name (manifest `name`)."
}

variable "environment" {
  type        = string
  description = "Environment being deployed: production, staging, …"
}

variable "environment_id" {
  type        = string
  description = "Dokploy environment id that receives every service of this env."
}

variable "server_id" {
  type        = string
  description = "Dokploy server id, null for the manager."
  default     = null
}

variable "spec" {
  type        = any
  description = "The manifest, with environments.<env>.overrides already merged (see apps/env)."
}

variable "env_spec" {
  type        = any
  description = "manifest.environments[<env>]."
}

variable "image_tag" {
  type        = string
  description = "Tag deployed for every image without an explicit tag (git short sha)."
}

variable "secrets" {
  type        = map(string)
  description = "Secret values by name, filtered on manifest `secrets`."
  default     = {}
  sensitive   = true
}

variable "compose_file" {
  type        = string
  description = "Content of the compose file (mode compose only)."
  default     = ""
}

variable "backup_destination_id" {
  type        = string
  description = "Destination of the backups of this environment."
}

variable "registry_ids" {
  type        = map(string)
  description = "Dokploy registry ids by name (platform output)."
  default     = {}
}
