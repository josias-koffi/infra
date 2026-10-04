# The single settings record of the Dokploy host. Adopted from the live server
# (imports.tf); destroy only drops it from the state.
resource "dokploy_web_server_settings" "this" {
  # Daily removal of unused images, STOPPED CONTAINERS and build cache on the
  # manager. Off until the one-off clean-up (docs/migration.md §5): it would
  # delete the stopped cvforge/traefik containers kept as rollback. The
  # housekeeping timer (images + build cache only) covers the disk meanwhile.
  enable_docker_cleanup = var.enable_docker_cleanup
  log_cleanup_cron      = "0 0 * * *"
  lets_encrypt_email    = var.lets_encrypt_email != "" ? var.lets_encrypt_email : null
}
