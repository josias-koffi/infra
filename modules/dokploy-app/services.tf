# ==============================================================================
# mode: services (default) — one Dokploy service per component.
#
#   databases.<k>  -> dokploy_postgres | dokploy_mysql | dokploy_mariadb | dokploy_mongo
#   caches.<k>     -> dokploy_redis
#   apps.<k>       -> dokploy_application (+ dokploy_domain)
#   workers.<k>    -> dokploy_application without a domain
#   <app>.volumes  -> dokploy_mount on an existing or new named volume
#
# Every service sits on dokploy-network. Database hosts are their Dokploy
# app_name (unique suffix, so staging and production never collide) and reach
# the apps through `uses:` as DATABASE_URL / REDIS_URL / … variables.
# ==============================================================================

locals {
  services_mode = local.mode == "services"

  # `for … if` rather than `cond ? x : {}`: manifest objects have per-key
  # shapes, which a conditional refuses to unify with an empty object.
  databases = { for k, d in try(var.spec.databases, {}) : k => d if local.services_mode }
  caches    = { for k, c in try(var.spec.caches, {}) : k => c if local.services_mode }

  components = merge(
    { for k, c in try(var.spec.apps, {}) : k => merge(c, { kind = "app" }) if local.services_mode },
    { for k, c in try(var.spec.workers, {}) : k => merge(c, { kind = "worker" }) if local.services_mode },
  )

  db_by_type = {
    for t in ["postgres", "mysql", "mariadb", "mongo"] :
    t => { for k, d in local.databases : k => d if d.type == t }
  }

  default_ports = { postgres = 5432, mysql = 3306, mariadb = 3306, mongo = 27017 }
  url_schemes   = { postgres = "postgresql", mysql = "mysql", mariadb = "mysql", mongo = "mongodb" }

  db_password = { for k, d in local.databases : k => var.secrets[try(d.passwordSecret, "${upper(k)}_PASSWORD")] }
  # Dokploy requires a password on every Redis.
  cache_password = { for k, c in local.caches : k => var.secrets[try(c.passwordSecret, "${upper(k)}_PASSWORD")] }
}

resource "dokploy_postgres" "db" {
  for_each = local.db_by_type.postgres

  name              = "${var.app}-${each.key}"
  app_name_prefix   = "${var.app}-${var.environment}-${each.key}"
  description       = "${var.app} ${var.environment} — ${each.key} (infra)"
  environment_id    = var.environment_id
  server_id         = var.server_id
  docker_image      = "postgres:${try(each.value.version, "16-alpine")}"
  database_name     = each.value.database
  database_user     = each.value.user
  database_password = local.db_password[each.key]
  memory_limit      = try(local.mem_bytes["db:${each.key}"], null)
  cpu_limit         = try(local.cpu_nanos["db:${each.key}"], null)
}

resource "dokploy_mysql" "db" {
  for_each = local.db_by_type.mysql

  name                   = "${var.app}-${each.key}"
  app_name_prefix        = "${var.app}-${var.environment}-${each.key}"
  environment_id         = var.environment_id
  server_id              = var.server_id
  docker_image           = "mysql:${try(each.value.version, "8")}"
  database_name          = each.value.database
  database_user          = each.value.user
  database_password      = local.db_password[each.key]
  database_root_password = var.secrets[try(each.value.rootPasswordSecret, "${upper(each.key)}_ROOT_PASSWORD")]
  memory_limit           = try(local.mem_bytes["db:${each.key}"], null)
  cpu_limit              = try(local.cpu_nanos["db:${each.key}"], null)
}

resource "dokploy_mariadb" "db" {
  for_each = local.db_by_type.mariadb

  name                   = "${var.app}-${each.key}"
  app_name_prefix        = "${var.app}-${var.environment}-${each.key}"
  environment_id         = var.environment_id
  server_id              = var.server_id
  docker_image           = "mariadb:${try(each.value.version, "11")}"
  database_name          = each.value.database
  database_user          = each.value.user
  database_password      = local.db_password[each.key]
  database_root_password = var.secrets[try(each.value.rootPasswordSecret, "${upper(each.key)}_ROOT_PASSWORD")]
  memory_limit           = try(local.mem_bytes["db:${each.key}"], null)
  cpu_limit              = try(local.cpu_nanos["db:${each.key}"], null)
}

resource "dokploy_mongo" "db" {
  for_each = local.db_by_type.mongo

  name              = "${var.app}-${each.key}"
  app_name_prefix   = "${var.app}-${var.environment}-${each.key}"
  environment_id    = var.environment_id
  server_id         = var.server_id
  docker_image      = "mongo:${try(each.value.version, "7")}"
  database_user     = each.value.user
  database_password = local.db_password[each.key]
  memory_limit      = try(local.mem_bytes["db:${each.key}"], null)
  cpu_limit         = try(local.cpu_nanos["db:${each.key}"], null)
}

resource "dokploy_redis" "cache" {
  for_each = local.caches

  name              = "${var.app}-${each.key}"
  app_name_prefix   = "${var.app}-${var.environment}-${each.key}"
  description       = "${var.app} ${var.environment} — ${each.key} (infra)"
  environment_id    = var.environment_id
  server_id         = var.server_id
  docker_image      = "redis:${try(each.value.version, "7-alpine")}"
  database_password = local.cache_password[each.key]
  memory_limit      = try(local.mem_bytes["cache:${each.key}"], null)
  cpu_limit         = try(local.cpu_nanos["cache:${each.key}"], null)
}

