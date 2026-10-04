# Purge

## Automatic (nothing to do)

| What | Where | When |
|---|---|---|
| Unused images > 7 days, build cache (stopped containers kept) | every node — `docker-housekeeping.timer` (Ansible) | daily 04:30 |
| Unused images, build cache | manager — Dokploy Docker cleanup (`enable_docker_cleanup`, on) ; remote nodes: on | daily |
| Traefik access log | Dokploy `log_cleanup_cron` | daily |
| Journald | `SystemMaxUse=500M` | continuous |
| GHCR versions beyond the 20 newest (branch/env tags kept) | `housekeeping.yml` | weekly |
| Old backups | `keep_latest_count` (35 prod / 7 staging) + R2 bucket lock | each run |

Volumes are **never** pruned automatically.

## Removing a service or an environment

- A component deleted from a manifest: the next deploy **refuses** if it holds
  state (database, cache, compose, mount). Stateless apps are removed normally.
- An environment: run **Purge environment** (Actions → `purge-env.yml`):
  `repository`, `environment`, `confirm=<app>/<env>`. Keep `dry_run` on first
  to read the destroy plan. Before destroying anything, every volume of the
  env (`<volumePrefix>_*` and the data volumes of its database services) is
  archived to `/opt/backups/purge/`. `delete_volumes` then removes the external
  volumes that are left (a deleted compose takes its non-external volumes with
  it, a deleted database its data volume — verified on Dokploy 0.30.6). The `purge` GitHub
  environment requires a reviewer.

## One-off clean-up of VPS20 (migration leftovers, 2026-10-04 audit)

Done by hand, one item at a time, after the migration — see migration.md §5.
