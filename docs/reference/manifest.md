# Référence du manifest (`.deploy/manifest.yaml`)

Schéma : [`schema/manifest.v1.json`](../../schema/manifest.v1.json).
Validation : `scripts/validate-manifest.py <fichier>`, qui contrôle le schéma
puis la cohérence (`uses` connus, domaines présents dans chaque
environnement, secrets de mot de passe déclarés…).

Complétion dans l'éditeur, en première ligne :
`# yaml-language-server: $schema=https://raw.githubusercontent.com/josias-koffi/infra/main/schema/manifest.v1.json`

## Racine

| Clé | Type | Défaut | Rôle |
|---|---|---|---|
| `apiVersion` | `deploy/v1` | requis | version du format |
| `name` | `[a-z][a-z0-9-]{1,30}` | requis | nom du projet Dokploy ; préfixe des services et des chemins R2 |
| `description` | string | | description du projet |
| `server` | string | `vps20` | clé de `platform/nodes.yaml` |
| `mode` | `services` \| `compose` | `services` | un service Dokploy par composant, ou un seul compose (mode legacy, pour l'existant) |
| `dns` | `cloudflare` \| `external` | `cloudflare` | crée les enregistrements A des domaines, en refusant d'écraser ceux d'un autre propriétaire ([DNS](../guides/deploy-an-app.md#dns)) ; `external` : tu les gères ailleurs |
| `secrets` | liste de noms | | secrets **obligatoires**, lus dans l'environnement GitHub |
| `optionalSecrets` | liste de noms | | secrets valant `""` s'ils sont absents |
| `lockedSecrets` | liste de noms | | secrets qui ne peuvent plus changer une fois posés ; les mots de passe des bases et caches le sont toujours ([secrets verrouillés](../guides/deploy-an-app.md#secrets-verrouillés)) |
| `vars` | map | | configuration commune à tous les environnements (voir *Templates*) |
| `apps`, `workers` | map de *composants* | | mode services |
| `databases` | map | | bases de données |
| `caches` | map | | Redis |
| `compose` | objet | | mode compose |
| `backups` | objet | activées | voir [sauvegardes](../guides/backups-and-restore.md) |
| `environments` | map | requis | un environnement Dokploy par clé |

## Composant (`apps.<nom>`, `workers.<nom>`)

| Clé | Rôle |
|---|---|
| `image` | image sans tag, à laquelle on ajoute le tag déployé (SHA court) ; une image avec `:tag` est utilisée telle quelle |
| `tag` | tag fixe, à la place du tag déployé |
| `registry` | nom d'un registre de `platform/` (`ghcr`) pour une image privée |
| `port` | port du conteneur derrière le domaine (apps) |
| `domain` / `domains` | clé(s) de `environments.<env>.domains` (apps uniquement) |
| `path` | chemin du domaine |
| `paths` | plusieurs préfixes du domaine, une règle Traefik chacun (à la place de `path`) : une API servie sous `/trpc` et `/api/auth` du domaine du site. Le préfixe est transmis tel quel au conteneur |
| `healthcheck` | chemin qui doit renvoyer 2xx au smoke test |
| `command`, `args` | commande du conteneur |
| `replicas` | nombre de réplicas |
| `uses` | composants dont il reçoit les coordonnées (voir plus bas) |
| `volumes` | `{ nom: /chemin }` : volume Docker `<volumePrefix>_<nom>`, sauvegardé |
| `vars` | variables propres à ce composant (templates acceptés) |
| `secrets` | restreint les secrets reçus à cette liste (par défaut : tous) |
| `resources` | `{ cpus: 0.5, memory: 512m }` : limites strictes |

### Ce que `uses` injecte

| Cible | Variables |
|---|---|
| une base (`databases.db`) | `DATABASE_HOST`, `_PORT`, `_NAME`, `_USER`, `_PASSWORD`, `_URL` (préfixe modifiable avec `envPrefix`) |
| un cache (`caches.cache`) | `REDIS_HOST`, `_PORT`, `_PASSWORD`, `_URL` |
| une autre app ou un worker | `<APP>_URL=https://<son domaine>` (s'il en a un) et `<APP>_INTERNAL_URL=http://<app>-<env>-<composant>:<port>` (s'il a un `port`) : alias stable sur `dokploy-network`, pour les appels côté serveur sans repasser par Traefik ni exposer de route |

L'hôte d'une base est son `app_name` Dokploy, unique grâce à un suffixe
aléatoire : le staging et la prod ne se mélangent jamais sur le réseau
partagé `dokploy-network`.

## Bases et caches

```yaml
databases:
  db:
    type: postgres            # postgres | mysql | mariadb | mongo
    version: 16-alpine        # tag de l'image officielle
    database: app
    user: app
    passwordSecret: DB_PASSWORD   # défaut : <CLÉ>_PASSWORD
    rootPasswordSecret: …         # mysql/mariadb, défaut : <CLÉ>_ROOT_PASSWORD
    envPrefix: DATABASE           # préfixe des variables injectées
    resources: { memory: 1g }
    service: postgres             # mode compose seulement : le service qui porte la base
caches:
  cache: { type: redis, version: 7-alpine, passwordSecret: CACHE_PASSWORD }
```

## Mode compose

```yaml
mode: compose
compose:
  file: infra/compose/stack.yml       # relatif à la racine du repo de l'app
  name: mon-compose                    # défaut : <name> en prod, <name>-<env> ailleurs
  routes:                              # domaines → services du compose
    web: { service: web, port: 3000, domain: site }   # domain : clé de environments.<env>.domains (défaut : la clé de la route)
  resources: { api: { cpus: 1, memory: 1g } }         # injectées dans deploy.resources.limits
  backupVolumes:
    - { volume: uploads, service: api, prefix: { production: uploads/production/ } }
databases:
  postgres: { type: postgres, service: postgres, database: app, user: app }
```

En mode compose, **chaque environnement doit avoir `externalVolumes: true`**
(le validateur le vérifie) : Dokploy supprime les volumes non externes d'un
compose supprimé. Les volumes du fichier doivent être nommés
`${VOLUME_PREFIX}_<nom>`.

## Environnements

```yaml
environments:
  production:
    branch: main                       # branche de cet environnement
    deploy: manual                     # auto (défaut) : un push sur la branche déploie ; manual : seulement un lancement manuel
    volumePrefix: myapp                # défaut : <name>-<env>
    externalVolumes: true              # mode compose
    domains: { web: app.example.com, api: api.example.com }
    vars: { LOG_LEVEL: info }
    overrides:                         # fusion sur deux niveaux : composant, puis resources
      apps: { api: { replicas: 2, resources: { memory: 2g } } }
```

Un même hôte ne peut appartenir qu'à un seul environnement (le validateur le
vérifie) : chacun possède ses enregistrements DNS.

Le workflow de l'app ne contient aucune règle de déclenchement : le job
`resolve` applique `branch` et `deploy` (voir [déployer une app](../guides/deploy-an-app.md#4-déployer)).

Un environnement nommé `production` utilise l'environnement par défaut du
projet Dokploy et le bucket de sauvegarde de prod. Tous les autres sont créés
dans le projet et utilisent le bucket de staging.

## Variables reçues par chaque service

Dans cet ordre :

1. `APP_ENV`, `IMAGE_TAG`, `APP_VERSION` (= tag déployé), `VOLUME_PREFIX` ;
2. `<CLÉ>_DOMAIN` pour chaque domaine de l'environnement (`api` donne `API_DOMAIN`) ;
3. `vars` du manifest, puis `vars` de l'environnement ;
4. variables de `uses`, puis `vars` du composant ;
5. secrets.

### Templates dans `vars`

Les valeurs de `vars` sont des templates évalués au déploiement :

| Expression | Valeur |
|---|---|
| `${secrets.NOM}` | un secret |
| `${domains.api}` | un domaine de l'environnement |
| `${env}`, `${app}`, `${volume_prefix}` | environnement, nom, préfixe des volumes |
| `${compose_sha}` | 12 caractères du hash du fichier compose, pour forcer une recréation |
| `${env == "production" ? "a" : "b"}` | expression conditionnelle |

Une valeur contenant `: ` ou des guillemets doit être entourée d'apostrophes
YAML. Un `${` littéral s'écrit `$${`.
