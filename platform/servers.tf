# Remote servers. Adding one = a line in nodes.yaml + `make platform-apply`,
# then "Setup Server" once in the panel (the provider does not run the setup).
resource "dokploy_ssh_key" "nodes" {
  count = length(local.remote_nodes) > 0 ? 1 : 0

  name                   = "infra-nodes"
  description            = "Key the Dokploy manager uses to reach remote nodes. Managed in infra/platform."
  public_key             = var.node_ssh_public_key
  private_key_wo         = var.node_ssh_private_key
  private_key_wo_version = 1

  lifecycle {
    precondition {
      condition     = var.node_ssh_public_key != "" && var.node_ssh_private_key != ""
      error_message = "Remote nodes need NODE_SSH_PUBLIC_KEY and NODE_SSH_PRIVATE_KEY (make node-key)."
    }
  }
}

resource "dokploy_server" "nodes" {
  for_each = local.remote_nodes

  name                  = each.key
  description           = try(each.value.description, null)
  ip_address            = each.value.ip
  port                  = try(each.value.port, 22)
  username              = "root"
  ssh_key_id            = dokploy_ssh_key.nodes[0].id
  server_type           = "deploy"
  enable_docker_cleanup = true
}
