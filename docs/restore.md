# Rebuilding VPS20

Sources of truth: this repo, the R2 bucket `koklo-db-backups` (`dokploy/` =
Dokploy DB + `/etc/dokploy`, `db/…`, `volumes/…`), GHCR images.

1. New VPS: update `VPS20_IP` in `.env`, `ansible/inventory/hosts`,
   `platform/nodes.yaml`, `~/.ssh/config`.
2. `make setup-manager` — base, Docker, **fresh Dokploy at the pinned version**
   (the role installs only when no Dokploy runs), housekeeping.
3. Restore Dokploy from the latest `dokploy/` archive in R2: stop the
   `dokploy` service, extract `/etc/dokploy`, load the database dump
   (`gunzip -c <dump> | docker exec -i <dokploy-postgres> psql -U dokploy`),
   start `dokploy` again.
4. `make platform-apply`, then re-run the deploy workflow of each app
   (staging then production): services are recreated from their manifests.
5. Restore each database from its latest `db/<app>/<env>/` dump (*Backups →
   Restore* on the database service), and each volume from `volumes/…`.
6. Point DNS: deploys rewrite the A records of apps with `dns: cloudflare`;
   `make dns` covers the koklo.dev records of `terraform/`.

The hand-made snapshot of 2026-09-28 (`~/perso/vps/snapshot/vps20-20260928-2358/`)
remains a fallback for the pre-migration state.
