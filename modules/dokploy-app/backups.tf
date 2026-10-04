# ==============================================================================
# Backups — ON by default for every database and every named volume.
#
# Opting out takes `backups: { enabled: false, reason: "…" }` in the manifest;
# the schema refuses an opt-out without a reason.
# ==============================================================================

locals {
  # services mode: native backups of each database service.
  native_db_backups = { for k, d in local.databases : k => d if local.backups_enabled }

  # compose mode: the database lives in a compose service.
  compose_db_backups = { for k, d in try(var.spec.databases, {}) : k => d if local.backups_enabled && local.compose_mode }

  # Volumes: every app volume in services mode, the listed ones in compose mode.
  volume_backups = merge(
    { for k, v in local.app_volumes : k => { service_type = "application", service_id = dokploy_application.svc[v.app].id, service_name = null, volume = v.volume, name = v.volume, prefix = null } if local.backups_enabled },
    {
      for v in try(var.spec.compose.backupVolumes, []) : v.volume => {
        service_type = "compose"
        service_id   = dokploy_compose.this[0].id
        service_name = v.service
        volume       = "${local.volume_prefix}_${v.volume}"
        name         = try(v.name, "${v.volume} — ${var.environment}")
        # Legacy key layouts (Jobspark: api-data/<env>/) are pinned per volume.
        prefix = try(v.prefix[var.environment], null)
      } if local.backups_enabled && local.compose_mode
    }
  )

  db_service_ids = merge(
    { for k, d in dokploy_postgres.db : k => d.id },
    { for k, d in dokploy_mysql.db : k => d.id },
    { for k, d in dokploy_mariadb.db : k => d.id },
    { for k, d in dokploy_mongo.db : k => d.id },
  )
}

resource "dokploy_backup" "native" {
  for_each = local.native_db_backups

  destination_id         = var.backup_destination_id
  service_type           = each.value.type
  service_id             = local.db_service_ids[each.key]
  database               = try(each.value.database, var.app)
  cron_expression        = local.backup_db_cron
  prefix                 = "${local.backup_db_prefix}${each.key}/"
  keep_latest_count      = local.backup_keep
  include_encryption_key = true
}

resource "dokploy_backup" "compose" {
  for_each = local.compose_db_backups

  destination_id         = var.backup_destination_id
  service_type           = "compose"
  service_id             = dokploy_compose.this[0].id
  service_name           = try(each.value.service, each.key)
  compose_database_type  = each.value.type
  compose_database_user  = each.value.user
  database               = each.value.database
  cron_expression        = local.backup_db_cron
  prefix                 = local.backup_db_prefix
  keep_latest_count      = local.backup_keep
  include_encryption_key = true
}

resource "dokploy_volume_backup" "this" {
  for_each = local.volume_backups

  name              = each.value.name
  destination_id    = var.backup_destination_id
  service_type      = each.value.service_type
  service_id        = each.value.service_id
  service_name      = each.value.service_name
  volume_name       = each.value.volume
  cron_expression   = local.backup_vol_cron
  prefix            = coalesce(each.value.prefix, "${local.backup_vol_prefix}${trimprefix(each.value.volume, "${local.volume_prefix}_")}/")
  keep_latest_count = local.backup_keep
}