locals {
  db_hosts = merge(
    { for k, d in dokploy_postgres.db : k => d.app_name },
    { for k, d in dokploy_mysql.db : k => d.app_name },
    { for k, d in dokploy_mariadb.db : k => d.app_name },
    { for k, d in dokploy_mongo.db : k => d.app_name },
  )

  # Variables a component receives for each entry of its `uses:` list. The
  # prefix defaults to DATABASE / REDIS and is set with `envPrefix` when an app
  # uses two databases.
  connection_lines = {
    for name, c in local.components : name => flatten([
      for u in try(c.uses, []) : (
        contains(keys(local.databases), u) ? [
          for line in [
            ["HOST", local.db_hosts[u]],
            ["PORT", tostring(local.default_ports[local.databases[u].type])],
            ["NAME", try(local.databases[u].database, "")],
            ["USER", local.databases[u].user],
            ["PASSWORD", local.db_password[u]],
            ["URL", format("%s://%s:%s@%s:%d/%s",
              local.url_schemes[local.databases[u].type], local.databases[u].user, local.db_password[u],
            local.db_hosts[u], local.default_ports[local.databases[u].type], try(local.databases[u].database, ""))],
          ] : "${try(local.databases[u].envPrefix, "DATABASE")}_${line[0]}=${line[1]}"
          ] : contains(keys(local.caches), u) ? [
          "${try(local.caches[u].envPrefix, "REDIS")}_HOST=${dokploy_redis.cache[u].app_name}",
          "${try(local.caches[u].envPrefix, "REDIS")}_PORT=6379",
          "${try(local.caches[u].envPrefix, "REDIS")}_PASSWORD=${local.cache_password[u]}",
          "${try(local.caches[u].envPrefix, "REDIS")}_URL=redis://default:${local.cache_password[u]}@${dokploy_redis.cache[u].app_name}:6379",
          ] : contains(keys(local.components), u) ? [
          # App to app goes through the public domain: an app_name is only
          # known after its own create, and a reference between two members
          # of the same resource block would be a cycle.
          "${upper(replace(u, "-", "_"))}_URL=https://${local.domains[local.components[u].domain]}",
        ] : ["# unknown uses entry: ${u}"]
      )
    ])
  }

  # Sizes from the manifest ("512m", "1g", 0.5 CPU) to Dokploy whole numbers.
  sized = merge(
    { for k, c in local.components : "svc:${k}" => try(c.resources, {}) },
    { for k, d in local.databases : "db:${k}" => try(d.resources, {}) },
    { for k, c in local.caches : "cache:${k}" => try(c.resources, {}) },
  )
  mem_bytes = {
    for k, r in local.sized : k => tostring(
      tonumber(regex("^([0-9.]+)", lower(tostring(r.memory)))[0]) *
      lookup(local.mem_units, try(regex("([kmg])b?$", lower(tostring(r.memory)))[0], "b"), 1)
    ) if try(r.memory, null) != null
  }
  cpu_nanos = {
    for k, r in local.sized : k => tostring(floor(tonumber(r.cpus) * 1000000000)) if try(r.cpus, null) != null
  }
}

resource "dokploy_application" "svc" {
  for_each = local.components

  name            = each.key
  app_name_prefix = "${var.app}-${var.environment}-${each.key}"
  description     = "${var.app} ${var.environment} — ${each.value.kind} ${each.key} (infra)"
  environment_id  = var.environment_id
  server_id       = var.server_id

  docker = {
    image = strcontains(element(split("/", each.value.image), length(split("/", each.value.image)) - 1), ":") ? each.value.image : "${each.value.image}:${try(each.value.tag, var.image_tag)}"
  }
  registry_id = try(var.registry_ids[each.value.registry], null)

  command  = try(each.value.command, null)
  args     = try(each.value.args, null)
  replicas = try(each.value.replicas, null)

  memory_limit = try(local.mem_bytes["svc:${each.key}"], null)
  cpu_limit    = try(local.cpu_nanos["svc:${each.key}"], null)

  # Keep the image of each deploy so the panel can roll back in one click.
  rollback = { enabled = true }

  env = join("\n", concat(
    local.base_env_lines,
    local.connection_lines[each.key],
    [for k in sort(keys(try(each.value.vars, {}))) : "${k}=${templatestring(tostring(each.value.vars[k]), local.template_ctx)}"],
    [for k in local.secret_names : "${k}=${var.secrets[k]}" if contains(try(each.value.secrets, local.secret_names), k)],
  ))
}

locals {
  app_domains = merge([
    for name, c in local.components : {
      for d in try(c.domains, try([c.domain], [])) : "${name}:${d}" => {
        app  = name
        host = local.domains[d]
        port = try(c.port, 80)
        path = try(c.path, null)
      }
    } if c.kind == "app"
  ]...)

  app_volumes = merge([
    for name, c in local.components : {
      for vol, path in try(c.volumes, {}) : "${name}:${vol}" => {
        app    = name
        volume = "${local.volume_prefix}_${vol}"
        path   = path
      }
    }
  ]...)
}

resource "dokploy_domain" "app" {
  for_each = local.app_domains

  application_id   = dokploy_application.svc[each.value.app].id
  host             = each.value.host
  port             = each.value.port
  path             = each.value.path
  https            = true
  certificate_type = "letsencrypt"
}

# Named volumes keep the <prefix>_<name> convention of the compose stacks, so
# an app moving out of a compose mounts the very same volume, without a copy.
resource "dokploy_mount" "app" {
  for_each = local.app_volumes

  service_id   = dokploy_application.svc[each.value.app].id
  service_type = "application"
  type         = "volume"
  volume_name  = each.value.volume
  mount_path   = each.value.path
}
