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
    domains = merge(
      { for k, d in dokploy_domain.compose : k => "${d.host} -> ${d.service_name}:${d.port}" },
      { for k, d in dokploy_domain.app : k => "${d.host} -> :${d.port}" },
    )
  }
}
