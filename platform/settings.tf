# The single settings record of the Dokploy host. Adopted from the live server
# (imports.tf); destroy only drops it from the state.
resource "dokploy_web_server_settings" "this" {
  # Dokploy's daily Docker cleanup on the manager, kept as found on the live
  # server. The Ansible housekeeping timer complements it (images + build cache).
  enable_docker_cleanup = var.enable_docker_cleanup
  log_cleanup_cron      = "0 0 * * *"
  lets_encrypt_email    = var.lets_encrypt_email != "" ? var.lets_encrypt_email : null
}
