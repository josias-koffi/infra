# ==============================================================================
# Add-ons — resources outside Dokploy that the manifest asks for by name.
# Their variables reach the components that `use` them (every add-on in
# compose mode) through module.app's `addons` input.
#
# buckets.<key>  an R2 bucket, EU jurisdiction by default, and a token that can
#                only read and write that bucket. Injected, with envPrefix S3:
#                S3_ENDPOINT, S3_BUCKET, S3_REGION, S3_ACCESS_KEY_ID,
#                S3_SECRET_ACCESS_KEY, S3_FORCE_PATH_STYLE.
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

  addons = {
    for k, b in local.buckets : k => {
      "${b.prefix}_ENDPOINT"          = local.r2_endpoint[k]
      "${b.prefix}_BUCKET"            = cloudflare_r2_bucket.this[k].name
      "${b.prefix}_REGION"            = "auto"
      "${b.prefix}_FORCE_PATH_STYLE"  = "true"
      "${b.prefix}_ACCESS_KEY_ID"     = cloudflare_account_token.bucket[k].id
      "${b.prefix}_SECRET_ACCESS_KEY" = sha256(cloudflare_account_token.bucket[k].value)
    }
  }
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
