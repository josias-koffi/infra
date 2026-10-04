terraform {
  required_version = ">= 1.11.0"

  required_providers {
    dokploy = {
      source  = "vanillauys/dokploy"
      version = "~> 1.9"
    }
  }
}
