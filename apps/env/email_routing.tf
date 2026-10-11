# ==============================================================================
# Email Routing — environments.<env>.emailRouting forwards an address of one of
# the account's zones to ONE mailbox (a Cloudflare rule has a single destination):
#
#   emailRouting:
#     contact@ouiti.com: me@gmail.com
#     orders@ouiti.com: shop@gmail.com
#
# zones/ turns Email Routing on in the zone; scripts/ensure-email-destinations.py
# registers the mailboxes (Cloudflare mails each one a confirmation link, once).
# Cloudflare refuses a rule towards an unconfirmed mailbox: its rule waits for
# the first deploy after the link is clicked. Removing a line removes its rule.
# ==============================================================================

locals {
  routes = {
    for src, dst in try(local.env_spec.emailRouting, {}) : lower(src) => lower(dst)
  }
  # null (tests, local plans): every rule, as if every mailbox were confirmed.
  confirmed_routes = {
    for src, dst in local.routes : src => dst
    if var.email_verified == null || contains(coalesce(var.email_verified, []), dst)
  }
  route_zone = {
    for src, _ in local.routes : src => try(split(" ", reverse(sort([
      for z in keys(local.zones) : format("%04d %s", length(z), z) if split("@", src)[1] == z || endswith(split("@", src)[1], ".${z}")
    ]))[0])[1], null)
  }
  routing_zones = try(data.terraform_remote_state.zones[0].outputs.email_routing_zones, [])
}

resource "cloudflare_email_routing_rule" "forward" {
  for_each = local.confirmed_routes

  zone_id = try(local.zones[local.route_zone[each.key]], "")
  name    = "${local.app} ${var.environment} — ${each.key} (infra apps/env)"
  enabled = true
  matchers = [{
    type  = "literal"
    field = "to"
    value = each.key
  }]
  actions = [{
    type  = "forward"
    value = [each.value]
  }]

  lifecycle {
    precondition {
      condition     = local.route_zone[each.key] != null
      error_message = "emailRouting: ${each.key} is in no zone of the Cloudflare account."
    }
    precondition {
      condition     = contains(local.routing_zones, coalesce(local.route_zone[each.key], "-"))
      error_message = "emailRouting: Email Routing is off in ${coalesce(local.route_zone[each.key], "its zone")} — apply zones/, and check its output email_routing_skipped (an MX or SPF of another mail service)."
    }
  }
}
