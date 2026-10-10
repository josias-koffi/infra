#!/usr/bin/env python3
"""Copies the secret values an app runs with into the infra environment
<app>-<env>, for an app moving from its own GitHub environments to the deploy
in infra (deploy-app.yml). GitHub never shows a secret again, so the values are
read from the app's state (apps/<app>/<env>.tfstate), where the service env
holds them.

    scripts/migrate-app-secrets.py <manifest> <environment> [--dry-run] [--force]

A value is found when the secret is in a service env under its own name, when a
var is exactly "${secrets.NAME}", or when it is a database/cache password.
The others are listed: type them with scripts/init-app-env.sh. Existing
secrets of the infra environment are kept unless --force. Values are never
printed.

Environment: TF_STATE_BUCKET and the R2 credentials (AWS_ENDPOINT_URL_S3,
AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, as `make` exports them); gh, aws.
"""
import json
import os
import re
import subprocess
import sys

import yaml


def state(app, env):
    out = subprocess.run(
        ["aws", "s3", "cp", f"s3://{os.environ['TF_STATE_BUCKET']}/apps/{app}/{env}.tfstate", "-"],
        capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"No state apps/{app}/{env}.tfstate — nothing deployed, nothing to migrate "
                 "(scripts/init-app-env.sh fills a new environment).")
    return json.loads(out.stdout)


def main(manifest_path, environment, dry_run=False, force=False):
    m = yaml.safe_load(open(manifest_path))
    app = m["name"]
    names = list(m.get("secrets", [])) + list(m.get("optionalSecrets", []))
    s = state(app, environment)

    # Env lines of every service (services mode) or of the compose.
    env_values = {}
    passwords = {}
    for r in s.get("resources", []):
        for i in r["instances"]:
            a = i["attributes"]
            for line in (a.get("env") or "").splitlines():
                k, sep, v = line.partition("=")
                if sep:
                    env_values.setdefault(k, v)
            if r["type"].startswith("dokploy_") and a.get("database_password"):
                passwords[(r["name"], i.get("index_key"))] = a

    found = {n: env_values[n] for n in names if n in env_values}

    # vars that are exactly ${secrets.NAME}: the env line of that var holds it.
    pattern = re.compile(r"^\$\{secrets\.([A-Za-z0-9_]+)\}$")
    var_maps = [m.get("vars", {})] + [c.get("vars", {}) for s_ in ("apps", "workers") for c in m.get(s_, {}).values()]
    var_maps.append(m["environments"][environment].get("vars", {}))
    for vars_ in var_maps:
        for var, tpl in (vars_ or {}).items():
            hit = pattern.match(str(tpl))
            if hit and hit.group(1) in names and var in env_values:
                found.setdefault(hit.group(1), env_values[var])

    # Database and cache passwords.
    for kind in ("databases", "caches"):
        for k, d in (m.get(kind) or {}).items():
            for (rname, key), a in passwords.items():
                if key != k:
                    continue
                found.setdefault(d.get("passwordSecret", f"{k.upper()}_PASSWORD"), a["database_password"])
                if a.get("database_root_password"):
                    found.setdefault(d.get("rootPasswordSecret", f"{k.upper()}_ROOT_PASSWORD"), a["database_root_password"])

    infra = subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
                           capture_output=True, text=True, check=True,
                           cwd=os.path.dirname(os.path.abspath(__file__))).stdout.strip()
    target = f"{app}-{environment}"
    if not dry_run:
        subprocess.run(["gh", "api", "-X", "PUT", f"repos/{infra}/environments/{target}"],
                       capture_output=True, check=True)
    have = set(subprocess.run(["gh", "secret", "list", "-R", infra, "-e", target, "--json", "name", "--jq", ".[].name"],
                              capture_output=True, text=True).stdout.split())

    print(f"{app}/{environment} → {infra}, environment {target}")
    for n in names:
        if n not in found:
            print(f"  ? {n}: not found in the state — scripts/init-app-env.sh -e {environment}")
        elif n in have and not force:
            print(f"  ✓ {n}: already set (kept)")
        elif dry_run:
            print(f"  · {n}: would be copied")
        else:
            subprocess.run(["gh", "secret", "set", n, "-R", infra, "-e", target],
                           input=found[n], text=True, capture_output=True, check=True)
            print(f"  ✓ {n}: copied")
    return 0


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        sys.exit(__doc__)
    sys.exit(main(*args, dry_run="--dry-run" in sys.argv, force="--force" in sys.argv))
