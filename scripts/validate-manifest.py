#!/usr/bin/env python3
"""Validate .deploy/manifest.yaml files against schema/manifest.v1.json.

Beyond the JSON Schema: every `uses:` entry must name a declared component,
every `domain:` must exist in each environment, and a database or cache needs
its password secret listed in `secrets`.

    scripts/validate-manifest.py path/to/.deploy/manifest.yaml [...]
"""
import json
import pathlib
import sys

import jsonschema
import yaml

SCHEMA = json.loads((pathlib.Path(__file__).parent.parent / "schema/manifest.v1.json").read_text())


def semantic_errors(m):
    errs = []
    comps = {**m.get("apps", {}), **m.get("workers", {})}
    dbs, caches = m.get("databases", {}), m.get("caches", {})
    secrets = set(m.get("secrets", [])) | set(m.get("optionalSecrets", []))
    known = set(comps) | set(dbs) | set(caches)
    for name, c in comps.items():
        for u in c.get("uses", []):
            if u not in known:
                errs.append(f"{name}.uses: unknown component '{u}'")
            elif u in comps and not comps[u].get("domain"):
                errs.append(f"{name}.uses: '{u}' has no domain (app-to-app goes through its public domain)")
        for d in [c["domain"]] if c.get("domain") else c.get("domains", []):
            for env, spec in m["environments"].items():
                if d not in spec.get("domains", {}):
                    errs.append(f"{name}.domain '{d}' missing in environments.{env}.domains")
        for s in c.get("secrets", []):
            if s not in secrets:
                errs.append(f"{name}.secrets: '{s}' not declared in secrets")
    if m.get("mode", "services") == "services":
        for k, d in dbs.items():
            if d.get("service"):
                errs.append(f"databases.{k}.service is only for mode: compose")
            if d.get("type") in ("postgres", "mysql", "mariadb") and not d.get("database"):
                errs.append(f"databases.{k}.database is required")
            needed = d.get("passwordSecret", f"{k.upper()}_PASSWORD")
            if needed not in secrets:
                errs.append(f"databases.{k}: secret {needed} must be listed in secrets")
        for k, c in caches.items():
            needed = c.get("passwordSecret", f"{k.upper()}_PASSWORD")
            if needed not in secrets:
                errs.append(f"caches.{k}: secret {needed} must be listed in secrets")
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
