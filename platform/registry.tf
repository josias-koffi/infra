# Pull credentials for private ghcr.io images. Apps reference the id through
# the `registry_id` output when their manifest says `registry: ghcr`.
resource "dokploy_registry" "ghcr" {
  count = var.ghcr_username != "" ? 1 : 0

  name                = "ghcr"
  registry_type       = "cloud"
  url                 = "ghcr.io"
  username            = var.ghcr_username
  password_wo         = var.ghcr_token
  password_wo_version = 1
}
