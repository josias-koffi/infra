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
| `CF_API_TOKEN`, `CF_ZONE_ID` | secret | non | DNS des apps (`purge-env.yml` ici ; poussés dans chaque repo d'app par `--app`) |
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
| `SSH_PRIVATE_KEY`, `MANAGER_IP`, `APP_REPOS_READ_TOKEN` | `purge-env.yml` |

## Repo d'une app

`scripts/set-secrets.sh --app <owner>/<app>` pose les variables et secrets du
repo depuis le `.env` d'infra.

| Nom | Type | Rôle |
|---|---|---|
| `DOKPLOY_URL`, `TF_STATE_BUCKET` | variables du repo | comme ci-dessus |
| `DOKPLOY_API_KEY`, `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | secrets du repo | comme ci-dessus |
| `CF_API_TOKEN`, `CF_ZONE_ID` | secrets du repo | DNS (`dns: cloudflare`) |
| secrets du manifest | secrets des **environnements** `staging` et `production` | valeurs propres à chaque environnement |

## Commandes `make`

| Commande | Effet |
|---|---|
| `make setup-manager [CHECK=1]` | provisionne le serveur du panel (dry run avec `CHECK=1`) |
| `make add-node NODE=<hôte>` | prépare un serveur distant |
| `make node-key` | génère la paire de clés des serveurs distants |
| `make platform-plan` / `platform-apply` | instance Dokploy |
| `make app-plan MANIFEST=… ENV=… [TAG=…]` | plan d'un environnement d'app |
| `make app-deploy MANIFEST=… ENV=… TAG=…` | déploiement depuis ton poste |
| `make test` | schéma, tests du module, validation de tous les roots |

## Fichiers à adapter dans un fork

`platform/nodes.yaml`, `platform/adopt.yaml` (à supprimer pour une
installation neuve), `apps/adopt/`, `infra_repository` dans
`.github/workflows/deploy.yml`, `uses:` dans `templates/app-deploy.yml`, et la
liste des images dans `.github/workflows/housekeeping.yml`.

## Version de Dokploy

Elle est figée dans `ansible/roles/dokploy/defaults/main.yml`
(`dokploy_version`). Pour mettre à jour : change la valeur, puis
`ansible-playbook ansible/playbooks/setup-manager.yml -e dokploy_allow_upgrade=true`. Le rôle utilise alors
l'updater officiel ; il ne réinstalle jamais.
