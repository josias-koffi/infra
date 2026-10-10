# zones/ with mocked providers: which mail records are created, and which are
# left to the owner that already holds them.
mock_provider "restapi" {
  mock_resource "restapi_object" {
    defaults = {
      id           = "dom-1"
      api_response = "{\"records\":[{\"record\":\"DKIM\",\"name\":\"resend._domainkey\",\"type\":\"TXT\",\"value\":\"p=KEY\"},{\"record\":\"SPF\",\"name\":\"send\",\"type\":\"MX\",\"value\":\"feedback-smtp.eu-west-1.amazonses.com\",\"priority\":10},{\"record\":\"SPF\",\"name\":\"send\",\"type\":\"TXT\",\"value\":\"v=spf1 include:amazonses.com ~all\"}]}"
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
  config_path = "./tests/fixture.yaml"
}

run "records_created_in_the_zone" {
  command   = apply
  providers = { cloudflare = cloudflare.empty, restapi = restapi }

  assert {
    condition     = cloudflare_dns_record.mail["mail.shop.example.com/dkim"].zone_id == "zone-shop" && cloudflare_dns_record.mail["mail.shop.example.com/dkim"].name == "resend._domainkey.mail.shop.example.com" && cloudflare_dns_record.mail["mail.shop.example.com/dkim"].content == "p=KEY"
    error_message = "DKIM from Resend's answer, in the zone with the longest suffix"
  }
  assert {
    condition     = cloudflare_dns_record.mail["mail.shop.example.com/spf-mx"].priority == 10 && cloudflare_dns_record.mail["mail.shop.example.com/spf-mx"].name == "send.mail.shop.example.com"
    error_message = "bounce MX on the return path"
  }
  assert {
    condition     = cloudflare_dns_record.mail["mail.shop.example.com/dmarc"].content == "v=DMARC1; p=none;"
    error_message = "default DMARC when the domain has none"
  }
  assert {
    condition     = output.mail_domains["mail.shop.example.com"].id == "dom-1" && output.mail_domains["mail.shop.example.com"].region == "eu-west-1"
    error_message = "apps/env reads the domain id; EU region by default"
  }
  assert {
    condition     = jsonencode(output.email_routing_zones) == jsonencode(["example.com", "shop.example.com"])
    error_message = "Email Routing on in every zone with no mail setup of its own"
  }
}

run "records_held_elsewhere_are_left_alone" {
  command   = apply
  providers = { cloudflare = cloudflare.taken, restapi = restapi }
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
