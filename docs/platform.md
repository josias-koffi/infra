# Platform — Dokploy as code

One Dokploy panel (`dokploy.ops.koklo.dev`, on VPS20) runs every app. This
repo owns the panel, its servers and the deploy engine; each app owns **only**
its `.deploy/manifest.yaml`, next to its code.

```
infra (this repo)                             app repo
├─ ansible/      servers: base, docker,       ├─ .deploy/manifest.yaml  ← what to run
│                dokploy, housekeeping        ├─ .github/workflows/deploy.yml
├─ platform/     the Dokploy instance:        │    (templates/app-deploy.yml → calls
│                settings, R2 destinations,   │     .github/workflows/deploy.yml here)
│                Dokploy self-backup, nodes,  └─ code, Dockerfiles
│                registry
├─ apps/project  one Dokploy project per app + its environments
├─ apps/env      one environment of one app (state per env)
├─ modules/dokploy-app   manifest → Dokploy resources
├─ schema/manifest.v1.json + scripts/validate-manifest.py
└─ scripts/deploy-app.sh  the pipeline run for every app
```

## Model

| Manifest | Dokploy |
|---|---|
| `name` | one **project** |
| `environments.<env>` | one **environment** of that project (`production` is the default one) |
| `apps.<x>` / `workers.<x>` | one **application** per component (image from GHCR, tag = git sha) |
| `databases.<x>` | one **postgres / mysql / mariadb / mongo** service |
| `caches.<x>` | one **redis** service |
| `<app>.volumes` | named volume `<volumePrefix>_<name>` mounted on the app |
| `mode: compose` | legacy: one compose service for the whole stack |

State: `platform/dokploy.tfstate`, `apps/<name>/project.tfstate`,
`apps/<name>/<env>.tfstate` in the R2 bucket `koklo-tofu-state`. A staging
apply cannot touch production.

## Defaults that protect data

- **Backups are on.** Every database gets a daily dump to R2 (bucket per env,
  35 days in production, 7 in staging), every named volume a daily archive.
  Dokploy itself (DB + `/etc/dokploy`) is backed up daily to `dokploy/`.
  Opting out needs `backups: { enabled: false, reason: "…" }`.
- **Deploys never destroy state.** `scripts/deploy-app.sh` refuses a plan that
  deletes a database, cache, compose stack or mount. Removal goes through the
  protected `purge-env` workflow.
- **Volumes are pinned.** `volumePrefix` names the volumes of an env;
  `externalVolumes: true` (compose mode) makes compose fail instead of starting
  on an empty volume when the prefix is wrong.
- **Purge is automatic for what is disposable**: unused images and build cache
  daily on every node (Ansible `housekeeping` + Dokploy Docker cleanup), GHCR
  versions beyond the 20 newest weekly (`housekeeping.yml`), journald capped.

## Manifest

Reference: `examples/sample-services/.deploy/manifest.yaml` (new app),
`examples/jobspark` and `examples/jemima` (compose mode). Schema:
`schema/manifest.v1.json` (add the `yaml-language-server` comment for editor
completion).

Variables reach services in this order: `APP_ENV`, `IMAGE_TAG`, `APP_VERSION`,
`VOLUME_PREFIX`, `<DOMAINKEY>_DOMAIN` for each domain, `vars` (manifest then
env), connection variables from `uses:` (`DATABASE_URL`, `REDIS_URL`,
`<APP>_URL`), then secrets. `vars` values are templates:
`${secrets.X}`, `${domains.api}`, `${env}`, `${app}`, `${volume_prefix}`,
`${compose_sha}`.

Resources: `resources: { cpus: 0.5, memory: 512m }` on any component (and per
env through `overrides`). Compose mode: `compose.resources.<service>`.

## Adding an app

1. Write `.deploy/manifest.yaml` (start from the sample), run
   `scripts/validate-manifest.py`.
2. Copy `templates/app-deploy.yml` to `.github/workflows/deploy.yml` and plug
   the app's image build job in front of the `deploy` job (which calls
   `josias-koffi/infra/.github/workflows/deploy.yml@main`).
3. Create the GitHub environments `staging` and `production` with the secrets
   the manifest lists, plus the repo secrets of the template header.
4. Push to `develop` → staging, merge to `main` → production. Roll back with a
   manual run and an older `image_tag`.

## Day-2

| Task | Command |
|---|---|
| Plan an env from a workstation | `make app-plan MANIFEST=… ENV=staging` |
| Change instance settings / destinations | edit `platform/`, PR → plan, merge → apply |
| Add a server | [add-node.md](add-node.md) |
| Remove an env | [purge.md](purge.md) |
| Rebuild VPS20 | [restore.md](restore.md) |
| Migration of the pre-PaaS services | [migration.md](migration.md) |
