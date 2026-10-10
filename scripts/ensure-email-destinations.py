#!/usr/bin/env python3
"""Registers the mailboxes an environment forwards to (emailRouting) as
Cloudflare Email Routing destination addresses. They belong to the account and
are shared by every app, so they are created here, never deleted.

Cloudflare mails each new address a confirmation link: until it is clicked,
mail is not forwarded there. The deploy goes on; this prints a warning.

    scripts/ensure-email-destinations.py <manifest> <environment> [--dry-run]

--dry-run (plan-only deploys) lists what would be registered, creates nothing.

Environment: CLOUDFLARE_API_TOKEN, CF_ACCOUNT_ID.
"""
import json
import os
import pathlib
import sys
import urllib.request

import yaml

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from importlib import import_module

cf = import_module("check-dns").cf  # same retries and error messages
API = "https://api.cloudflare.com/client/v4"


def main(manifest_path, environment, dry_run=False):
    m = yaml.safe_load(open(manifest_path))
    routes = m["environments"][environment].get("emailRouting", {})
    wanted = sorted({d.lower() for v in routes.values() for d in ([v] if isinstance(v, str) else v)})
    if not wanted:
        return 0
    token, account = os.environ.get("CLOUDFLARE_API_TOKEN"), os.environ.get("CF_ACCOUNT_ID")
    if not token or not account:
        sys.exit("emailRouting needs CF_API_TOKEN and CF_ACCOUNT_ID")

    known, page = {}, 1
    while True:
        batch = cf(f"/accounts/{account}/email/routing/addresses?per_page=50&page={page}", token)
        known.update({a["email"].lower(): a for a in batch})
        if len(batch) < 50:
            break
        page += 1

    for email in wanted:
        if email not in known and dry_run:
            print(f"· Email Routing: {email} would be registered (a confirmation link is mailed to it)")
            continue
        if email not in known:
            req = urllib.request.Request(
                f"{API}/accounts/{account}/email/routing/addresses", method="POST",
                data=json.dumps({"email": email}).encode(),
                headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=20) as r:
                known[email] = json.load(r)["result"]
            print(f"✓ Email Routing: {email} registered — Cloudflare sent it a confirmation link")
        if not known[email].get("verified"):
            print(f"::warning::Email Routing: {email} is not confirmed yet, nothing is forwarded to it "
                  "until the link Cloudflare mailed it is clicked")
    return 0


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--dry-run"]
    if len(args) != 2:
        sys.exit(__doc__)
    sys.exit(main(*args, dry_run="--dry-run" in sys.argv))
