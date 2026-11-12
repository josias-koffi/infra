#!/usr/bin/env python3
"""Google Search Console for the domains listed under `searchConsole:` in
zones/zones.yaml: a Domain property (sc-domain:<domain>) per domain, which
covers every subdomain, verified by a DNS TXT record at the domain.

Opt-in, one line per domain: a domain that is not listed is never touched (a
property made by hand, civinat.fr…, stays as it is). Listing a domain already
verified by hand adds the service account as one more owner, nothing else.

Two steps around the zones/ apply, each safe to run again:

    scripts/ensure-search-console.py tokens <zones.yaml> <out.json | ->
        The TXT value Google wants for each listed domain, as a JSON object
        { domain: "google-site-verification=…" } (zones/, var.search_console_tokens).
        A token is stable: asking again gives the same one. Changes nothing.

    scripts/ensure-search-console.py verify <zones.yaml> [--dry-run]
        Once the records are written: verifies each domain not verified yet,
        adds the owners missing from it (never removes one), and adds the
        property to Search Console.

Environment:
  GOOGLE_SERVICE_ACCOUNT_JSON  the platform's service account (needed only
                               when a domain is listed)
  SEARCH_CONSOLE_OWNERS        Google accounts made owners of every property,
                               comma-separated, so that it shows in their
                               Search Console (repo variable: kept out of this
                               public repository)
"""
import json
import os
import pathlib
import sys
import time
import urllib.parse

import yaml

from google_api import Api, session_from_env

SV = "https://www.googleapis.com/siteVerification/v1"
WEBMASTERS = "https://www.googleapis.com/webmasters/v3"
SCOPES = [
    "https://www.googleapis.com/auth/siteverification",
    "https://www.googleapis.com/auth/webmasters",
]
LABEL = "search-console"


def domains(config_path):
    config = yaml.safe_load(open(config_path)) or {}
    return sorted((config.get("searchConsole") or {}).keys())


def site(domain):
    return {"type": "INET_DOMAIN", "identifier": domain}


def resource_url(domain):
    return f"{SV}/webResource/{urllib.parse.quote(f'dns://{domain}', safe='')}"


def owners_from_env():
    return sorted({o.strip().lower() for o in os.environ.get("SEARCH_CONSOLE_OWNERS", "").split(",") if o.strip()})


def tokens(api, listed):
    return {
        d: api.call("POST", f"{SV}/token", {"site": site(d), "verificationMethod": "DNS_TXT"})["token"]
        for d in listed
    }


def verify_domain(api, domain, wait_seconds):
    """Asks Google to check the TXT record, again while DNS catches up."""
    deadline = time.time() + wait_seconds
    while True:
        r = api.s.request("POST", f"{SV}/webResource", params={"verificationMethod": "DNS_TXT"},
                          json={"site": site(domain)}, timeout=60)
        if r.status_code < 400:
            return r.json()
        if r.status_code != 400 or time.time() > deadline:
            sys.exit(f"{LABEL}: {domain} not verified ({r.status_code}): {r.text}\n"
                     "Is the TXT record of zones/ in place? Run the Zones workflow again in a few minutes.")
        time.sleep(30)


def ensure(api, domain, owners, dry_run, wait_seconds=600):
    resource = api.call("GET", resource_url(domain))
    if resource is None:
        print(f"{LABEL}: {domain} {'would be verified' if dry_run else 'verifying'} (DNS TXT)")
        if dry_run:
            return
        resource = verify_domain(api, domain, wait_seconds)
    current = {o.lower() for o in resource.get("owners", [])}
    missing = [o for o in owners if o not in current]
    if missing:
        print(f"{LABEL}: {domain} {'would get' if dry_run else 'gets'} {len(missing)} more owner(s)")
        if not dry_run:
            api.call("PUT", resource_url(domain), {"site": site(domain), "owners": resource.get("owners", []) + missing})
    if not dry_run:
        # Adding a property the account already has changes nothing.
        api.call("PUT", f"{WEBMASTERS}/sites/{urllib.parse.quote(f'sc-domain:{domain}', safe='')}")
    print(f"{LABEL}: {domain} verified" + ("" if dry_run else ", in Search Console"))


def main(argv):
    dry_run = "--dry-run" in argv
    args = [a for a in argv if a != "--dry-run"]
    if not args or args[0] not in ("tokens", "verify") or len(args) != (3 if args[0] == "tokens" else 2):
        sys.exit(__doc__)
    listed = domains(args[1])
    if args[0] == "tokens":
        found = tokens(Api(session_from_env(SCOPES, LABEL), LABEL), listed) if listed else {}
        if args[2] == "-":  # for `export TF_VAR_search_console_tokens=$(…)`
            print(json.dumps(found))
        else:
            pathlib.Path(args[2]).write_text(json.dumps(found))
        return 0
    if listed:
        api, owners = Api(session_from_env(SCOPES, LABEL), LABEL), owners_from_env()
        for d in listed:
            ensure(api, d, owners, dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
