#!/usr/bin/env python3
"""Refuse to deploy over DNS records owned elsewhere (manifests with dns: cloudflare).

Every domain of the environment must be in the zone CF_ZONE_ID, and any
A/AAAA/CNAME record already on its name must be ours: created by apps/env (its
comment) or declared in apps/adopt/<app>.yaml (environments.<env>.dnsRecords).
Otherwise the apply would add a second record next to the one another state
(koklo-infra, an app's own terraform…) manages.

    scripts/check-dns.py <manifest> <environment>

Environment: CLOUDFLARE_API_TOKEN, CF_ZONE_ID.
"""
import json
import os
import pathlib
import sys
import urllib.parse
import urllib.request

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
API = "https://api.cloudflare.com/client/v4"


def cf(path, token):
    req = urllib.request.Request(f"{API}{path}", headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            body = json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"Cloudflare API {path}: HTTP {e.code} — check CF_API_TOKEN (Zone → DNS → Edit) and CF_ZONE_ID")
    if not body.get("success"):
        sys.exit(f"Cloudflare API {path}: {body.get('errors')}")
    return body["result"]


def main(manifest_path, environment):
    m = yaml.safe_load(open(manifest_path))
    if m.get("dns", "cloudflare") != "cloudflare":
        return 0
    domains = m["environments"][environment].get("domains", {})
    if not domains:
        return 0

    token, zone_id = os.environ.get("CLOUDFLARE_API_TOKEN"), os.environ.get("CF_ZONE_ID")
    if not token or not zone_id:
        sys.exit("dns: cloudflare needs the repo secrets CF_API_TOKEN and CF_ZONE_ID "
                 "(or dns: external if the records live elsewhere)")

    app = m["name"]
    adopt_file = ROOT / "apps/adopt" / f"{app}.yaml"
    adopt = {}
    if adopt_file.exists():
        adopt = (yaml.safe_load(adopt_file.read_text()) or {}).get("environments", {}).get(environment, {})
    adopted = adopt.get("dnsRecords", {})
    ours = f"{app} {environment} — infra apps/env"  # comment of cloudflare_record.domains

    zone = cf(f"/zones/{zone_id}", token)["name"]
    errs = []
    for key, host in domains.items():
        if host != zone and not host.endswith(f".{zone}"):
            errs.append(f"{key}: {host} is not in the zone {zone} (CF_ZONE_ID)")
            continue
        q = urllib.parse.urlencode({"name": host, "per_page": 100})
        for r in cf(f"/zones/{zone_id}/dns_records?{q}", token):
            if r["type"] not in ("A", "AAAA", "CNAME"):
                continue
            if r.get("comment") == ours or adopted.get(key) == r["id"]:
                continue
            errs.append(f"{key}: {host} already has a {r['type']} record ({r['content']}, id {r['id']}, "
                        f"comment {r.get('comment')!r}) owned elsewhere")

    if errs:
        print("✗ DNS — records this deploy would duplicate:")
        for e in errs:
            print(f"    {e}")
        print("Remove the record from the state that owns it, then adopt it: "
              f"apps/adopt/{app}.yaml → environments.{environment}.dnsRecords.<key>: <id> "
              "(see docs/guides/deploy-an-app.md#dns)")
        return 1
    print(f"✓ DNS — {len(domains)} domain(s) of {app}/{environment} in {zone}, no foreign record")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
