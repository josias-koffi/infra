locals {
  is_production = var.environment == "production"
  mode          = try(var.spec.mode, "services")

  # Prefix of every named volume of this env. Migrated apps pin the exact
  # prefix of their live volumes (jobspark, cvspark-staging, …) — never derive
  # it for them, a wrong prefix starts the stack on empty volumes.
  volume_prefix = try(var.env_spec.volumePrefix, "${var.app}-${var.environment}")

  # Domain key -> host, e.g. { api = "jobspark-api.koklo.dev" }.
  domains = try(var.env_spec.domains, {})

  # Configuration: manifest-wide `vars`, then the env's own. Values are
  # templates: `${secrets.POSTGRES_PASSWORD}`, `${domains.api}`, `${env}`,
  # `${app}`, `${volume_prefix}`, `${compose_sha}` (12 chars of the compose
  # file hash, to force a recreate when only an inline config changed).
  # A literal `${` is written `$${`.
  raw_vars = merge(try(var.spec.vars, {}), try(var.env_spec.vars, {}))
  template_ctx = {
    secrets       = var.secrets
    domains       = try(var.env_spec.domains, {})
    env           = var.environment
    app           = var.app
    volume_prefix = local.volume_prefix
    compose_sha   = substr(sha1(var.compose_file), 0, 12)
  }
  vars = { for k, v in local.raw_vars : k => templatestring(tostring(v), local.template_ctx) }

  # Every service of the env receives these, before its own variables.
  base_env_lines = concat(
    [
      "APP_ENV=${var.environment}",
      "IMAGE_TAG=${var.image_tag}",
      # Served back by health endpoints, so a deploy can assert what runs.
      "APP_VERSION=${var.image_tag}",
      "VOLUME_PREFIX=${local.volume_prefix}",
    ],
    [for k in sort(keys(local.domains)) : "${upper(replace(k, "-", "_"))}_DOMAIN=${local.domains[k]}"],
    [for k in sort(keys(local.vars)) : "${k}=${local.vars[k]}"],
  )

  secret_names = sort(nonsensitive(keys(var.secrets)))

  # --- Backups: ON by default -------------------------------------------------
  backups         = try(var.spec.backups, {})
  backups_enabled = try(local.backups.enabled, true)
  backup_keep     = try(local.backups.keep[var.environment], local.is_production ? 35 : 7)
  backup_db_cron  = try(local.backups.cron, "0 3 * * *")
  backup_vol_cron = try(local.backups.volumeCron, "0 4 * * *")
  # R2 key layout: db/<app>/<env>/… and volumes/<app>/<env>/…, unless the
  # manifest pins a legacy prefix (Jobspark keeps db/production/ so that its
  # restore_check sidecar keeps finding the dumps).
  backup_db_prefix  = try(local.backups.prefix.db[var.environment], "db/${var.app}/${var.environment}/")
  backup_vol_prefix = try(local.backups.prefix.volumes[var.environment], "volumes/${var.app}/${var.environment}/")

  # --- Resource helpers ---------------------------------------------------------
  # Dokploy wants whole numbers: bytes for memory, nano-CPUs for CPU.
  mem_units = { b = 1, k = 1024, m = 1048576, g = 1073741824 }
}
