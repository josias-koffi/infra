# Adoption of an EXISTING Dokploy (docs/getting-started/existing-dokploy.md).
# platform/adopt.yaml lists the ids of the records to take over; a fresh install
# has no such file and these blocks do nothing. Keep the file after adoption:
# the imports are no-ops once the resources are in the state.
locals {
  adopt = yamldecode(fileexists("${path.module}/adopt.yaml") ? file("${path.module}/adopt.yaml") : "{}")
}

import {
  for_each = try(local.adopt.destinations, {})
  to       = dokploy_destination.backups[each.key]
  id       = each.value
}

import {
  for_each = { for k, v in { this = try(local.adopt.settings, null) } : k => v if v != null }
  to       = dokploy_web_server_settings.this
  id       = each.value
}
