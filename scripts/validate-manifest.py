#!/usr/bin/env python3
"""Validate .deploy/manifest.yaml files against schema/manifest.v1.json.

Beyond the JSON Schema: every `uses:` entry must name a declared component,
every `domain:` must exist in each environment, a host belongs to one
environment only (each one owns its DNS records), a generated secret is not
also typed, and no secret takes the name of a platform credential of the infra
repo.

    scripts/validate-manifest.py path/to/.deploy/manifest.yaml [...]
"""
import json
import pathlib
import sys

import jsonschema
import yaml

# Platform credentials: the deploy runs in the infra repo, where these are repo
# secrets. A manifest listing one would hand it to the app.
RESERVED = {
    "DOKPLOY_API_KEY", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY",
    "R2_BACKUP_PROD_ACCESS_KEY_ID", "R2_BACKUP_PROD_SECRET_ACCESS_KEY",
    "R2_BACKUP_STAGING_ACCESS_KEY_ID", "R2_BACKUP_STAGING_SECRET_ACCESS_KEY",
    "CF_API_TOKEN", "CLOUDFLARE_API_TOKEN", "RESEND_ADMIN_API_KEY",
    "GHCR_TOKEN", "GHCR_ADMIN_TOKEN", "NODE_SSH_PRIVATE_KEY", "SSH_PRIVATE_KEY",
    "APP_REPOS_READ_TOKEN", "INFRA_DEPLOY_TOKEN", "GITHUB_TOKEN",
}

SCHEMA = json.loads((pathlib.Path(__file__).parent.parent / "schema/manifest.v1.json").read_text())


def semantic_errors(m):
    errs = []
    comps = {**m.get("apps", {}), **m.get("workers", {})}
    dbs, caches = m.get("databases", {}), m.get("caches", {})
    typed = set(m.get("secrets", [])) | set(m.get("optionalSecrets", []))
    generated = set(m.get("generate", []))   # a list, or the keys of a map
    secrets = typed | generated
    buckets = m.get("buckets", {})
    addons = set(buckets) | ({"mail"} if m.get("mail") is not None else set())
    known = set(comps) | set(dbs) | set(caches) | addons
    for a in sorted(addons & (set(comps) | set(dbs) | set(caches))):
        errs.append(f"'{a}' is both an add-on (buckets/mail) and a component, database or cache")
    for name, c in comps.items():
        for u in c.get("uses", []):
            if u not in known:
                errs.append(f"{name}.uses: unknown component '{u}'")
            elif u in comps and not comps[u].get("domain") and not comps[u].get("port"):
                errs.append(f"{name}.uses: '{u}' has neither a domain nor a port to reach it on")
        for d in [c["domain"]] if c.get("domain") else c.get("domains", []):
            for env, spec in m["environments"].items():
                if d not in spec.get("domains", {}):
                    errs.append(f"{name}.domain '{d}' missing in environments.{env}.domains")
        if c.get("paths") and not (c.get("domain") or c.get("domains")):
            errs.append(f"{name}.paths: needs a domain")
        for s in c.get("secrets", []):
            if s not in secrets:
                errs.append(f"{name}.secrets: '{s}' not declared in secrets or generate")
    # Names an add-on injects: a secret of the same name would override them.
    injected = set()
    for k, b in buckets.items():
        p = b.get("envPrefix", "S3")
        injected |= {f"{p}_{n}" for n in ("ENDPOINT", "BUCKET", "REGION", "ACCESS_KEY_ID", "SECRET_ACCESS_KEY", "FORCE_PATH_STYLE")}
    if m.get("mail") is not None:
        injected |= {"RESEND_API_KEY", "MAIL_DOMAIN", "SMTP_HOST", "SMTP_PORT", "SMTP_USER", "SMTP_PASSWORD"}
        if m.get("dns", "cloudflare") == "external" and not m["mail"].get("domain"):
            errs.append("mail.domain is required with dns: external")
    for s in sorted(secrets & injected):
        errs.append(f"secrets: '{s}' is injected by an add-on (buckets/mail) — remove it from the secrets")
    for s in sorted(typed & generated):
        errs.append(f"generate: '{s}' is also in secrets/optionalSecrets — infra generates it, nobody types it")
    for s in sorted(secrets & RESERVED):
        errs.append(f"secrets: '{s}' is a platform credential of the infra repo, use another name")
    for s in m.get("lockedSecrets", []):
        if s not in secrets:
            errs.append(f"lockedSecrets: '{s}' not declared in secrets or generate")
    for k, b in buckets.items():
        if b.get("name") and len(m["environments"]) > 1:
            errs.append(f"buckets.{k}.name: one fixed name for {len(m['environments'])} environments would share the bucket — "
                        "drop it (default <name>-<env>-<key>) or set it in environments.<env>.overrides")
    seen = {}
    for env, spec in m["environments"].items():
        for k, host in spec.get("domains", {}).items():
            if host in seen:
                errs.append(f"environments.{env}.domains.{k}: {host} already used by environments.{seen[host]}")
            seen.setdefault(host, f"{env}.domains.{k}")
    if m.get("mode", "services") == "services":
        for k, d in dbs.items():
            if d.get("service"):
                errs.append(f"databases.{k}.service is only for mode: compose")
            if d.get("type") in ("postgres", "mysql", "mariadb") and not d.get("database"):
                errs.append(f"databases.{k}.database is required")
    else:
        routes = m.get("compose", {}).get("routes", {})
        for r, spec in routes.items():
            d = spec.get("domain", r)
            for env, e in m["environments"].items():
                if d not in e.get("domains", {}):
                    errs.append(f"compose.routes.{r}: domain '{d}' missing in environments.{env}.domains")
        for k, d in dbs.items():
            if not d.get("database"):
                errs.append(f"databases.{k}.database is required (backups)")
        # Deleting a compose deletes its named volumes unless they are external.
        for env, e in m["environments"].items():
            if e.get("externalVolumes") is not True:
                errs.append(f"environments.{env}.externalVolumes must be true in mode: compose "
                            "(Dokploy deletes the named volumes of a deleted compose otherwise)")
    return errs


def main(paths):
    failed = False
    for p in paths:
        m = yaml.safe_load(pathlib.Path(p).read_text())
        errs = [f"{'.'.join(map(str, e.absolute_path)) or '<root>'}: {e.message}"
                for e in jsonschema.Draft202012Validator(SCHEMA).iter_errors(m)]
        if not errs:
            errs = semantic_errors(m)
        if errs:
            failed = True
            print(f"✗ {p}")
            for e in errs:
                print(f"    {e}")
        else:
            print(f"✓ {p}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
