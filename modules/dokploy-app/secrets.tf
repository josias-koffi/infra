# ==============================================================================
# Secret values — given by a human, or generated here.
#
# `secrets` / `optionalSecrets`  typed by a human (GitHub environment <app>-<env>
#                                of the infra repo); a missing optional one is "".
# `generate`                     created once by infra and kept in this env's
#                                state: a list of names, or { NAME: { length, special } }.
#                                Injected like the typed ones.
# database / cache passwords     generated too when the manifest does not list
#                                them (<KEY>_PASSWORD, <KEY>_ROOT_PASSWORD of
#                                mysql/mariadb, or passwordSecret): the
#                                components reach them through `uses`.
#
# A value given in the GitHub environment always wins over the generated one:
# apps that typed their passwords keep them, and a generated value can be
# replaced on purpose. Generated values are locked like the others
# (locks.tf), so losing a typed value never silently switches the database
# to a new password.
# ==============================================================================

locals {
  declared_secrets = distinct(concat(try(var.spec.secrets, []), try(var.spec.optionalSecrets, [])))

  generate_raw      = try(var.spec.generate, [])
  generate_explicit = try({ for n in tolist(local.generate_raw) : n => {} }, { for n, g in local.generate_raw : n => g })

  password_secrets = distinct(concat(
    [for k, d in try(var.spec.databases, {}) : try(d.passwordSecret, "${upper(k)}_PASSWORD")],
    [for k, d in try(var.spec.databases, {}) : try(d.rootPasswordSecret, "${upper(k)}_ROOT_PASSWORD") if contains(["mysql", "mariadb"], d.type)],
    [for k, c in try(var.spec.caches, {}) : try(c.passwordSecret, "${upper(k)}_PASSWORD")],
  ))
  generate_implicit = { for n in local.password_secrets : n => {} if !contains(local.declared_secrets, n) }
  generate          = merge(local.generate_implicit, local.generate_explicit)

  secret_values = merge(
    { for n in local.declared_secrets : n => try(var.secrets[n], "") },
    { for n in keys(local.generate) : n => try(var.secrets[n], "") != "" ? var.secrets[n] : random_password.generated[n].result },
  )
  # Every known name (locks), and the ones injected as plain variables: not
  # the implicit passwords, which only the components that `use` them get.
  secret_names     = sort(concat(local.declared_secrets, keys(local.generate)))
  env_secret_names = sort(distinct(concat(local.declared_secrets, keys(local.generate_explicit))))
}

resource "random_password" "generated" {
  for_each = local.generate

  length = try(each.value.length, 32)
  # Letters and digits by default: the value often ends up inside a URL.
  special = try(each.value.special, false)
}
