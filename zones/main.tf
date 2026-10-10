# ==============================================================================
# zones/ — what belongs to a domain, not to an app.
#
# Sending domains (Resend): created once per domain and shared by every app and
# environment that sends from it. Each app/env then gets its own sending key,
# limited to that domain (apps/env, add-on `mail`). Driven by zones.yaml.
#
#   make zones-plan / make zones-apply   (CI: .github/workflows/zones.yml)
# ==============================================================================

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.26"
    }
    restapi = {
      source  = "Mastercard/restapi"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    # bucket: -backend-config="bucket=$TF_STATE_BUCKET" (see Makefile)
    key    = "zones/zones.tfstate"
    region = "auto"

    use_path_style              = true
    use_lockfile                = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

provider "cloudflare" {
  # CLOUDFLARE_API_TOKEN from the environment.
}

provider "restapi" {
  uri                   = "https://api.resend.com"
  headers               = { Authorization = "Bearer ${var.resend_api_key}", "Content-Type" = "application/json" }
  create_returns_object = true
  rate_limit            = 2 # Resend's default limit
}

locals {
  config = yamldecode(file(var.config_path))

  zones = { for z in data.cloudflare_zones.all.result : z.name => z.id }
  # The zone with the longest suffix matching the name, as in apps/env.
  zone_of = {
    for d in keys(try(local.config.mail, {})) : d => try(split(" ", reverse(sort([
      for z in keys(local.zones) : format("%04d %s", length(z), z) if d == z || endswith(d, ".${z}")
    ]))[0])[1], null)
  }

  mail = {
    for d, m in try(local.config.mail, {}) : d => {
      region      = try(m.region, "eu-west-1")
      return_path = try(m.returnPath, "send")
      dmarc       = try(m.dmarc, "v=DMARC1; p=none;")
      resend_id   = try(m.resendId, null)
      zone_id     = try(local.zones[local.zone_of[d]], null)
    }
  }
  ours = "zones — infra"

  # What Resend asks for, from its answer about the domain. The names are fixed
  # (resend._domainkey, <returnPath>), so what exists already is known at plan.
  resend_records = { for d, _ in local.mail : d => try(jsondecode(restapi_object.mail_domain[d].api_response).records, []) }
  wanted = merge([
    for d, m in local.mail : {
      "${d}/dkim" = {
        domain  = d, zone_id = m.zone_id, name = "resend._domainkey.${d}", type = "TXT", priority = null
        content = try([for r in local.resend_records[d] : r.value if r.record == "DKIM"][0], "")
      }
      "${d}/spf-mx" = {
        domain  = d, zone_id = m.zone_id, name = "${m.return_path}.${d}", type = "MX", priority = 10
        content = try([for r in local.resend_records[d] : r.value if r.record == "SPF" && r.type == "MX"][0], "")
      }
      "${d}/spf-txt" = {
        domain  = d, zone_id = m.zone_id, name = "${m.return_path}.${d}", type = "TXT", priority = null
        content = try([for r in local.resend_records[d] : r.value if r.record == "SPF" && r.type == "TXT"][0], "")
      }
      "${d}/dmarc" = {
        domain = d, zone_id = m.zone_id, name = "_dmarc.${d}", type = "TXT", priority = null, content = m.dmarc
      }
    }
  ]...)

  # A record another owner already holds on that name (koklo-infra, an app's
  # own terraform, the console) is left alone: never a second DKIM or DMARC.
  # A DMARC counts only if it starts with v=DMARC1; the others must match.
  foreign = {
    for k, r in local.wanted : k => [
      for e in data.cloudflare_dns_records.existing[k].result : e
      if e.comment != local.ours && (!endswith(k, "/dmarc") || startswith(e.content, "v=DMARC1"))
    ]
  }
  managed = { for k, r in local.wanted : k => r if length(local.foreign[k]) == 0 }
}

data "cloudflare_zones" "all" {
  account = var.cf_account_id != "" ? { id = var.cf_account_id } : null
  status  = "active"
}

resource "restapi_object" "mail_domain" {
  for_each = local.mail

  path = "/domains"
  data = jsonencode({ name = each.key, region = each.value.region, custom_return_path = each.value.return_path })
  # Resend answers with many more fields (status, records…): only existence
  # matters; name, region and return path cannot change in place.
  ignore_all_server_changes = true
  force_new                 = ["name", "region", "custom_return_path"]

  lifecycle {
    precondition {
      condition     = each.value.zone_id != null
      error_message = "${each.key} is in no zone of the Cloudflare account: add it to Cloudflare first."
    }
  }
}

data "cloudflare_dns_records" "existing" {
  for_each = local.wanted

  zone_id = each.value.zone_id
  name    = { exact = each.value.name }
  type    = each.value.type
}

resource "cloudflare_dns_record" "mail" {
  for_each = local.managed

  zone_id  = each.value.zone_id
  name     = each.value.name
  type     = each.value.type
  content  = each.value.content
  priority = each.value.priority
  ttl      = 1
  comment  = local.ours
}

check "foreign_mail_records_match" {
  assert {
    condition = alltrue([
      for k, es in local.foreign : alltrue([for e in es : e.content == local.wanted[k].content])
      if !endswith(k, "/dmarc") && local.wanted[k].content != ""
    ])
    error_message = "A Resend record held by another owner differs from what Resend asks for: ${join(", ", [for k, es in local.foreign : local.wanted[k].name if length(es) > 0 && !endswith(k, "/dmarc")])}. Fix it where it is managed, or remove it so that zones/ creates it."
  }
}

# Resend checks the records on request; it retries by itself afterwards.
resource "terraform_data" "verify" {
  for_each = local.mail

  triggers_replace = [for k, r in local.managed : r.content if r.domain == each.key]

  provisioner "local-exec" {
    command = "[ -n \"$RESEND_API_KEY\" ] || exit 0; curl -fsS -X POST -H \"Authorization: Bearer $RESEND_API_KEY\" https://api.resend.com/domains/${restapi_object.mail_domain[each.key].id}/verify >/dev/null || echo 'verify request failed for ${each.key} (Resend retries on its own)'"
    environment = {
      RESEND_API_KEY = var.resend_api_key
    }
  }

  depends_on = [cloudflare_dns_record.mail]
}

# A sending domain created by hand: zones.yaml → mail.<domain>.resendId.
import {
  for_each = { for d, m in local.mail : d => m.resend_id if m.resend_id != null }
  to       = restapi_object.mail_domain[each.key]
  id       = "/domains/${each.value}"
}
