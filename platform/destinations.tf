# Backup destinations, one per environment. Every app's database and volume
# backups point at these ids (output `backup_destination_ids`).
#
# Two sources for the buckets:
#   eu_backup_buckets = false  the buckets and tokens of .env (R2_BACKUP_*),
#                              made by hand (default jurisdiction);
#   eu_backup_buckets = true   buckets created here in the EU jurisdiction
#                              (<bucket>-eu, GDPR) with a token limited to each.
# Switching only moves where the next dumps go: the destination ids stay, so
# every app follows without a deploy. Older dumps stay in the old buckets until
# their retention ends (restore from there meanwhile).

locals {
  backup_targets = {
    for env, bucket in var.r2_backup_buckets : env => var.eu_backup_buckets ? {
      bucket   = cloudflare_r2_bucket.backups_eu[env].name
      endpoint = "https://${var.cf_account_id}.eu.r2.cloudflarestorage.com"
      } : {
      bucket   = bucket
      endpoint = var.r2_endpoint
    }
  }
  backup_credentials = {
    for env, _ in var.r2_backup_buckets : env => var.eu_backup_buckets ? {
      access_key        = cloudflare_account_token.backups_eu[env].id
      secret_access_key = sha256(cloudflare_account_token.backups_eu[env].value)
    } : var.r2_backup_credentials[env]
  }
}

# The _list data source: the single one (cloudflare_account_api_token_permission_groups)
# returns permission_groups = null in provider 5.27.
data "cloudflare_account_api_token_permission_groups_list" "r2_bucket_write" {
  count      = var.eu_backup_buckets ? 1 : 0
  account_id = var.cf_account_id
  name       = "Workers R2 Storage Bucket Item Write"
  scope      = "com.cloudflare.edge.r2.bucket"
}

resource "cloudflare_r2_bucket" "backups_eu" {
  for_each = var.eu_backup_buckets ? var.r2_backup_buckets : {}

  account_id   = var.cf_account_id
  name         = "${each.value}-eu"
  jurisdiction = "eu"

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = var.cf_account_id != ""
      error_message = "eu_backup_buckets needs CF_ACCOUNT_ID."
    }
  }
}

resource "cloudflare_account_token" "backups_eu" {
  for_each = var.eu_backup_buckets ? var.r2_backup_buckets : {}

  account_id = var.cf_account_id
  name       = "Dokploy backups ${each.key} — ${cloudflare_r2_bucket.backups_eu[each.key].name} (infra platform)"
  policies = [{
    effect = "allow"
    permission_groups = [{
      id = one([for g in data.cloudflare_account_api_token_permission_groups_list.r2_bucket_write[0].result : g.id if g.name == "Workers R2 Storage Bucket Item Write"])
    }]
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.cf_account_id}_eu_${cloudflare_r2_bucket.backups_eu[each.key].name}" = "*"
    })
  }]
}

resource "dokploy_destination" "backups" {
  for_each = var.r2_backup_buckets

  name          = "R2 backups — ${each.key}"
  provider_name = "Cloudflare"
  endpoint      = local.backup_targets[each.key].endpoint
  bucket        = local.backup_targets[each.key].bucket
  region        = "auto"

  access_key_wo        = local.backup_credentials[each.key].access_key
  secret_access_key_wo = local.backup_credentials[each.key].secret_access_key
  # Write-only values are pushed when the version changes: switching the
  # source of the buckets pushes the new token.
  access_key_wo_version        = var.r2_backup_credentials_version + (var.eu_backup_buckets ? 1000 : 0)
  secret_access_key_wo_version = var.r2_backup_credentials_version + (var.eu_backup_buckets ? 1000 : 0)

  # Dokploy lists the bucket with these credentials before saving them: a wrong
  # token fails the apply instead of failing tonight's backups.
  verify_connection = true
}

# Daily backup of Dokploy itself (its database and /etc/dokploy), so a lost
# VPS is rebuilt from code + this dump instead of a hand-made snapshot.
resource "dokploy_web_server_backup" "dokploy" {
  destination_id         = dokploy_destination.backups["production"].id
  cron_expression        = "30 2 * * *"
  prefix                 = "dokploy/"
  keep_latest_count      = var.dokploy_backup_keep
  include_encryption_key = true
}
