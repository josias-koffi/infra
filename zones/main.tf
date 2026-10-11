# ==============================================================================
# zones/ — what belongs to a domain, not to an app.
#
# Sending domains (Resend): created once per domain and shared by every app and
# environment that sends from it. Each app/env then gets its own sending key,
# limited to that domain (apps/env, add-on `mail`). Driven by zones.yaml.
#
# Email Routing (Cloudflare): turned on in every zone of the account that has
# no mail setup of its own at its apex, so that a manifest can forward an
# address (environments.<env>.emailRouting, rules made by apps/env).
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
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
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
      resend_id   = try(m.resendId, local.resend_existing[d].id, null)
      zone_id     = try(local.zones[local.zone_of[d]], null)
    }
  }
  ours = "zones — infra"

  # Domains already in the Resend account (made by hand, or by an earlier run):
  # adopted as they are, never created a second time.
  resend_existing = nonsensitive(var.resend_api_key == "") ? {} : {
    for r in try(jsondecode(data.http.resend_domains[0].response_body).data, []) : r.name => r
  }
  resend_ids = { for d, m in local.mail : d => m.resend_id if m.resend_id != null }

  # What Resend asks for, exactly as it lists it (its layout changes: MX + TXT
  # on the return path before, two CNAMEs now). Read from the domain as it
  # exists, so the records are known at plan; a domain created by this run
  # gets them on the next apply (zones.yml applies twice).
  resend_records = { for d, _ in local.resend_ids : d => try(jsondecode(data.http.resend_domain[d].response_body).records, []) }
  wanted = merge(
    merge([
      for d, rs in local.resend_records : {
        for r in rs : "${d}/${lower(r.record)}/${r.type}/${r.name}" => {
          domain   = d
          zone_id  = local.mail[d].zone_id
          name     = contains(["", "@"], r.name) ? d : endswith(r.name, d) ? r.name : "${r.name}.${d}"
          type     = r.type
          content  = r.value
          priority = r.type == "MX" ? try(tonumber(r.priority), 10) : null
        }
      }
    ]...),
    {
      for d, m in local.mail : "${d}/dmarc" => {
        domain = d, zone_id = m.zone_id, name = "_dmarc.${d}", type = "TXT", priority = null, content = m.dmarc
      }
    },
  )

  # A record another owner already holds on that name (koklo-infra, an app's
  # own terraform, the console) is left alone: never a second DKIM or DMARC.
  # A DMARC counts only if it starts with v=DMARC1; the others must match
  # (Cloudflare returns a TXT content quoted).
  foreign = {
    for k, r in local.wanted : k => [
      for e in data.cloudflare_dns_records.existing[k].result : e
      if e.comment != local.ours && (!endswith(k, "/dmarc") || startswith(e.content, "v=DMARC1"))
    ]
  }
  managed = { for k, r in local.wanted : k => r if length(local.foreign[k]) == 0 }

  # Email Routing: a zone whose apex already receives mail elsewhere (an MX that
  # is not Cloudflare's, or an SPF without it) is left alone and listed.
  routing_excluded   = try(local.config.emailRouting.exclude, [])
  routing_candidates = { for z, id in local.zones : z => id if !contains(local.routing_excluded, z) }
  routing_blocked = {
    for z, _ in local.routing_candidates : z => concat(
      [for r in data.cloudflare_dns_records.apex_mx[z].result : "MX ${r.content}" if !endswith(r.content, ".mx.cloudflare.net")],
      [for r in data.cloudflare_dns_records.apex_spf[z].result : "SPF" if startswith(r.content, "v=spf1") && !strcontains(r.content, "_spf.mx.cloudflare.net")],
    )
  }
  routing_zones = { for z, id in local.routing_candidates : z => id if length(local.routing_blocked[z]) == 0 }
}

data "cloudflare_zones" "all" {
  account = var.cf_account_id != "" ? { id = var.cf_account_id } : null
  status  = "active"
}

data "http" "resend_domains" {
  count = nonsensitive(var.resend_api_key == "") ? 0 : 1

  url             = "https://api.resend.com/domains"
  request_headers = { Authorization = "Bearer ${var.resend_api_key}" }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Resend refused to list the domains (HTTP ${self.status_code}): RESEND_ADMIN_API_KEY must have full access."
    }
  }
}

data "http" "resend_domain" {
  for_each = local.resend_ids

  url             = "https://api.resend.com/domains/${each.value}"
  request_headers = { Authorization = "Bearer ${var.resend_api_key}" }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Resend has no domain ${each.value} (${each.key}): fix resendId in zones.yaml (HTTP ${self.status_code})."
    }
  }
}

resource "restapi_object" "mail_domain" {
  for_each = local.mail

  path = "/domains"
  data = jsonencode({ name = each.key, region = each.value.region, custom_return_path = each.value.return_path })
  # Resend answers with many more fields (status, records…): only existence
  # matters. A domain is never updated, nor replaced: region and return path
  # cannot change in place, and replacing it would drop its verification (and
  # an adopted domain carries none of these arguments in its state).
  ignore_all_server_changes = true

  lifecycle {
    ignore_changes = all
    precondition {
      condition     = each.value.zone_id != null
      error_message = "${each.key} is in no zone of the Cloudflare account: add it to Cloudflare first."
    }
  }
}

check "mail_domain_region" {
  assert {
    condition = alltrue([
      for d, m in local.mail : try(jsondecode(restapi_object.mail_domain[d].api_response).region, m.region) == m.region
    ])
    error_message = "A sending domain is not in the region of zones.yaml: ${join(", ", [for d, m in local.mail : "${d} (${try(jsondecode(restapi_object.mail_domain[d].api_response).region, "?")})" if try(jsondecode(restapi_object.mail_domain[d].api_response).region, m.region) != m.region])}. Resend cannot move a domain: delete it in Resend to have it recreated, or write its region in zones.yaml."
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
      for k, es in local.foreign : alltrue([for e in es : trim(e.content, "\"") == local.wanted[k].content])
      if !endswith(k, "/dmarc")
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

data "cloudflare_dns_records" "apex_mx" {
  for_each = local.routing_candidates

  zone_id = each.value
  name    = { exact = each.key }
  type    = "MX"
}

data "cloudflare_dns_records" "apex_spf" {
  for_each = local.routing_candidates

  zone_id = each.value
  name    = { exact = each.key }
  type    = "TXT"
}

# Turns Email Routing on and writes its MX and SPF records at the apex. No
# name: the API takes one only for a subdomain of the zone.
resource "cloudflare_email_routing_dns" "this" {
  for_each = local.routing_zones

  zone_id = each.value
}

# A sending domain already in Resend: found by its name, or zones.yaml →
# mail.<domain>.resendId. Importing one that is already in the state is a no-op.
import {
  for_each = var.adopt_resend_domains ? local.resend_ids : {}
  to       = restapi_object.mail_domain[each.key]
  id       = "/domains/${each.value}"
}
