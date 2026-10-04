output "backup_destination_ids" {
  description = "Backup destination id per environment."
  value       = { for env, d in dokploy_destination.backups : env => d.id }
}

output "nodes" {
  description = "Every node: ip, role, and the Dokploy server_id (null for the manager)."
  value = {
    for name, n in local.nodes : name => {
      ip        = n.ip
      role      = try(n.role, "remote")
      server_id = try(dokploy_server.nodes[name].id, null)
    }
  }
}

output "registry_ids" {
  description = "Registry id by name."
  value       = { for r in dokploy_registry.ghcr : r.name => r.id }
}

output "dokploy_node_public_key" {
  description = "Public key to install on remote nodes (dokploy-node role)."
  value       = var.node_ssh_public_key
}
