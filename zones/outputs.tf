output "mail_domains" {
  description = "Sending domains, read by apps/env (add-on mail) to issue a key limited to one of them."
  value = {
    for d, m in local.mail : d => {
      id     = restapi_object.mail_domain[d].id
      region = m.region
    }
  }
}

output "foreign_mail_records" {
  description = "Mail records left to another owner (they already existed)."
  value       = sort([for k, es in local.foreign : local.wanted[k].name if length(es) > 0])
}
