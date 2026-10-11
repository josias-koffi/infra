# zones/ with mocked providers: which mail records are created, and which are
# left to the owner that already holds them.
mock_provider "restapi" {}
# One body for both calls: the list of domains (data) and the domain (records),
# in Resend's current layout (two CNAMEs on the return path).
mock_provider "http" {
  mock_data "http" {
    defaults = {
      status_code   = 200
      response_body = "{\"data\":[{\"id\":\"dom-1\",\"name\":\"mail.shop.example.com\",\"region\":\"eu-west-1\"}],\"records\":[{\"record\":\"DKIM\",\"name\":\"resend._domainkey\",\"type\":\"TXT\",\"value\":\"p=KEY\"},{\"record\":\"SPF\",\"name\":\"send\",\"type\":\"CNAME\",\"value\":\"send.forge.rmta.net\"},{\"record\":\"SPF\",\"name\":\"rsend\",\"type\":\"CNAME\",\"value\":\"rsend-euw1.forge.rmta.net\"}]}"
    }
  }
}
mock_provider "cloudflare" {
  alias = "empty"
  mock_data "cloudflare_zones" {
    defaults = {
      result = [
        { id = "zone-example", name = "example.com", account = null, activated_on = null, cname_suffix = null, created_on = null, development_mode = null, meta = null, modified_on = null, name_servers = null, original_dnshost = null, original_name_servers = null, original_registrar = null, owner = null, paused = null, permissions = null, plan = null, status = null, tenant = null, tenant_unit = null, type = null, vanity_name_servers = null, verification_key = null },
        { id = "zone-shop", name = "shop.example.com", account = null, activated_on = null, cname_suffix = null, created_on = null, development_mode = null, meta = null, modified_on = null, name_servers = null, original_dnshost = null, original_name_servers = null, original_registrar = null, owner = null, paused = null, permissions = null, plan = null, status = null, tenant = null, tenant_unit = null, type = null, vanity_name_servers = null, verification_key = null },
      ]
    }
  }
  mock_data "cloudflare_dns_records" {
    defaults = { result = [] }
  }
}
mock_provider "cloudflare" {
  alias = "taken"
  mock_data "cloudflare_zones" {
    defaults = {
      result = [
        { id = "zone-example", name = "example.com", account = null, activated_on = null, cname_suffix = null, created_on = null, development_mode = null, meta = null, modified_on = null, name_servers = null, original_dnshost = null, original_name_servers = null, original_registrar = null, owner = null, paused = null, permissions = null, plan = null, status = null, tenant = null, tenant_unit = null, type = null, vanity_name_servers = null, verification_key = null },
        { id = "zone-shop", name = "shop.example.com", account = null, activated_on = null, cname_suffix = null, created_on = null, development_mode = null, meta = null, modified_on = null, name_servers = null, original_dnshost = null, original_name_servers = null, original_registrar = null, owner = null, paused = null, permissions = null, plan = null, status = null, tenant = null, tenant_unit = null, type = null, vanity_name_servers = null, verification_key = null },
      ]
    }
  }
  mock_data "cloudflare_dns_records" {
    defaults = { result = [{ id = "rec-x", name = "x", type = "TXT", content = "v=DMARC1; p=reject;", comment = "koklo-infra", comment_modified_on = null, created_on = null, meta = null, modified_on = null, proxiable = null, proxied = null, settings = null, tags = null, tags_modified_on = null, ttl = null, data = null, priority = null, private_routing = null }] }
  }
}

variables {
  config_path          = "./tests/fixture.yaml"
  resend_api_key       = "re_test"
  adopt_resend_domains = false # mocked providers cannot import
}

run "records_created_in_the_zone" {
  command   = apply
  providers = { cloudflare = cloudflare.empty, restapi = restapi, http = http }

  assert {
    condition     = cloudflare_dns_record.mail["mail.shop.example.com/dkim/TXT/resend._domainkey"].zone_id == "zone-shop" && cloudflare_dns_record.mail["mail.shop.example.com/dkim/TXT/resend._domainkey"].name == "resend._domainkey.mail.shop.example.com" && cloudflare_dns_record.mail["mail.shop.example.com/dkim/TXT/resend._domainkey"].content == "p=KEY"
    error_message = "DKIM from Resend's answer, in the zone with the longest suffix"
  }
  assert {
    condition     = cloudflare_dns_record.mail["mail.shop.example.com/spf/CNAME/send"].name == "send.mail.shop.example.com" && cloudflare_dns_record.mail["mail.shop.example.com/spf/CNAME/rsend"].content == "rsend-euw1.forge.rmta.net" && length(cloudflare_dns_record.mail) == 4
    error_message = "every record Resend lists, whatever its type, and the DMARC"
  }
  assert {
    condition     = cloudflare_dns_record.mail["mail.shop.example.com/dmarc"].content == "v=DMARC1; p=none;"
    error_message = "default DMARC when the domain has none"
  }
  assert {
    condition     = output.mail_domains["mail.shop.example.com"].region == "eu-west-1"
    error_message = "apps/env reads the domain id; EU region by default"
  }
  assert {
    condition     = jsonencode(output.email_routing_zones) == jsonencode(["example.com", "shop.example.com"])
    error_message = "Email Routing on in every zone with no mail setup of its own"
  }
  assert {
    condition     = alltrue([for r in cloudflare_email_routing_dns.this : r.name == null])
    error_message = "Email Routing at the apex: no name (the API takes one only for a subdomain)"
  }
}

run "records_held_elsewhere_are_left_alone" {
  command   = apply
  providers = { cloudflare = cloudflare.taken, restapi = restapi, http = http }
  # The other owner's DKIM/SPF differ from Resend's answer: the check warns.
  expect_failures = [check.foreign_mail_records_match]

  assert {
    condition     = length(cloudflare_dns_record.mail) == 0
    error_message = "never a second DKIM, SPF or DMARC next to another owner's"
  }
  assert {
    condition     = length(output.foreign_mail_records) == 4
    error_message = "records left alone are listed"
  }
  assert {
    condition     = length(output.email_routing_zones) == 0 && length(output.email_routing_skipped) == 2
    error_message = "a zone whose apex already receives mail elsewhere keeps its setup"
  }
}
