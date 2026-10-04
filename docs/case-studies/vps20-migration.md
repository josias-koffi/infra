# Case study — migrating VPS20 to the platform (runbook)

> Journal réel de la reprise d’un Dokploy en production (en anglais). Pour la méthode générale, voir [Reprendre un Dokploy existant](../getting-started/existing-dokploy.md).

## Outcome (2026-10-04)

| Step | Result |
|---|---|
| Safety net | 4 dumps with exact row counts + media / api_data archives, copied off the VPS |
| Platform | settings + 2 R2 destinations imported, Dokploy self-backup created, 0 destroyed |
| Jemima staging / production | compose moved / adopted in place: **no container restarted**, same volumes (now `external`), identical row counts; first off-site backups of DB and media |
| Jobspark staging / production | same, plus the existing R2 backups imported unchanged (retention 35 kept, legacy prefixes kept); version assertion green |
| Deploy rules | in the manifests: staging `deploy: auto` (push on develop), production `deploy: manual` (run from main) |
| Removed | projects `jemima-staging`, `jobspark-staging` (empty after the move), old app pipelines and their `infra/dokploy` (states released with `state rm`) |

Still to do: §3b (one service per component), §4 (koklo-front, koklo-ee-staging), §5 clean-up.

Starting point (audit 2026-10-04, read-only): Dokploy v0.30.6 on VPS20 with
four compose stacks managed from the app repos, plus `koklo-front` and
`koklo-ee-staging` running as plain compose outside Dokploy. Every step below
is reversible; production steps are run by hand, one at a time.

## Volume map — the source of truth

| App / env | Dokploy compose (appName) | Mounted volumes — keep | Not mounted |
|---|---|---|---|
| Jobspark **prod** | `jobspark` (`cvspark-vxlxow`) | `jobspark_*` | `cvforge_*` (pre-Dokploy prod, rollback) |
| Jobspark staging | `jobspark-staging` (`jobspark-staging-rdzqb4`) | `cvspark-staging_*` | `jobspark-staging_*` (orphans of 2026-09-26) |
| Jemima prod | `jemima` (`jemima-8ppofu`) | `jemima_*` | — |
| Jemima staging | `jemima-staging` (`jemima-staging-mtcbsk`) | `jemima-staging_*` | — |

The manifests (`examples/jobspark`, `examples/jemima`) pin these prefixes and
set `externalVolumes: true`: a wrong prefix fails the deploy instead of
starting on empty volumes. Their rendered env was checked against the live
`.env` files: every variable present, none missing.

## Verified behaviour (throwaway project, 2026-10-04)

- Changing `environment_id` of a compose moves it **in place**: same compose,
  same appName, same container (not even restarted), same volumes.
- **Deleting a compose deletes its named volumes**, unless they are declared
  `external: true` — hence `externalVolumes: true` everywhere in compose mode,
  and `tofu state rm` (never `destroy`) to release the old states.
- Deleting an application leaves the volumes it mounted.
- A mount added to an existing application only applies after a redeploy (the
  module redeploys automatically after mount changes).

## 0. Safety net

Done 2026-10-04: `/opt/backups/pre-paas-20261004T202924/` on VPS20 and
`~/perso/vps/snapshot/pre-paas-20261004T202924/` (4 dumps with exact row
counts, Jemima media, Jobspark api_data).

```bash
# fresh dumps of the four databases, pushed off the VPS
ssh kokloVps20 'ts=$(date +%Y%m%dT%H%M%S); mkdir -p /opt/backups/pre-paas-$ts; cd /opt/backups/pre-paas-$ts
  for c in cvspark-vxlxow-postgres-1:cvforge jobspark-staging-rdzqb4-postgres-1:cvforge \
           jemima-8ppofu-postgres-1:jemima jemima-staging-mtcbsk-postgres-1:jemima; do
    n=${c%%:*}; u=${c##*:}; docker exec $n pg_dumpall -U $u | gzip > $n.sql.gz
    docker exec $n psql -U $u -d $u -At -F= -c "select relname, n_live_tup from pg_stat_user_tables order by 1" > $n.counts   # estimates; count(*) key tables for an exact check
  done; ls -la'
scp -r kokloVps20:/opt/backups/pre-paas-* ~/perso/vps/snapshot/
```

Jemima has no off-site backup before step 2: do this first.

## 1. Platform (no change on the server)

1. `.env` from `.env.example`; GitHub secrets of this repo:
   `DOKPLOY_API_KEY`, `R2_*`, `R2_BACKUP_{PROD,STAGING}_*`.
2. Stop the old app pipelines from touching the shared records: disable the
   *Deploy* workflow of `cvforge` and `jemima-portfolio`
   (`gh workflow disable deploy.yml -R josias-koffi/cvforge`, same for jemima).
3. Hand the destinations to `platform/` — **no destroy**:
   ```bash
   cd ~/perso/projets/cvforge/infra/dokploy
   for e in production staging; do
     tofu init -reconfigure -backend-config="key=cvspark/dokploy-$e.tfstate"
     tofu state rm dokploy_destination.backups
   done
   ```
4. `make platform-plan` → must show **imports only** (2 destinations, the
   settings record) plus creates (Dokploy self-backup, notification). Then
   `make platform-apply`.
5. `make setup-manager CHECK=1` → no destructive change (the dokploy role only
   reports the version), then `make setup-manager`.

## 2. Jemima → one project, two environments

