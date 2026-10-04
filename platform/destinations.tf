# Backup destinations, one per environment. Every app's database and volume
# backups point at these ids (output `backup_destination_ids`).
resource "dokploy_destination" "backups" {
  for_each = var.r2_backup_buckets

  name          = "R2 backups — ${each.key}"
  provider_name = "Cloudflare"
  endpoint      = var.r2_endpoint
  bucket        = each.value
  region        = "auto"

  access_key_wo                = var.r2_backup_credentials[each.key].access_key
  secret_access_key_wo         = var.r2_backup_credentials[each.key].secret_access_key
  access_key_wo_version        = var.r2_backup_credentials_version
  secret_access_key_wo_version = var.r2_backup_credentials_version
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
