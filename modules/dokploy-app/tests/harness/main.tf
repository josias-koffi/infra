terraform {
  required_providers {
    dokploy = { source = "vanillauys/dokploy" }
  }
}

# Test harness: renders one manifest/env through the module with a mocked
# provider (tofu test). Mirrors what apps/env does, minus remote states.
variable "manifest_path" { type = string }
variable "environment" { type = string }
variable "secrets" {
  type    = map(string)
  default = {}
}

locals {
  manifest = yamldecode(file(var.manifest_path))
  env_spec = local.manifest.environments[var.environment]
  root     = dirname(dirname(var.manifest_path))
  compose  = try(local.manifest.compose.file, null)
}

module "app" {
  source = "../.."

  app                   = local.manifest.name
  environment           = var.environment
  environment_id        = "env-${var.environment}"
  spec                  = local.manifest
  env_spec              = local.env_spec
  image_tag             = "abc1234"
  secrets               = { for k in concat(try(local.manifest.secrets, []), try(local.manifest.optionalSecrets, [])) : k => lookup(var.secrets, k, "s3cr3t-${lower(k)}") }
  compose_file          = local.compose != null ? (fileexists("${local.root}/${local.compose}") ? file("${local.root}/${local.compose}") : "services: {}\n") : ""
  backup_destination_id = "dest-${var.environment}"
  redeploy_after_mounts = false
}

output "rendered" {
  value     = module.app.rendered
  sensitive = true
}

output "env_keys" {
  description = "Variable names only (no values) — compared against the live stacks."
  value       = sort([for l in split("\n", nonsensitive(module.app.rendered.compose_env == null ? "" : module.app.rendered.compose_env)) : split("=", l)[0] if l != ""])
}