```bash
cp examples/jemima/.deploy/manifest.yaml ~/perso/projets/jemima-portfolio/.deploy/manifest.yaml
cd ~/perso/projets/jemima-portfolio/infra/dokploy        # release the old states, NO destroy
tofu init -reconfigure -backend-config="key=jemima/dokploy-staging.tfstate"
tofu state rm dokploy_project.jemima dokploy_compose.jemima 'dokploy_domain.jemima'
tofu init -reconfigure -backend-config="key=jemima/dokploy-production.tfstate"
tofu state rm dokploy_project.jemima dokploy_compose.jemima 'dokploy_domain.jemima'
```

Then from this repo, staging first, with the tag **currently running**
(`docker ps --format '{{.Image}}' | grep jemima`) so no new code ships with
the move:

```bash
export SECRETS_JSON=$(…)   # the staging secrets, as JSON — or run the app workflow manually
make app-plan  MANIFEST=../../jemima-portfolio/.deploy/manifest.yaml ENV=staging TAG=<running tag>
```

The plan must show: project `jemima` **imported**, environment `staging`
**created**, compose `L3b8…` **imported and updated in place**
(`environment_id`, env, compose text), domains imported, backups **created**.
No `destroy`, no `replace`. Apply with `make app-deploy …`. The compose
redeploys once (same volumes, now `external`).

Check: `curl -I https://jemima-staging.koklo.dev`, compare
`docker exec … psql … pg_stat_user_tables` with the `.counts` of step 0,
`docker inspect jemima-staging-mtcbsk-postgres-1 --format '{{range .Mounts}}{{.Name}} {{end}}'`
still lists `jemima-staging_postgres_data`. Same for production. Delete the
empty project `jemima-staging` in the panel, `apps/adopt/jemima.yaml`, and
`infra/dokploy` + `infra/terraform`… of the app repo (DNS: keep
`dns: external` until its records are imported, see §6). Install
`templates/app-deploy.yml` as the app's deploy workflow (it calls the
reusable `deploy.yml` of this repo).

Rollback: the compose keeps its appName and volumes; moving it back is an
`environment_id` change in the panel (*Move*), and the old app pipeline can be
re-enabled after `tofu import` of the released resources.

## 3. Jobspark → one project, two environments

Same procedure with `examples/jobspark` and the cvforge states
(`cvspark/dokploy-{production,staging}.tfstate`, addresses
`dokploy_project.jobspark dokploy_compose.jobspark 'dokploy_domain.jobspark'
dokploy_backup.postgres dokploy_volume_backup.api_data`). The existing R2
backups are **imported** (history kept, legacy prefixes `db/<env>/` and
`api-data/<env>/` pinned in the manifest). Delete the `jobspark-staging` and
`CVSpark` (hello-world demo) projects once empty.

## 3b. Split into one service per component (after a week stable)

Per app, staging first:

1. **Stateless** (web, landing, api, puppeteer / app): add them under `apps:`
   with temporary domains, deploy, smoke test; then remove the service from
   the compose file and move the domain to the application.
2. **File volumes** (`api_data`, `minio_data`): the application mounts the same
   named volume (`volumes:` → `dokploy_mount`); stop the compose service first.
3. **Redis**: check whether it holds durable data (`redis-cli info keyspace`,
   queue keys) before choosing empty start vs RDB copy.
4. **Postgres**: `databases:` entry (same `postgres:16-alpine`), maintenance
   window, `pg_dump | pg_restore` into the new service, compare counts, switch
   `uses:`. The old `*_postgres_data` volume stays untouched as rollback.
5. Native backups replace the `db_backup` / `r2_fetch` sidecars; the compose
   is deleted when empty, its volumes stay until §5.

## 4. Services outside Dokploy

- `koklo-front` (stateless): manifest in the `koklo-front` repo, `mode: services`
  (`site` and `docs`, staging + production). Cut-over:
  `docker compose -f /opt/koklo/stacks/koklo-front/docker-compose.yml down`
  then deploy; rollback = `up -d`. Then retire the SSH deploy of koklo-infra
  (`deploy-staging.yml`, `deploy-prod.yml`, `stacks/`).
- `koklo-ee-staging`: the live label says `ee-staging.ops.koklo.dev`, the file
  says `api-staging.koklo.dev` — decide the domain (or retire it) first.

## 5. One-off clean-up (each item confirmed)

| Item | Check before removal |
|---|---|
| stack `/opt/koklo/stacks/cvforge` + `cvforge_*` volumes (≈ 290 MB) | `/opt/backups/cvforge-pre-dokploy-*` present, archive volumes to R2 |
| `/opt/traefik` + exited container `traefik` | `dokploy-traefik` serves every domain |
| exited task `dokploy.1.owsy…`, `*-minio-init-1` | exited one-shots |
| network `zzprecreated_default`, volume `zz_precreated_test` | test leftovers |
| volumes `jobspark-staging_*` + anonymous unused | not mounted (`docker ps -a --filter volume=…`) |
| ≈ 30 GB of unused images | first run of `docker-housekeeping` |

## 6. DNS adoption (optional, last)

Records still live in `cvforge/infra/terraform` and
`jemima-portfolio/infra/terraform`. To manage them from the manifest: list the
record ids (`tofu state show`), add them to `apps/adopt/<app>.yaml` under
`environments.<env>.dnsRecords`, `tofu state rm` them from the old state, set
`dns: cloudflare`. Mail records (Resend DKIM/SPF/DMARC) stay in the app's
`infra/terraform` or move to `terraform/` here.
