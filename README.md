# infra

My self-hosted platform, built on [Dokploy](https://dokploy.com) and driven
entirely as code: the servers, the panel, and every app that runs on it.

An app describes itself in one file, `.deploy/manifest.yaml`, next to its own
code. Pushing to `develop` deploys staging, and merging to `main` deploys
production.

```yaml
apiVersion: deploy/v1
name: sample
apps:
  api: { image: ghcr.io/josias-koffi/sample-api, port: 8080, domain: api, uses: [db], resources: { memory: 1g } }
databases:
  db: { type: postgres, database: sample, user: sample }   # backed up daily, by default
environments:
  production: { branch: main,    domains: { api: api.example.com } }
  staging:    { branch: develop, domains: { api: api-staging.example.com } }
```

## What it does

- **One project per app, with one environment per stage.** Every component
  (app, worker, database, cache) is its own Dokploy service, with its own
  resource limits, logs and redeploys.
- **Data protected by default:**
  - every database and volume is backed up daily to Cloudflare R2, and so is
    the panel itself;
  - a deploy refuses to destroy anything that holds state;
  - removing an environment goes through a protected workflow that archives
    the volumes first.
- **Automatic purge:** unused images and build cache are pruned on every node,
  registry versions are rotated, and the journal is capped.
- **Multi-server:** adding a server is one Ansible run plus one line in
  `platform/nodes.yaml`. An app then picks it with `server:`.
- **Reproducible:** a lost server is rebuilt from this repo and the R2 backups
  (`docs/restore.md`).

## Layout

| Path | Role |
|---|---|
| `ansible/` | server provisioning: hardening, Docker, Dokploy (pinned, never reinstalled over a live panel), housekeeping |
| `platform/` | the Dokploy instance: settings, backup destinations, self-backup, registry, remote servers |
| `apps/project`, `apps/env` | OpenTofu roots run for each app: the project with its environments, then one environment |
| `modules/dokploy-app` | manifest → Dokploy applications, databases, caches, domains, mounts, backups (tested with a mocked provider) |
| `schema/`, `scripts/validate-manifest.py` | the manifest contract |
| `.github/workflows/deploy.yml` | the reusable deploy workflow that app repos call |
| `templates/app-deploy.yml` | the caller workflow to copy into an app |
| `examples/` | reference manifests |

## Use

```bash
cp .env.example .env                          # fill in the Dokploy key and R2 tokens
cp ansible/inventory/hosts.example ansible/inventory/hosts
make test                                     # schema, module tests, validation
make setup-manager CHECK=1                    # dry run against the manager
make platform-plan
make app-plan MANIFEST=../my-app/.deploy/manifest.yaml ENV=staging
```

Documentation: [platform](docs/platform.md) · [add a server](docs/add-node.md) ·
[purge](docs/purge.md) · [restore](docs/restore.md) ·
[migration of the existing services](docs/migration.md)

Stack: Dokploy · Docker Swarm · Traefik · OpenTofu · Ansible · GitHub Actions · Cloudflare (DNS, R2)
