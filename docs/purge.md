# Purge

## Automatic (nothing to do)

| What | Where | When |
|---|---|---|
| Unused images > 7 days, build cache (stopped containers kept) | every node — `docker-housekeeping.timer` (Ansible) | daily 04:30 |
| Unused images, stopped containers, build cache | manager — Dokploy Docker cleanup, `enable_docker_cleanup` (**off until migration §5**) ; remote nodes: on | daily |
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
  to read the destroy plan. `delete_volumes` archives each
  `<volumePrefix>_*` volume to `/opt/backups/purge/<ts>/` before removing it,
  and skips any volume still used by a container. The `purge` GitHub
  environment requires a reviewer.

## One-off clean-up of VPS20 (migration leftovers, 2026-10-04 audit)

Done by hand, one item at a time, after the migration — see migration.md §5.
