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
      version = "~> 5.26"
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
  missing_secrets = nonsensitive([for k in try(local.manifest.secrets, []) : k if !contains(keys(local.all_secrets), k)])
  secrets = merge(
    { for k in try(local.manifest.optionalSecrets, []) : k => try(local.all_secrets[k], "") },
    { for k in try(local.manifest.secrets, []) : k => try(local.all_secrets[k], "") },
  )

  compose_path = try(local.spec.compose.file, null)

  # DNS: every zone the token sees (of CF_ACCOUNT_ID when set). Each host goes
  # to the zone with the longest matching suffix, so a.b.example.com lands in
  # b.example.com when both zones exist.
  dns_managed = try(local.manifest.dns, "cloudflare") == "cloudflare"
  dns_hosts   = local.dns_managed ? try(local.env_spec.domains, {}) : {}
  zones       = { for z in try(data.cloudflare_zones.all[0].result, []) : z.name => z.id }
  zone_name_for = {
    for k, h in local.dns_hosts : k => try(split(" ", reverse(sort([
      for z in keys(local.zones) : format("%04d %s", length(z), z) if h == z || endswith(h, ".${z}")
    ]))[0])[1], null)
  }
  # CF_ZONE_ID (deprecated) still answers for a host no listed zone covers.
  zone_for       = { for k, z in local.zone_name_for : k => z != null ? local.zones[z] : (var.cf_zone_id != "" ? var.cf_zone_id : null) }
  hosts_off_zone = [for k, z in local.zone_for : local.dns_hosts[k] if z == null]

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
  # Skipped by a plan-only run on an app whose project was never applied.
  count   = var.project_state_exists ? 1 : 0
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
}

data "cloudflare_zones" "all" {
  count   = length(local.dns_hosts) > 0 ? 1 : 0
  account = var.cf_account_id != "" ? { id = var.cf_account_id } : null
  status  = "active"
}

check "secrets_present" {
  assert {
    condition     = length(local.missing_secrets) == 0
    error_message = "Missing secrets in the GitHub environment ${var.environment}: ${join(", ", local.missing_secrets)}"
  }
}

module "app" {
  source = "../../modules/dokploy-app"

  app         = local.app
  environment = var.environment
  # The placeholder only appears in a plan-only run before the first project
  # apply; a real deploy applies apps/project first.
  environment_id = try(data.terraform_remote_state.project[0].outputs.environment_ids[var.environment], "(created by apps/project)")
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
resource "cloudflare_dns_record" "domains" {
  for_each = local.dns_hosts

  zone_id = local.zone_for[each.key]
  name    = each.value
  type    = "A"
  content = local.node.ip
  ttl     = 1     # automatic
  proxied = false # Let's Encrypt HTTP challenge on the Dokploy Traefik
  comment = "${local.app} ${var.environment} — infra apps/env"

  lifecycle {
    precondition {
      condition     = length(local.hosts_off_zone) == 0
      error_message = "Not in any zone of the Cloudflare account: ${join(", ", local.hosts_off_zone)}. Add the domain to Cloudflare, or set dns: external."
    }
  }
}

# Records that carry our comment but are missing from the state are imported
# back (scripts/check-dns.py finds them). This is how the v4 -> v5 type rename
# is migrated: deploy-app.sh drops cloudflare_record from the state, which
# OpenTofu cannot decode with the v5 provider, and the records come back here.
import {
  for_each = var.dns_imports
  to       = cloudflare_dns_record.domains[each.key]
  id       = each.value
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
  to       = cloudflare_dns_record.domains[each.key]
  id       = "${local.zone_for[each.key]}/${each.value}"
}
