# ==============================================================================
# apps/project — the Dokploy project of one app and its environments.
#
# State: apps/<name>/project.tfstate. Run by the deploy-app workflow before the
# environment step; the environment step reads `environment_ids` from here.
#
#   tofu init -backend-config="key=apps/<name>/project.tfstate"
#   tofu apply -var manifest_path=../../../<app-repo>/.deploy/manifest.yaml
# ==============================================================================

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    dokploy = {
      source  = "vanillauys/dokploy"
      version = "~> 1.9"
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

variable "dokploy_endpoint" {
  type        = string
  description = "URL of the Dokploy panel (DOKPLOY_URL)."
}

variable "manifest_path" {
  type        = string
  description = "Path to the app's .deploy/manifest.yaml."
}

locals {
  manifest = yamldecode(file(var.manifest_path))
  app      = local.manifest.name

  # `production` is the environment Dokploy creates with every project, and
  # the API cannot delete it. Every other environment is a resource here.
  extra_envs = toset([for e in keys(local.manifest.environments) : e if e != "production"])

  # One-shot adoption of what already runs (apps/adopt/<name>.yaml).
  adopt_file = "${path.module}/../adopt/${local.app}.yaml"
  adopt      = yamldecode(fileexists(local.adopt_file) ? file(local.adopt_file) : "{}")
}

resource "dokploy_project" "this" {
  name        = local.app
  description = try(local.manifest.description, "${local.app} — managed by infra from .deploy/manifest.yaml. Do not edit in the Dokploy UI.")
}

resource "dokploy_environment" "this" {
  for_each = local.extra_envs

  project_id  = dokploy_project.this.id
  name        = each.key
  description = "${local.app} ${each.key}"
}

import {
  for_each = try(local.adopt.project, null) != null ? { this = local.adopt.project } : {}
  to       = dokploy_project.this
  id       = each.value
}

output "project_id" {
  value = dokploy_project.this.id
}

# Never derived from dokploy_project.environments: that list goes unknown on a
# project update, and an unknown environment_id would replace every service.
output "environment_ids" {
  value = merge(
    { production = dokploy_project.this.production_environment_id },
    { for e, r in dokploy_environment.this : e => r.id },
  )
}
