# Installation neuve

Ce guide part d'un serveur vierge et va jusqu'à une première app déployée.
Compte environ une heure, dont la moitié passée dans la console Cloudflare.

Avant de commencer : [prérequis](prerequisites.md). Ils listent le serveur, le
domaine, les 3 buckets R2 et leurs tokens, et les outils à installer.

## 1. Récupérer le repo

Fais un fork de ce repo (ou *Use this template*), puis clone-le :

```bash
gh repo fork josias-koffi/infra --clone && cd infra
```

Un fork contient encore des fichiers propres à l'instance d'origine. Il faut
les adapter :

| Fichier | Quoi faire |
|---|---|
| `platform/adopt.yaml` | **le supprimer** : il ne sert qu'à reprendre un Dokploy existant |
| `apps/adopt/*.yaml` | **les supprimer**, pour la même raison |
| `platform/nodes.yaml` | remplacer `vps20` par le nom et l'IP de ton serveur (`role: manager`) |
| `.github/workflows/deploy.yml` | remplacer la valeur par défaut de `infra_repository` par `<toi>/infra` |
| `templates/app-deploy.yml` | remplacer `josias-koffi/infra` par `<toi>/infra` dans `uses:` |
| `.github/workflows/housekeeping.yml` | lister tes propres images GHCR |
| `schema/manifest.v1.json`, `examples/*` | remplacer l'URL `$id`, ou laisser telle quelle (elle ne sert qu'à la complétion dans l'éditeur) |

Les manifests `examples/jobspark` et `examples/jemima` servent aux tests du
module : garde-les.

## 2. Configuration locale

```bash
cp .env.example .env
cp ansible/inventory/hosts.example ansible/inventory/hosts
```

- `ansible/inventory/hosts` : mets l'IP du serveur sous `[dokploy_manager]`.
- `.env` : remplis pour l'instant `TF_STATE_BUCKET`, `R2_*` et
  `R2_BACKUP_BUCKET_*`. `DOKPLOY_URL` et `DOKPLOY_API_KEY` viennent aux
  étapes 4 et 5.

Le `.env` et l'inventaire sont ignorés par git. La liste complète des
variables est dans la [référence de configuration](../reference/configuration.md).

## 3. Provisionner le serveur et installer Dokploy

```bash
make setup-manager CHECK=1     # dry run : affiche ce qui va changer
make setup-manager
```

Le playbook applique les rôles suivants :

- `base` : utilisateur admin (`devops` par défaut) avec ta clé SSH, connexion
  SSH par clé uniquement, `ufw` limité aux ports 22, 80 et 443, fail2ban,
  mises à jour de sécurité automatiques ;
- `docker` : installe Docker CE ;
- `dokploy` : installe la version figée dans
  `ansible/roles/dokploy/defaults/main.yml`. Le rôle n'installe **que** si
  aucun Dokploy ne tourne et que Swarm est inactif ;
- `housekeeping` : timer quotidien qui purge les images et le cache de build,
  et limite la taille du journal système.

## 4. Premier accès au panel

1. Ouvre `http://<ip>:3000` et crée le compte administrateur.
2. Chez Cloudflare, crée un enregistrement A, par exemple
   `dokploy.example.com` → IP du serveur, **proxy désactivé** (nuage gris).
3. Dans *Settings → Web Server*, renseigne ce domaine, active HTTPS avec
   Let's Encrypt, puis enregistre. Le panel répond alors en
   `https://dokploy.example.com`.
4. Dans `.env`, mets `DOKPLOY_URL=https://dokploy.example.com`.

Une fois le domaine actif, ne laisse pas le port 3000 ouvert. Les ports
publiés par Docker contournent `ufw`, donc la règle du pare-feu ne suffit pas.
Vérifie avec `ss -tlnp | grep :3000` ; si le port est encore publié :

```bash
docker service update --publish-rm 3000 dokploy
```

Le panel reste accessible en HTTPS, servi par Traefik sur le port 443.

## 5. Clé API

Dans *Settings → Profile → API / CLI*, génère une clé (par exemple `infra`)
et colle-la dans `DOKPLOY_API_KEY`.

Si l'option existe, laisse le *rate limiting* de la clé désactivé : une clé
bridée répond `401` et non `429`, ce qui ressemble à une erreur
d'authentification.

## 6. Configurer l'instance en code

```bash
make platform-plan
make platform-apply
```

Ce que l'apply crée :

- les deux destinations de sauvegarde R2, testées par Dokploy avant
  l'enregistrement (`verify_connection`), si bien qu'un mauvais token fait
  échouer l'apply ;
- la sauvegarde quotidienne de Dokploy lui-même (base et `/etc/dokploy`) vers
  `<bucket prod>/dokploy/`, 14 copies conservées ;
- les réglages du serveur (nettoyage Docker quotidien) ;
- le registre GHCR, si `GHCR_USERNAME` et `GHCR_TOKEN` sont renseignés (pour
  tirer des images privées).

## 7. Vérifier

```bash
make test             # schéma, tests du module (provider simulé), validation des roots
make platform-plan    # doit répondre « No changes »
```

## 8. Brancher la CI

```bash
scripts/set-secrets.sh          # pousse le .env dans les secrets et variables du repo
```

Le script n'affiche jamais une valeur. Il n'active le job `platform`
(variable `PLATFORM_ENABLED=true`) que si tout ce qui est obligatoire est
renseigné. Ensuite, une modification de `platform/` donne un `plan` sur la PR
et un `apply` au merge sur `main`.

## 9. Première app

Suis le guide [déployer une app](../guides/deploy-an-app.md). En résumé : un
`.deploy/manifest.yaml`, le workflow `templates/app-deploy.yml`, les secrets
de l'app, puis un push sur `develop`.

## Ensuite

- [Ajouter un serveur](../guides/add-a-server.md)
- [Sauvegardes et restauration](../guides/backups-and-restore.md)
- [Purge](../guides/purge.md)
