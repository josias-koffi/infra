# Prérequis

Ce qu'il faut avant une [installation neuve](fresh-install.md) ou une
[adoption d'un Dokploy existant](existing-dokploy.md).

## Comptes et services

| Besoin | Pourquoi | Notes |
|---|---|---|
| Un serveur Linux | Il héberge le panel Dokploy et les apps | Ubuntu 22.04 ou 24.04, au moins 2 vCPU et 4 Go de RAM (Dokploy seul en prend environ 1 Go), accès `root` par clé SSH. Testé sur un VPS Contabo de 6 vCPU et 11 Go. |
| Un domaine géré par Cloudflare | DNS du panel et des apps | Le module DNS crée des enregistrements A non proxifiés, pour que Let's Encrypt fonctionne sur le Traefik de Dokploy. |
| Cloudflare R2 | States OpenTofu et sauvegardes | Il faut trois buckets, décrits plus bas. R2 n'a pas de frais de sortie, et le palier gratuit couvre 10 Go. |
| Un compte GitHub | CI, registre d'images (GHCR) | Le workflow de déploiement réutilisable est appelé par les repos d'apps. |

### Buckets R2

Crée-les dans *Cloudflare → R2 Object Storage → Create bucket* :

| Bucket (exemple) | Contenu | Variable `.env` |
|---|---|---|
| `myinfra-tofu-state` | states OpenTofu (`platform/…`, `apps/<app>/…`) | `TF_STATE_BUCKET` |
| `myinfra-backups` | sauvegardes de **production**, plus celles de Dokploy | `R2_BACKUP_BUCKET_PROD` |
| `myinfra-backups-staging` | sauvegardes de **staging** | `R2_BACKUP_BUCKET_STAGING` |

Ensuite, dans *R2 → Manage API tokens → Create API token*, crée **trois
tokens** avec la permission *Object Read & Write*, chacun limité à **un seul
bucket**. Ainsi, un token de staging ne peut jamais lire ni effacer une
sauvegarde de production.

- Token du bucket de state → `R2_ACCESS_KEY_ID` et `R2_SECRET_ACCESS_KEY`
- Token du bucket de prod → `R2_BACKUP_PROD_ACCESS_KEY_ID` et `R2_BACKUP_PROD_SECRET_ACCESS_KEY`
- Token du bucket de staging → `R2_BACKUP_STAGING_ACCESS_KEY_ID` et `R2_BACKUP_STAGING_SECRET_ACCESS_KEY`

Cloudflare n'affiche le *Secret Access Key* qu'une seule fois. L'endpoint
(`R2_ENDPOINT`) se trouve sur la page *R2 → Overview*, dans le panneau
*Account Details*, ligne *S3 API* : `https://<account_id>.r2.cloudflarestorage.com`,
sans nom de bucket à la fin.

Optionnel : activer un *bucket lock* de 30 jours sur les buckets de
sauvegarde, pour qu'une sauvegarde ne puisse pas être effacée avant ce délai.
La rétention par défaut (35 jours en prod) est réglée pour rester au-dessus de
ce lock.

## Outils sur ton poste

| Outil | Version | Installation |
|---|---|---|
| OpenTofu | ≥ 1.11 (testé avec 1.12) | <https://opentofu.org/docs/intro/install/> |
| Ansible | ansible-core ≥ 2.15 | `pipx install ansible-core`, puis `ansible-galaxy collection install ansible.posix community.general` |
| Python 3 | avec `pyyaml` et `jsonschema` | `pip install pyyaml jsonschema` |
| GitHub CLI | `gh`, connecté | `gh auth login` |
| GNU make, curl, ssh | | en général déjà présents |

Vérification :

```bash
tofu version && ansible --version | head -1 && gh auth status && python3 -c "import yaml, jsonschema"
```
