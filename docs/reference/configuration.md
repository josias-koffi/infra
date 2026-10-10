# Référence de configuration

## `.env` (ton poste) et repo `infra` (CI)

`scripts/set-secrets.sh` pousse le `.env` dans le repo GitHub, sous forme de
secrets ou de variables selon la colonne *GitHub*.

| Nom | GitHub | Obligatoire | Rôle |
|---|---|---|---|
| `DOKPLOY_URL` | variable | oui | URL du panel |
| `DOKPLOY_API_KEY` | secret | oui | clé API Dokploy |
| `TF_STATE_BUCKET` | variable | oui | bucket R2 des states |
| `R2_ENDPOINT` | secret | oui | `https://<account_id>.r2.cloudflarestorage.com` |
| `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | secret | oui | token du bucket de state |
| `R2_BACKUP_BUCKET_PROD`, `R2_BACKUP_BUCKET_STAGING` | variable | oui | buckets de sauvegarde |
| `R2_BACKUP_PROD_ACCESS_KEY_ID`, `R2_BACKUP_PROD_SECRET_ACCESS_KEY` | secret | oui | token du bucket de prod |
| `R2_BACKUP_STAGING_ACCESS_KEY_ID`, `R2_BACKUP_STAGING_SECRET_ACCESS_KEY` | secret | oui | token du bucket de staging |
| `CF_API_TOKEN`, `CF_ACCOUNT_ID` | secret | non | DNS des apps dans toutes les zones du compte, buckets R2 et leurs tokens. Permissions du token : *Zone → Zone → Read* et *Zone → DNS → Edit* (toutes les zones), *Account → Workers R2 Storage → Edit*, *Account → Account API Tokens → Edit*. `CF_ZONE_ID` est déprécié : repli pour un hôte qu'aucune zone ne couvre |
| `RESEND_ADMIN_API_KEY` | secret | avec `mail` | clé Resend *full access* : `zones/` crée les domaines d'envoi, `apps/env` une clé d'envoi par app et environnement |
| `ZONES_ENABLED` | variable | non | active le workflow `zones.yml` (à poser une fois `CF_*` et `RESEND_ADMIN_API_KEY` en place) |
| `APP_REPOS_READ_TOKEN` | secret | oui pour déployer | token fine-grained *Contents: Read* sur les repos d'apps (`deploy-app.yml`, `purge-env.yml`) |
| `INFRA_DEPLOY_TOKEN` | — (`.env` seulement) | oui pour brancher une app | token fine-grained *Actions: Read and write* sur ce repo seul ; `scripts/onboard-app.sh` le copie dans chaque repo d'app |
| `GHCR_USERNAME` / `GHCR_TOKEN` | variable / secret | non | identifiants pour tirer des images privées |
| `NODE_SSH_PUBLIC_KEY` / `NODE_SSH_PRIVATE_KEY` | variable / secret | avec des serveurs distants | `make node-key` |
| `NODE_ADMIN_USER` | — | non (`devops`) | utilisateur admin créé par Ansible |
| `OPERATOR_SSH_PUBLIC_KEY_FILE` | — | non (`~/.ssh/id_ed25519.pub`) | clé autorisée sur les serveurs |
| `SWAP_SIZE_MB` | — | non (`0`) | swap à créer |
| `PLATFORM_ENABLED` | variable | posée par le script | active le job `platform` de la CI |

Secrets propres aux workflows de maintenance :

| Nom | Workflow |
|---|---|
| `GHCR_ADMIN_TOKEN` | `housekeeping.yml` (rétention des images) |
| `SSH_PRIVATE_KEY`, `MANAGER_IP` | `purge-env.yml` |

## Repo d'une app

Le déploiement tourne dans infra (`deploy-app.yml`) : le repo d'une app ne
porte aucun accès plateforme.

| Nom | Où | Rôle |
|---|---|---|
| `INFRA_DEPLOY_TOKEN` | secret du repo de l'app | lance `deploy-app.yml` dans infra (`scripts/onboard-app.sh`) |
| secrets du manifest | environnements `<app>-<env>` **du repo infra** | valeurs propres à chaque environnement (`scripts/init-app-env.sh`) |

Une app encore sur l'ancien `deploy.yml` réutilisable garde les secrets
plateforme dans son repo (`scripts/set-secrets.sh --legacy-app <owner>/<app>`)
et ses environnements `staging` / `production` ; pour la migrer, voir
[Déployer une app](../guides/deploy-an-app.md#migrer-une-app-depuis-lancien-deployyml).

## Commandes `make`

| Commande | Effet |
|---|---|
| `make setup-manager [CHECK=1]` | provisionne le serveur du panel (dry run avec `CHECK=1`) |
| `make add-node NODE=<hôte>` | prépare un serveur distant |
| `make node-key` | génère la paire de clés des serveurs distants |
| `make platform-plan` / `platform-apply` | instance Dokploy |
| `make zones-plan` / `zones-apply` | domaines d'envoi et leurs enregistrements (`zones/zones.yaml`) |
| `make app-plan MANIFEST=… ENV=… [TAG=…]` | plan d'un environnement d'app |
| `make app-deploy MANIFEST=… ENV=… TAG=…` | déploiement depuis ton poste |
| `make test` | schéma, tests du module, validation de tous les roots |
| `scripts/onboard-app.sh <owner>/<app> [checkout]` | branche une app : token de déploiement, environnements et secrets dans infra |
| `scripts/migrate-app-secrets.py <manifest> <env>` | recopie les secrets d'une app de l'ancien modèle vers infra |

## Fichiers à adapter dans un fork

`platform/nodes.yaml`, `platform/adopt.yaml` (à supprimer pour une
installation neuve), `apps/adopt/`, `infra_repository` dans
`.github/workflows/dispatch-deploy.yml`, `uses:` dans `templates/app-deploy.yml`, et la
liste des images dans `.github/workflows/housekeeping.yml`.

## Version de Dokploy

Elle est figée dans `ansible/roles/dokploy/defaults/main.yml`
(`dokploy_version`). Pour mettre à jour : change la valeur, puis
`ansible-playbook ansible/playbooks/setup-manager.yml -e dokploy_allow_upgrade=true`. Le rôle utilise alors
l'updater officiel ; il ne réinstalle jamais.
