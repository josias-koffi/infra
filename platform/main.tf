# ==============================================================================
# platform/ — the Dokploy instance itself, as code.
#
# Owns what is shared by every app: host settings (Docker cleanup), backup
# destinations, the backup of Dokploy itself, the GHCR registry and the
# remote servers (nodes). Apps never declare these; they read them from
# this state's outputs (see modules/dokploy-app).
#
#   make platform-plan / make platform-apply
# ==============================================================================

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    dokploy = {
      source  = "vanillauys/dokploy"
      version = "~> 1.9"
    }
  }

  # Same R2 bucket as every other Koklo state. Endpoint and credentials come
  # from AWS_ENDPOINT_URL_S3 / AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.
  backend "s3" {
    bucket = "koklo-tofu-state"
    key    = "platform/dokploy.tfstate"
    region = "auto"

    use_path_style              = true
    use_lockfile                = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

provider "dokploy" {
  endpoint = var.dokploy_endpoint
  # api_key comes from DOKPLOY_API_KEY, never from a file.
}

locals {
  nodes = yamldecode(file("${path.module}/nodes.yaml")).nodes

  # The manager is the Dokploy host itself: it has no dokploy_server record,
  # services on it simply have no server_id.
  remote_nodes = { for name, n in local.nodes : name => n if try(n.role, "remote") == "remote" }
}
