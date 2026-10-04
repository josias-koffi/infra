# Purge

## Automatique, rien à faire

| Quoi | Où | Quand |
|---|---|---|
| Images inutilisées de plus de 7 jours, cache de build (les conteneurs arrêtés sont conservés) | chaque serveur : `docker-housekeeping.timer` (rôle Ansible `housekeeping`) | tous les jours à 4h30 |
| Images inutilisées, cache de build | serveur du panel : nettoyage Docker de Dokploy (`enable_docker_cleanup`) ; serveurs distants : `enable_docker_cleanup` du `dokploy_server` | tous les jours |
| Log d'accès de Traefik | `log_cleanup_cron` de Dokploy | tous les jours |
| Journal système | `SystemMaxUse=500M` | en continu |
| Versions GHCR au-delà des 20 plus récentes (les tags de branche et d'env sont conservés) | `.github/workflows/housekeeping.yml` (liste des images à tenir à jour) | chaque semaine |
| Anciennes sauvegardes | `keep_latest_count` de chaque sauvegarde | à chaque exécution |

Les **volumes ne sont jamais purgés automatiquement**.

Le workflow GHCR a besoin d'un secret `GHCR_ADMIN_TOKEN` : un token avec
`read:packages` et `delete:packages` sur le propriétaire des images.

## Retirer un service

- **Sans état** (app, worker) : supprime-le du manifest ; le déploiement
  suivant l'enlève.
- **Avec état** (base, cache, compose, montage) : le déploiement **refuse**.
  C'est volontaire. Supprimer un service Dokploy peut supprimer ses données
  ([comportement vérifié](../reference/dokploy-behaviour.md)).

## Supprimer un environnement complet

Lance le workflow **Purge environment** (*Actions → purge-env.yml*) avec ces
entrées :

| Entrée | Valeur |
|---|---|
| `repository` | repo de l'app (`owner/name`), qui contient `.deploy/manifest.yaml` |
| `environment` | environnement à supprimer |
| `confirm` | `<app>/<environment>`, à taper exactement |
| `dry_run` | **laisse-le activé la première fois** : il affiche seulement le plan de destruction |
| `delete_volumes` | supprimer aussi les volumes restants |

Déroulement :

1. Tous les volumes de l'environnement (`<volumePrefix>_*`, plus les volumes
   de données de ses bases) sont archivés dans `/opt/backups/purge/` sur le
   serveur, **avant toute suppression**.
2. Les services sont détruits.
3. Avec `delete_volumes`, les volumes restants qui ne sont plus utilisés par
   un conteneur sont supprimés.

Prérequis :
- un environnement GitHub `purge` avec un reviewer obligatoire ;
- les secrets `SSH_PRIVATE_KEY` (clé SSH root du serveur) et `MANAGER_IP` ;
- `APP_REPOS_READ_TOKEN` si le repo de l'app est privé.
