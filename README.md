# infra

**Ma plateforme d'hébergement auto-hébergée**, construite sur
[Dokploy](https://dokploy.com) et entièrement décrite en code : les serveurs,
le panel et chaque app qui y tourne.

Une app se décrit dans **un seul fichier**, placé à côté de son code. Un push
sur `develop` la déploie en staging ; un merge sur `main` la déploie en
production.

```yaml
# .deploy/manifest.yaml (dans le repo de l'app)
apiVersion: deploy/v1
name: shop
apps:
  api: { image: ghcr.io/me/shop-api, port: 8080, domain: api, uses: [db], resources: { memory: 1g } }
databases:
  db: { type: postgres, database: shop, user: shop }          # sauvegardée chaque jour, par défaut
environments:
  production: { branch: main,    domains: { api: api.shop.example } }
  staging:    { branch: develop, domains: { api: api-staging.shop.example } }
```

Ce fichier donne :
- un projet Dokploy `shop`, avec deux environnements ;
- un service par composant (l'API et Postgres), avec ses limites ;
- le domaine en HTTPS et l'enregistrement DNS ;
- la sauvegarde quotidienne de la base vers R2 ;
- un smoke test après chaque déploiement.

## Ce que ça apporte

- **Un projet par app, un environnement par étape.** Chaque composant (app,
  worker, base, cache) est un service Dokploy à part, avec ses limites CPU et
  mémoire, ses logs et ses redéploiements.
- **Les données protégées par défaut :**
  - chaque base et chaque volume est sauvegardé tous les jours vers
    Cloudflare R2, et Dokploy lui-même aussi ;
  - un déploiement refuse de supprimer ce qui contient des données ;
  - supprimer un environnement passe par un workflow protégé, qui archive les
    volumes d'abord.
- **Une purge automatique :** images et cache de build sur chaque serveur,
  rotation des images du registre, journal système plafonné.
- **Plusieurs serveurs :** ajouter une machine, c'est un playbook et une ligne
  dans `platform/nodes.yaml`. Une app choisit ensuite son serveur avec
  `server:`.
- **Reproductible :** un serveur perdu se reconstruit depuis ce repo et les
  sauvegardes R2.
- **Adoptable :** un Dokploy déjà en production se reprend par import, sans
  rien recréer.

## Démarrer

| Tu as… | Lis |
|---|---|
| un serveur vierge | [Prérequis](docs/getting-started/prerequisites.md), puis [Installation neuve](docs/getting-started/fresh-install.md) |
| un Dokploy qui tourne déjà | [Reprendre un Dokploy existant](docs/getting-started/existing-dokploy.md) |
| une plateforme en place, et une app à déployer | [Déployer une app](docs/guides/deploy-an-app.md) |

En bref :

```bash
gh repo fork josias-koffi/infra --clone && cd infra
cp .env.example .env                                   # URL Dokploy, clé API, buckets et tokens R2
cp ansible/inventory/hosts.example ansible/inventory/hosts
make setup-manager                                     # Docker + Dokploy (version figée) + purge
make platform-apply                                    # destinations de sauvegarde, auto-sauvegarde, registre
scripts/set-secrets.sh                                 # la même config pour la CI
```

## Documentation

L'index complet est dans [`docs/`](docs/README.md).

- **Guides :** [déployer une app](docs/guides/deploy-an-app.md) ·
  [ajouter un serveur](docs/guides/add-a-server.md) ·
  [sauvegardes et restauration](docs/guides/backups-and-restore.md) ·
  [purge](docs/guides/purge.md)
- **Référence :** [manifest](docs/reference/manifest.md) ·
  [configuration](docs/reference/configuration.md) ·
  [architecture](docs/reference/architecture.md) ·
  [comportements Dokploy vérifiés](docs/reference/dokploy-behaviour.md)
- **Retour d'expérience :** [migration d'un VPS en production](docs/case-studies/vps20-migration.md)

## Organisation du repo

```
ansible/                 serveurs : sécurisation, Docker, Dokploy, purge
platform/                l'instance Dokploy : réglages, sauvegardes, registre, serveurs
apps/project, apps/env   roots OpenTofu lancés pour chaque app (projet, puis un environnement)
modules/dokploy-app      manifest → services, domaines, montages, sauvegardes (tests avec provider simulé)
schema/, scripts/        contrat du manifest, validateur, pipeline de déploiement
.github/workflows/       deploy.yml (réutilisable par les apps), platform, purge-env, housekeeping
templates/               workflow à copier dans le repo d'une app
examples/                manifests de référence
docs/                    documentation
```

## Stack

Dokploy · Docker Swarm · Traefik · OpenTofu (provider
[`vanillauys/dokploy`](https://registry.terraform.io/providers/vanillauys/dokploy))
· Ansible · GitHub Actions · Cloudflare (DNS, R2)

Testé avec Dokploy v0.30.6 sur Ubuntu 24.04. `make test` valide les
manifests, lance les tests du module (provider simulé) et valide tous les
roots ; la CI le rejoue sur chaque PR.
