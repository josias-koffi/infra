# ==============================================================================
# Locked secrets — a value that cannot change once data depends on it.
#
# A database only reads its password when its volume is first initialised:
# changing DB_PASSWORD later updates the service env but not the role, and the
# apps can no longer connect. The same goes for any secret that encrypts or
# signs stored data (PAYLOAD_SECRET, an encryption key…).
#
# Locked, in every mode:
#   - the password secret of each database and cache (passwordSecret,
#     default <KEY>_PASSWORD) and the root password of mysql/mariadb;
#   - every name listed in the manifest's `lockedSecrets`.
#
# Each locked secret is stored as a SHA-256 fingerprint. scripts/deploy-app.sh
# refuses a plan that changes an existing fingerprint, unless that name is
# listed in ALLOW_SECRET_CHANGE for a deliberate, manual rotation (docs:
# guides/deploy-an-app.md#secrets-verrouillés). An empty optional secret
# (fingerprint of "") can still be set for the first time.
# ==============================================================================

locals {
  locked_secret_candidates = distinct(concat(
    [for k, d in try(var.spec.databases, {}) : try(d.passwordSecret, "${upper(k)}_PASSWORD")],
    [for k, d in try(var.spec.databases, {}) : try(d.rootPasswordSecret, "${upper(k)}_ROOT_PASSWORD") if contains(["mysql", "mariadb"], d.type)],
    [for k, c in try(var.spec.caches, {}) : try(c.passwordSecret, "${upper(k)}_PASSWORD")],
    try(var.spec.lockedSecrets, []),
  ))
  locked_secret_names = sort([for n in local.locked_secret_candidates : n if contains(local.secret_names, n)])
}

resource "terraform_data" "locked_secrets" {
  # The fingerprint is not secret: these values are long random strings, and
  # the state lives in a private bucket.
  input = { for n in local.locked_secret_names : n => nonsensitive(sha256(var.secrets[n])) }
}
