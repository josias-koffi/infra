# ==============================================================================
# mode: compose — the legacy layout, one dokploy_compose for the whole stack.
# Kept so that Jobspark and Jemima move into the new project/environments
# without a rebuild; they then split service by service into mode: services.
# ==============================================================================

locals {
  compose_mode = local.mode == "compose"
  compose_cfg  = try(var.spec.compose, {})

  compose_resources = try(local.compose_cfg.resources, {})
  external_volumes  = try(var.env_spec.externalVolumes, false)

  # The file is shipped verbatim unless limits or external volumes must be
  # injected; re-encoding changes the text, which only matters on the first
  # deploy after the switch.
  compose_transform = local.compose_mode && (length(local.compose_resources) > 0 || local.external_volumes)
  compose_doc       = local.compose_transform ? yamldecode(var.compose_file) : {}

  compose_rendered = !local.compose_transform ? var.compose_file : yamlencode(merge(
    local.compose_doc,
    {
      services = {
        for name, svc in local.compose_doc.services : name => merge(
          svc,
          contains(keys(local.compose_resources), name) ? {
            deploy = merge(try(svc.deploy, {}), {
              resources = merge(try(svc.deploy.resources, {}), {
                limits = { for k, v in local.compose_resources[name] : k => tostring(v) }
              })
            })
          } : {}
        )
      }
    },
    # external: true makes compose refuse to start on a missing volume instead
    # of silently creating an empty one — the guard against a wrong prefix.
    # It is also what keeps the data when the compose is deleted: Dokploy
    # removes the named volumes of a deleted compose, but not external ones
    # (verified 2026-10-04).
    local.external_volumes && try(local.compose_doc.volumes, null) != null ? {
      volumes = {
        for name, vol in local.compose_doc.volumes : name => merge(vol == null ? {} : vol, { external = true })
      }
    } : {}
  ))

  compose_routes = { for k, r in try(local.compose_cfg.routes, {}) : k => r if local.compose_mode }
}

resource "dokploy_compose" "this" {
  count = local.compose_mode ? 1 : 0

  name           = try(local.compose_cfg.name, var.environment == "production" ? var.app : "${var.app}-${var.environment}")
  description    = "${var.app} ${var.environment} — managed by infra (manifest .deploy/manifest.yaml). Do not edit in the Dokploy UI."
  environment_id = var.environment_id
  server_id      = var.server_id
  compose_type   = "docker-compose"

  raw = {
    compose_file = local.compose_rendered
  }

  env = join("\n", concat(
    local.base_env_lines,
    [for k in local.secret_names : "${k}=${var.secrets[k]}"],
  ))

  lifecycle {
    precondition {
      condition     = var.compose_file != ""
      error_message = "mode: compose needs compose.file in the manifest."
    }
  }
}

resource "dokploy_domain" "compose" {
  for_each = local.compose_routes

  compose_id       = dokploy_compose.this[0].id
  service_name     = try(each.value.service, each.key)
  host             = local.domains[try(each.value.domain, each.key)]
  port             = each.value.port
  path             = try(each.value.path, null)
  https            = true
  certificate_type = "letsencrypt"
}
