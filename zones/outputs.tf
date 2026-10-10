output "mail_domains" {
  description = "Sending domains, read by apps/env (add-on mail) to issue a key limited to one of them."
  value = {
    for d, m in local.mail : d => {
      id     = restapi_object.mail_domain[d].id
      region = m.region
    }
  }
}

output "email_routing_zones" {
  description = "Zones where a manifest can forward an address (apps/env checks it)."
  value       = sort(keys(local.routing_zones))
}

output "email_routing_skipped" {
  description = "Zones whose apex already receives mail elsewhere: Email Routing left off."
  value       = { for z, why in local.routing_blocked : z => why if length(why) > 0 }
}

output "foreign_mail_records" {
  description = "Mail records left to another owner (they already existed)."
  value       = sort([for k, es in local.foreign : local.wanted[k].name if length(es) > 0])
}
