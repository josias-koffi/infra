# ==============================================================================
# Add-ons — resources outside Dokploy that the manifest asks for by name.
# Their variables reach the components that `use` them (every add-on in
# compose mode) through module.app's `addons` input.
#
# buckets.<key>  an R2 bucket, EU jurisdiction by default, and a token that can
#                only read and write that bucket. Injected, with envPrefix S3:
#                S3_ENDPOINT, S3_BUCKET, S3_REGION, S3_ACCESS_KEY_ID,
#                S3_SECRET_ACCESS_KEY, S3_FORCE_PATH_STYLE.
#
# mail           a Resend key that can only send, from one domain of
#                zones/zones.yaml (default: the zone of the env's first domain).
#                Injected: RESEND_API_KEY, MAIL_DOMAIN, and SMTP_HOST/PORT/USER/
#                PASSWORD for the apps that speak SMTP.
# ==============================================================================

locals {
  buckets = {
    for k, b in try(local.spec.buckets, {}) : k => {
      name         = try(b.name, "${local.app}-${var.environment}-${k}")
      jurisdiction = try(b.jurisdiction, "eu")
      prefix       = try(b.envPrefix, "S3")
    }
  }
  # The S3 endpoint carries the jurisdiction: an EU bucket is not reachable
  # through the default endpoint.
  r2_endpoint = {
    for k, b in local.buckets : k => b.jurisdiction == "default"
    ? "https://${var.cf_account_id}.r2.cloudflarestorage.com"
    : "https://${var.cf_account_id}.${b.jurisdiction}.r2.cloudflarestorage.com"
  }

  mail_spec = try(local.spec.mail, null)
  # Default sending domain: the zone of the first domain of the environment.
  # (dns: external apps write mail.domain: their zones are not looked up.)
  mail_domain   = local.mail_spec == null ? null : try(local.mail_spec.domain, local.zone_name_for[sort(keys(local.zone_name_for))[0]], null)
  mail_domains  = try(data.terraform_remote_state.zones[0].outputs.mail_domains, {})
  mail_key_name = "${local.app} ${var.environment} (infra apps/env)"

  addons = merge({
    for k, b in local.buckets : k => {
      "${b.prefix}_ENDPOINT"          = local.r2_endpoint[k]
      "${b.prefix}_BUCKET"            = cloudflare_r2_bucket.this[k].name
      "${b.prefix}_REGION"            = "auto"
      "${b.prefix}_FORCE_PATH_STYLE"  = "true"
      "${b.prefix}_ACCESS_KEY_ID"     = cloudflare_account_token.bucket[k].id
      "${b.prefix}_SECRET_ACCESS_KEY" = sha256(cloudflare_account_token.bucket[k].value)
    }
    }, local.mail_spec == null ? {} : {
    mail = {
      RESEND_API_KEY = jsondecode(restapi_object.mail_key[0].create_response).token
      MAIL_DOMAIN    = local.mail_domain
      SMTP_HOST      = "smtp.resend.com"
      SMTP_PORT      = "587"
      SMTP_USER      = "resend"
      SMTP_PASSWORD  = jsondecode(restapi_object.mail_key[0].create_response).token
    }
  })
}

data "cloudflare_account_api_token_permission_groups" "r2_bucket_write" {
  count      = length(local.buckets) > 0 ? 1 : 0
  account_id = var.cf_account_id
  name       = "Workers%20R2%20Storage%20Bucket%20Item%20Write"
  scope      = "com.cloudflare.edge.r2.bucket"
}

resource "cloudflare_r2_bucket" "this" {
  for_each = local.buckets

  account_id   = var.cf_account_id
  name         = each.value.name
  jurisdiction = each.value.jurisdiction

  lifecycle {
    precondition {
      condition     = var.cf_account_id != ""
      error_message = "buckets need CF_ACCOUNT_ID (infra repo secret)."
    }
  }
}

# R2's S3 API takes a Cloudflare token as credentials: the access key is the
# token id, the secret is the SHA-256 of its value. This token only reaches
# its own bucket.
resource "cloudflare_account_token" "bucket" {
  for_each = local.buckets

  account_id = var.cf_account_id
  name       = "${local.app} ${var.environment} — R2 ${each.value.name} (infra apps/env)"
  policies = [{
    effect = "allow"
    permission_groups = [{
      id = one([for g in data.cloudflare_account_api_token_permission_groups.r2_bucket_write[0].permission_groups : g.id if g.name == "Workers R2 Storage Bucket Item Write"])
    }]
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.cf_account_id}_${each.value.jurisdiction}_${cloudflare_r2_bucket.this[each.key].name}" = "*"
    })
  }]
}

# A bucket made by hand: apps/adopt/<app>.yaml → environments.<env>.buckets.<key>: <name>.
import {
  for_each = try(local.adopt.buckets, {})
  to       = cloudflare_r2_bucket.this[each.key]
  id       = "${var.cf_account_id}/${each.value}/${local.buckets[each.key].jurisdiction}"
}

data "terraform_remote_state" "zones" {
  count   = local.mail_spec != null ? 1 : 0
  backend = "s3"
  config = {
    bucket                      = var.state_bucket
    key                         = "zones/zones.tfstate"
    region                      = "auto"
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

# Resend shows a key's token once, in the answer to its creation: it is kept
# from create_response. Resend has no read by id, so the key is found back by
# its name in the list of keys.
resource "restapi_object" "mail_key" {
  count = local.mail_spec != null ? 1 : 0

  path = "/api-keys"
  data = jsonencode({
    name       = local.mail_key_name
    permission = "sending_access"
    domain_id  = try(local.mail_domains[local.mail_domain].id, "")
  })
  read_path   = "/api-keys"
  read_search = { results_key = "data", search_key = "name", search_value = local.mail_key_name }
  # Keys cannot be edited: any change makes a new one.
  ignore_all_server_changes = true
  force_new                 = ["name", "permission", "domain_id"]

  lifecycle {
    precondition {
      condition     = contains(keys(local.mail_domains), coalesce(local.mail_domain, "-"))
      error_message = "mail: ${coalesce(local.mail_domain, "no domain")} is not a sending domain yet — add it to zones/zones.yaml (mail:) and apply zones/ first."
    }
  }
}

# What the backup jobs read from this state (scripts/backups.py): databases and
# volumes (Dokploy backs them up), buckets (copied by bucket-backup.yml).
resource "terraform_data" "backup_inventory" {
  input = merge(module.app.backup_inventory, {
    environment = var.environment == "production" ? "production" : "staging"
    buckets = {
      for k, b in local.buckets : k => {
        name         = cloudflare_r2_bucket.this[k].name
        jurisdiction = b.jurisdiction
        endpoint     = local.r2_endpoint[k]
        prefix       = "buckets/${local.app}/${var.environment}/${k}/"
      } if try(local.spec.buckets[k].backup, true)
    }
  })
}
