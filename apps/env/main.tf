# ==============================================================================
# apps/env — one environment of one app, driven by its manifest.
#
# State: apps/<name>/<env>.tfstate, so a staging apply can never touch
# production. Run by .github/workflows/deploy-app.yml after apps/project.
# ==============================================================================

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    dokploy = {
      source  = "vanillauys/dokploy"
      version = "~> 1.9"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    # bucket: -backend-config="bucket=$TF_STATE_BUCKET" (see Makefile)
    region = "auto"

    use_path_style              = true
    use_lockfile                = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

provider "dokploy" {
  endpoint = var.dokploy_endpoint
}

provider "cloudflare" {
  # CLOUDFLARE_API_TOKEN from the environment.
}

locals {
  manifest = yamldecode(file(var.manifest_path))
  app      = local.manifest.name
  app_root = coalesce(var.app_root, dirname(dirname(abspath(var.manifest_path))))

  env_spec  = local.manifest.environments[var.environment]
  overrides = try(local.env_spec.overrides, {})

  # Two-level merge of environments.<env>.overrides: per component, and per
  # `resources` block inside it. Anything deeper is replaced, not merged.
  sections = ["apps", "workers", "databases", "caches"]
  spec = merge(local.manifest, {
    for s in local.sections : s => {
      for k, c in try(local.manifest[s], {}) : k => merge(
        c,
        try(local.overrides[s][k], {}),
        can(c.resources) || can(local.overrides[s][k].resources) ? {
          resources = merge(try(c.resources, {}), try(local.overrides[s][k].resources, {}))
        } : {}
      )
    } if can(local.manifest[s])
    }, can(local.overrides.compose) ? {
    compose = merge(try(local.manifest.compose, {}), local.overrides.compose)
  } : {})

  server = try(local.manifest.server, "vps20")
  node   = data.terraform_remote_state.platform.outputs.nodes[local.server]

  all_secrets = jsondecode(var.secrets_json)
  # `secrets` must exist in the GitHub environment; `optionalSecrets` default
  # to an empty string (features that stay off until their key is set).
  missing_secrets = [for k in try(local.manifest.secrets, []) : k if !contains(keys(local.all_secrets), k)]
  secrets = merge(
    { for k in try(local.manifest.optionalSecrets, []) : k => try(local.all_secrets[k], "") },
    { for k in try(local.manifest.secrets, []) : k => try(local.all_secrets[k], "") },
  )

  compose_path = try(local.spec.compose.file, null)

  adopt_file = "${path.module}/../adopt/${local.app}.yaml"
  adopt      = try(yamldecode(file(local.adopt_file)).environments[var.environment], {})
}

data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket                      = var.state_bucket
    key                         = "platform/dokploy.tfstate"
    region                      = "auto"
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

data "terraform_remote_state" "project" {
  backend = "s3"
  config = {
    bucket                      = var.state_bucket
    key                         = "apps/${local.app}/project.tfstate"
    region                      = "auto"
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
  # A plan-only run on a new app happens before apps/project was ever applied.
  defaults = { environment_ids = {} }
}

check "secrets_present" {
  assert {
    condition     = length(local.missing_secrets) == 0
    error_message = "Missing secrets in the GitHub environment ${var.environment}: ${join(", ", local.missing_secrets)}"
  }
}

module "app" {
  source = "../../modules/dokploy-app"

  app            = local.app
  environment    = var.environment
  # The placeholder only appears in a plan-only run before the first project
  # apply; a real deploy applies apps/project first.
  environment_id = try(data.terraform_remote_state.project.outputs.environment_ids[var.environment], "(created by apps/project)")
  server_id      = local.node.server_id

  spec         = local.spec
  env_spec     = local.env_spec
  image_tag    = var.image_tag
  secrets      = local.secrets
  compose_file = local.compose_path != null ? file("${local.app_root}/${local.compose_path}") : ""

  dokploy_endpoint      = var.dokploy_endpoint
  backup_destination_id = data.terraform_remote_state.platform.outputs.backup_destination_ids[var.environment == "production" ? "production" : "staging"]
  registry_ids          = data.terraform_remote_state.platform.outputs.registry_ids
}

# DNS: one A record per domain of the env, to the node that runs it. Apps whose
# records still live elsewhere set `dns: external` until they are adopted.
resource "cloudflare_record" "domains" {
  for_each = try(local.manifest.dns, "cloudflare") == "cloudflare" ? try(local.env_spec.domains, {}) : {}

  zone_id = var.cf_zone_id
  name    = each.value
  type    = "A"
  content = local.node.ip
  proxied = false # Let's Encrypt HTTP challenge on the Dokploy Traefik
  comment = "${local.app} ${var.environment} — infra apps/env"
}

# --- One-shot adoption (apps/adopt/<name>.yaml) ------------------------------
import {
  for_each = try(local.adopt.compose, null) != null ? { this = local.adopt.compose } : {}
  to       = module.app.dokploy_compose.this[0]
  id       = each.value
}

import {
  for_each = try(local.adopt.domains, {})
  to       = module.app.dokploy_domain.compose[each.key]
  id       = each.value
}

import {
  for_each = try(local.adopt.backups, {})
  to       = module.app.dokploy_backup.compose[each.key]
  id       = each.value
}

import {
  for_each = try(local.adopt.volumeBackups, {})
  to       = module.app.dokploy_volume_backup.this[each.key]
  id       = each.value
}

import {
  for_each = try(local.adopt.dnsRecords, {})
  to       = cloudflare_record.domains[each.key]
  id       = "${var.cf_zone_id}/${each.value}"
}
