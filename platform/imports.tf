# Adoption of what already runs on VPS20 (ids read from the Dokploy database on
# 2026-10-04). The first plan must show these imports and NO replacement.
# Keep the blocks: they are no-ops once the resources are in the state.

import {
  to = dokploy_destination.backups["production"]
  id = "s-3ZcDeOs02ykeb4vYPIz"
}

import {
  to = dokploy_destination.backups["staging"]
  id = "js7-8ZojzBM2PHsdf_vqT"
}

import {
  to = dokploy_web_server_settings.this
  id = "d4a32e7d-397b-4bb1-bdfb-a8b780b4cb6e"
}
