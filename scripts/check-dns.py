#!/usr/bin/env python3
"""Refuse to deploy over DNS records owned elsewhere (manifests with dns: cloudflare).

Every domain of the environment must be in a zone of the Cloudflare account
(the zone with the longest matching suffix), and any A/AAAA/CNAME record
already on its name must be ours: created by apps/env (its comment) or declared
in apps/adopt/<app>.yaml (environments.<env>.dnsRecords).
Otherwise the apply would add a second record next to the one another state
(koklo-infra, an app's own terraform…) manages.

    scripts/check-dns.py <manifest> <environment> [<imports.json>]

With a third argument, writes the records that carry our comment as
{"<key>": "<zone_id>/<record_id>"}: apps/env imports the ones its state lacks.

Environment: CLOUDFLARE_API_TOKEN, CF_ACCOUNT_ID (optional: every zone the
token sees), CF_ZONE_ID (deprecated: fallback for a host no zone covers).
"""
import http.client
import json
import os
import pathlib
import sys
import time
import urllib.parse
import urllib.request

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
API = "https://api.cloudflare.com/client/v4"


def cf(path, token):
    req = urllib.request.Request(f"{API}{path}", headers={"Authorization": f"Bearer {token}"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                body = json.load(r)
            break
        except urllib.error.HTTPError as e:
            if e.code < 500 and e.code != 429:
                sys.exit(f"Cloudflare API {path}: HTTP {e.code} — check CF_API_TOKEN (Zone → Zone → Read and Zone → DNS → Edit, all zones)")
            err = f"HTTP {e.code}"
        except (urllib.error.URLError, http.client.HTTPException, OSError) as e:
            err = repr(e)
        time.sleep(2 ** attempt)
    else:
        sys.exit(f"Cloudflare API {path}: unreachable after 4 attempts ({err})")
    if not body.get("success"):
        sys.exit(f"Cloudflare API {path}: {body.get('errors')}")
    return body["result"]


def zones(token, account_id):
    """{name: id} of the active zones the token sees, in the account when given."""
    found, page = {}, 1
    while True:
        q = {"status": "active", "per_page": 50, "page": page}
        if account_id:
            q["account.id"] = account_id
        batch = cf(f"/zones?{urllib.parse.urlencode(q)}", token)
        found.update({z["name"]: z["id"] for z in batch})
        if len(batch) < 50:
            return found
        page += 1


def zone_of(host, names):
    """The zone with the longest suffix matching host, or None."""
    hits = [z for z in names if host == z or host.endswith(f".{z}")]
    return max(hits, key=len) if hits else None


def main(manifest_path, environment, imports_path=None):
    m = yaml.safe_load(open(manifest_path))
    owned = {}
    if imports_path:
        pathlib.Path(imports_path).write_text("{}")
    if m.get("dns", "cloudflare") != "cloudflare":
        return 0
    domains = m["environments"][environment].get("domains", {})
    if not domains:
        return 0

    token = os.environ.get("CLOUDFLARE_API_TOKEN")
    if not token:
        sys.exit("dns: cloudflare needs CF_API_TOKEN (or dns: external if the records live elsewhere)")
    known = zones(token, os.environ.get("CF_ACCOUNT_ID"))
    fallback = os.environ.get("CF_ZONE_ID")

    app = m["name"]
    adopt_file = ROOT / "apps/adopt" / f"{app}.yaml"
    adopt = {}
    if adopt_file.exists():
        adopt = (yaml.safe_load(adopt_file.read_text()) or {}).get("environments", {}).get(environment, {})
    adopted = adopt.get("dnsRecords", {})
    ours = f"{app} {environment} — infra apps/env"  # comment of cloudflare_dns_record.domains

    errs, foreign, used = [], False, set()
    for key, host in domains.items():
        zone = zone_of(host, known)
        zone_id = known.get(zone) or fallback
        if not zone_id:
            errs.append(f"{key}: {host} is in no zone of the Cloudflare account "
                        f"(zones seen: {', '.join(sorted(known)) or 'none'})")
            continue
        used.add(zone or "CF_ZONE_ID")
        q = urllib.parse.urlencode({"name": host, "per_page": 100})
        for r in cf(f"/zones/{zone_id}/dns_records?{q}", token):
            if r["type"] not in ("A", "AAAA", "CNAME"):
                continue
            if r.get("comment") == ours:
                owned[key] = f"{zone_id}/{r['id']}"
                continue
            if adopted.get(key) == r["id"]:
                continue
            foreign = True
            errs.append(f"{key}: {host} already has a {r['type']} record ({r['content']}, id {r['id']}, "
                        f"comment {r.get('comment')!r}) owned elsewhere")

    if errs:
        print("✗ DNS — this deploy would create records it must not:")
        for e in errs:
            print(f"    {e}")
        if foreign:
            print("Remove the record from the state that owns it, then adopt it: "
                  f"apps/adopt/{app}.yaml → environments.{environment}.dnsRecords.<key>: <id> "
                  "(see docs/guides/deploy-an-app.md#dns)")
        return 1
    if imports_path:
        pathlib.Path(imports_path).write_text(json.dumps(owned))
    print(f"✓ DNS — {len(domains)} domain(s) of {app}/{environment} in {', '.join(sorted(used))}, no foreign record")
    return 0


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
