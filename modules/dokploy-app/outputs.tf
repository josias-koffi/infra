output "compose_id" {
  value = try(dokploy_compose.this[0].id, null)
}

output "application_ids" {
  value = { for k, a in dokploy_application.svc : k => a.id }
}

output "database_hosts" {
  description = "Internal host (Dokploy app_name) of each database and cache."
  value       = merge(local.db_hosts, { for k, c in dokploy_redis.cache : k => c.app_name })
}

output "domains" {
  value = local.domains
}

output "volume_prefix" {
  value = local.volume_prefix
}

output "rendered" {
  description = "What Dokploy receives (env files, compose text) — for tests and dry-runs."
  sensitive   = true
  value = {
    compose_env  = try(dokploy_compose.this[0].env, null)
    compose_file = try(dokploy_compose.this[0].raw.compose_file, null)
    app_env      = { for k, a in dokploy_application.svc : k => a.env }
    backups = {
      db      = merge({ for k, b in dokploy_backup.native : k => b.prefix }, { for k, b in dokploy_backup.compose : k => b.prefix })
      volumes = { for k, b in dokploy_volume_backup.this : k => { volume = b.volume_name, prefix = b.prefix } }
    }
    locked_secrets = local.locked_secret_names
    aliases        = { for k, a in dokploy_application.svc : k => try(a.swarm.network[0].aliases, null) }
    domains = merge(
      { for k, d in dokploy_domain.compose : k => "${d.host} -> ${d.service_name}:${d.port}" },
      { for k, d in dokploy_domain.app : k => "${d.host} -> :${d.port}" },
    )
  }
}

output "backup_inventory" {
  description = "What is backed up and how to test it (scripts/backups.py verify reads it from the state)."
  value = {
    databases = merge(
      {
        for k, d in local.native_db_backups : k => {
          type         = d.type
          image        = "${d.type}:${try(d.version, local.default_db_versions[d.type])}"
          database     = try(d.database, var.app)
          user         = d.user
          prefix       = dokploy_backup.native[k].prefix
          cron         = local.backup_db_cron
          verify_query = try(d.verify.query, null)
        }
      },
      {
        # The dump comes from the compose's own container: its exact version
        # is unknown here, a recent server restores older dumps.
        for k, d in local.compose_db_backups : k => {
          type         = d.type
          image        = "${d.type}:${try(d.version, local.latest_db_versions[d.type])}"
          database     = d.database
          user         = d.user
          prefix       = dokploy_backup.compose[k].prefix
          cron         = local.backup_db_cron
          verify_query = try(d.verify.query, null)
        }
      },
    )
    volumes = { for k, b in dokploy_volume_backup.this : k => { volume = b.volume_name, prefix = b.prefix, cron = local.backup_vol_cron } }
    keep    = local.backup_keep
  }
}
