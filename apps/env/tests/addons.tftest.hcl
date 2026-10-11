# apps/env with mocked providers and remote states: what the add-ons and the
# DNS lookup produce, without a Cloudflare account.
mock_provider "dokploy" {}
mock_provider "random" {}
mock_provider "restapi" {
  mock_resource "restapi_object" {
    defaults = { id = "key-1", create_response = "{\"id\":\"key-1\",\"token\":\"re_sending\"}" }
  }
}
mock_provider "cloudflare" {
  mock_data "cloudflare_zones" {
    defaults = {
      result = [
        # The schema wants every attribute; only id and name matter here.
        { id = "zone-example", name = "example.com", account = null, activated_on = null, cname_suffix = null, created_on = null, development_mode = null, meta = null, modified_on = null, name_servers = null, original_dnshost = null, original_name_servers = null, original_registrar = null, owner = null, paused = null, permissions = null, plan = null, status = null, tenant = null, tenant_unit = null, type = null, vanity_name_servers = null, verification_key = null },
        { id = "zone-shop", name = "shop.example.com", account = null, activated_on = null, cname_suffix = null, created_on = null, development_mode = null, meta = null, modified_on = null, name_servers = null, original_dnshost = null, original_name_servers = null, original_registrar = null, owner = null, paused = null, permissions = null, plan = null, status = null, tenant = null, tenant_unit = null, type = null, vanity_name_servers = null, verification_key = null },
      ]
    }
  }
  mock_data "cloudflare_account_api_token_permission_groups_list" {
    defaults = {
      result = [{ id = "pg-r2-write", name = "Workers R2 Storage Bucket Item Write", scopes = ["com.cloudflare.edge.r2.bucket"], category = null, is_selectable = null }]
    }
  }
  mock_resource "cloudflare_account_token" {
    defaults = { id = "tok-id", value = "tok-value" }
  }
}

override_data {
  target = data.terraform_remote_state.platform
  values = {
    outputs = {
      nodes                  = { vps20 = { ip = "203.0.113.10", server_id = null } }
      backup_destination_ids = { production = "dest-prod", staging = "dest-staging" }
      registry_ids           = {}
    }
  }
}

override_data {
  target = data.terraform_remote_state.zones
  values = { outputs = {
    mail_domains        = { "example.com" = { id = "dom-1", region = "eu-west-1" } }
    email_routing_zones = ["example.com", "shop.example.com"]
  } }
}

override_data {
  target = data.terraform_remote_state.project
  values = { outputs = { environment_ids = { staging = "env-staging" } } }
}

variables {
  dokploy_endpoint = "https://dokploy.example.com"
  state_bucket     = "state"
  manifest_path    = "./tests/fixtures/addons/.deploy/manifest.yaml"
  environment      = "staging"
  image_tag        = "abc1234"
  cf_account_id    = "acc"
}

run "eu_bucket_and_scoped_token" {
  command = apply

  assert {
    condition     = cloudflare_r2_bucket.this["medias"].name == "shop-staging-medias" && cloudflare_r2_bucket.this["medias"].jurisdiction == "eu"
    error_message = "default bucket: <name>-<env>-<key>, EU jurisdiction"
  }
  assert {
    condition     = nonsensitive(local.addons.medias.S3_ENDPOINT) == "https://acc.eu.r2.cloudflarestorage.com"
    error_message = "an EU bucket is reached through the eu endpoint"
  }
  assert {
    condition     = nonsensitive(local.addons.medias.S3_ACCESS_KEY_ID) == "tok-id" && nonsensitive(local.addons.medias.S3_SECRET_ACCESS_KEY) == sha256("tok-value")
    error_message = "R2 S3 credentials: token id, SHA-256 of the token value"
  }
  assert {
    condition     = keys(jsondecode(cloudflare_account_token.bucket["medias"].policies[0].resources))[0] == "com.cloudflare.edge.r2.bucket.acc_eu_shop-staging-medias"
    error_message = "the token reaches only its bucket, in its jurisdiction"
  }
  assert {
    condition     = nonsensitive(local.addons.files.FILES_ENDPOINT) == "https://acc.r2.cloudflarestorage.com" && nonsensitive(local.addons.files.FILES_BUCKET) == "shop-staging-files"
    error_message = "jurisdiction default and envPrefix"
  }
}

run "dns_zone_by_longest_suffix" {
  command = apply

  assert {
    condition     = cloudflare_dns_record.domains["site"].zone_id == "zone-shop" && cloudflare_dns_record.domains["blog"].zone_id == "zone-example"
    error_message = "each host goes to the zone with the longest matching suffix"
  }
}

run "mail_key_limited_to_the_domain" {
  command = apply

  assert {
    condition     = jsondecode(restapi_object.mail_key[0].data).domain_id == "dom-1" && jsondecode(restapi_object.mail_key[0].data).permission == "sending_access"
    error_message = "a sending-only key, limited to the zone of the env's first domain"
  }
  assert {
    condition     = nonsensitive(local.addons.mail.RESEND_API_KEY) == "re_sending" && nonsensitive(local.addons.mail.SMTP_PASSWORD) == "re_sending" && nonsensitive(local.addons.mail.MAIL_DOMAIN) == "example.com"
    error_message = "the token comes from the creation answer, for the API and for SMTP"
  }
}

run "forwarding_rules_in_the_right_zone" {
  command = apply

  assert {
    condition     = cloudflare_email_routing_rule.forward["contact@shop.example.com"].zone_id == "zone-shop" && cloudflare_email_routing_rule.forward["orders@example.com"].zone_id == "zone-example"
    error_message = "each address goes to the zone with the longest matching suffix (lowercased)"
  }
  assert {
    condition     = jsonencode(cloudflare_email_routing_rule.forward["orders@example.com"].actions[0].value) == jsonencode(["shop@gmail.com"]) && cloudflare_email_routing_rule.forward["contact@shop.example.com"].matchers[0].value == "contact@shop.example.com"
    error_message = "one rule per address, forwarding to its one mailbox (lowercased)"
  }
}

run "no_rule_towards_an_unconfirmed_mailbox" {
  command = plan

  variables {
    email_verified = ["me@gmail.com"]
  }

  assert {
    condition     = keys(cloudflare_email_routing_rule.forward) == ["contact@shop.example.com"]
    error_message = "Cloudflare refuses a rule towards an unconfirmed mailbox: it waits for the next deploy"
  }
}

run "forwarding_refused_where_routing_is_off" {
  command = plan

  override_data {
    target = data.terraform_remote_state.zones
    values = { outputs = {
      mail_domains        = { "example.com" = { id = "dom-1", region = "eu-west-1" } }
      email_routing_zones = ["example.com"]
    } }
  }
  expect_failures = [cloudflare_email_routing_rule.forward]
}
