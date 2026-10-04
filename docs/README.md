# Documentation

## Démarrer

| Page | Pour qui |
|---|---|
| [Prérequis](getting-started/prerequisites.md) | serveur, domaine Cloudflare, buckets et tokens R2, outils locaux |
| [Installation neuve](getting-started/fresh-install.md) | un serveur vierge, jusqu'à une première app déployée |
| [Reprendre un Dokploy existant](getting-started/existing-dokploy.md) | un Dokploy déjà en production, repris sans rien recréer |

## Guides

| Page | Sujet |
|---|---|
| [Déployer une app](guides/deploy-an-app.md) | manifest, workflow, secrets, rollback |
| [Ajouter un serveur](guides/add-a-server.md) | serveurs distants Dokploy |
| [Sauvegardes et restauration](guides/backups-and-restore.md) | ce qui est sauvegardé, restaurer une base ou un volume, reconstruire un serveur |
| [Purge](guides/purge.md) | nettoyage automatique, suppression d'un service ou d'un environnement |

## Référence

| Page | Contenu |
|---|---|
| [Manifest](reference/manifest.md) | toutes les clés de `.deploy/manifest.yaml` |
| [Configuration](reference/configuration.md) | `.env`, secrets GitHub, commandes `make`, fichiers à adapter dans un fork |
| [Architecture](reference/architecture.md) | couches, states, déroulement d'un déploiement, garde-fous, limites |
| [Comportements Dokploy vérifiés](reference/dokploy-behaviour.md) | ce qui a été testé, et pourquoi les garde-fous existent |

## Retour d'expérience

- [Migration de VPS20](case-studies/vps20-migration.md) : reprise réelle de
  stacks en production (volumes, adoption, ordre des opérations)
