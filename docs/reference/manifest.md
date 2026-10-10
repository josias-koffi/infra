# Référence du manifest (`.deploy/manifest.yaml`)

Schéma : [`schema/manifest.v1.json`](../../schema/manifest.v1.json).
Validation : `scripts/validate-manifest.py <fichier>`, qui contrôle le schéma
puis la cohérence (`uses` connus, domaines présents dans chaque
environnement, secrets générés non saisis, noms réservés…).

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
| `secrets` | liste de noms | | secrets **obligatoires** qu'un humain fournit, lus dans l'environnement GitHub `<app>-<env>` du repo infra |
| `optionalSecrets` | liste de noms | | secrets valant `""` s'ils sont absents |
| `generate` | liste de noms, ou `{ NOM: { length, special } }` | | secrets **créés par infra** une fois, gardés dans le state de l'environnement (voir [Secrets générés](#secrets-générés)) |
| `lockedSecrets` | liste de noms | | secrets qui ne peuvent plus changer une fois posés ; les mots de passe des bases et caches le sont toujours ([secrets verrouillés](../guides/deploy-an-app.md#secrets-verrouillés)) |
| `vars` | map | | configuration commune à tous les environnements (voir *Templates*) |
| `apps`, `workers` | map de *composants* | | mode services |
| `databases` | map | | bases de données |
| `caches` | map | | Redis |
| `buckets` | map | | stockage objet R2 créé par infra (voir [Buckets](#buckets)) |
| `mail` | objet | | envoi de mails par Resend, clé créée par infra (voir [Mail](#mail)) |
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
| `mail` | `RESEND_API_KEY`, `MAIL_DOMAIN`, et pour les apps SMTP `SMTP_HOST=smtp.resend.com`, `SMTP_PORT=587`, `SMTP_USER=resend`, `SMTP_PASSWORD` |
| un bucket (`buckets.medias`) | `S3_ENDPOINT`, `S3_BUCKET`, `S3_REGION=auto`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_FORCE_PATH_STYLE=true` (préfixe modifiable avec `envPrefix`) |
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
    passwordSecret: DB_PASSWORD   # défaut : <CLÉ>_PASSWORD ; généré s'il n'est pas dans secrets
    rootPasswordSecret: …         # mysql/mariadb, défaut : <CLÉ>_ROOT_PASSWORD
    envPrefix: DATABASE           # préfixe des variables injectées
    resources: { memory: 1g }
    service: postgres             # mode compose seulement : le service qui porte la base
caches:
  cache: { type: redis, version: 7-alpine, passwordSecret: CACHE_PASSWORD }
```

## Buckets

```yaml
buckets:
  medias: {}                                   # tous les défauts
  exports: { jurisdiction: default, envPrefix: EXPORTS }
apps:
  api: { uses: [medias], … }
```

| Clé | Défaut | Rôle |
|---|---|---|
| `backend` | `r2` | seul backend pour l'instant |
| `name` | `<name>-<env>-<clé>` | nom du bucket ; un nom fixe n'est accepté qu'avec un seul environnement (ou dans `environments.<env>.overrides.buckets`) |
| `jurisdiction` | `eu` | `eu` : les objets restent dans l'UE (RGPD). Ne change plus une fois le bucket créé |
| `envPrefix` | `S3` | préfixe des variables injectées |

Au déploiement, infra crée le bucket et un token Cloudflare qui ne peut lire
et écrire **que ce bucket** ; la clé S3 est l'id du token, le secret le
SHA-256 de sa valeur (convention R2). Rien n'est à saisir. Un composant les
reçoit avec `uses`, un compose (mode legacy) les reçoit tous ; un template les
lit avec `${addons.medias.S3_BUCKET}`.

Le déploiement refuse un plan qui supprime un bucket (comme une base). Un
bucket créé à la main se reprend avec
`apps/adopt/<app>.yaml` → `environments.<env>.buckets.<clé>: <nom>` ; sa
juridiction doit être celle du manifest.

## Mail

```yaml
mail: {}                       # domaine : la zone du premier domaine de l'environnement
# mail: { domain: ouiti.com }  # explicite (obligatoire avec dns: external)
apps:
  api: { uses: [mail], … }
```

Chaque environnement reçoit **sa propre clé Resend**, qui ne peut
qu'envoyer, et seulement depuis ce domaine. Rien à saisir.

Le domaine d'envoi est partagé entre apps et environnements : il se déclare
une fois dans [`zones/zones.yaml`](../../zones/zones.yaml) (`mail:`), et la
pile `zones/` le crée chez Resend (région `eu-west-1` par défaut), pose les
enregistrements DKIM, SPF et DMARC dans sa zone Cloudflare et demande la
vérification. Un enregistrement qu'un autre propriétaire tient déjà n'est
jamais doublé : il est laissé en place et listé. Un domaine déjà créé chez
Resend s'adopte avec `resendId`.

RGPD : `eu-west-1` envoie depuis l'Irlande, mais Resend garde les données du
compte (journaux, métadonnées) aux États-Unis.

## Secrets générés

Rien à saisir pour ce qu'une machine peut inventer :

```yaml
secrets: [ADMIN_EMAIL]          # seulement ce qu'un humain doit fournir
generate: [SESSION_SECRET]      # ou { SESSION_SECRET: { length: 64, special: false } }
lockedSecrets: [SESSION_SECRET]
databases:
  db: { type: postgres, database: app, user: app }   # DB_PASSWORD généré
```

- `generate` : chaque nom reçoit une valeur aléatoire (32 lettres et chiffres
  par défaut), créée au premier déploiement et stable ensuite. Elle est
  injectée comme un secret saisi, et utilisable dans les templates
  (`${secrets.SESSION_SECRET}`).
- **Mots de passe des bases et caches** : générés sans rien écrire, tant
  que leur nom (`<CLÉ>_PASSWORD`, `passwordSecret`…) n'est pas dans
  `secrets`. Seuls les composants qui `use` la base les reçoivent
  (`DATABASE_PASSWORD`, `DATABASE_URL`…).
- **Une valeur saisie gagne toujours** : si l'environnement GitHub contient
  déjà le nom, c'est elle qui sert. Les apps existantes gardent donc leurs
  mots de passe.
- Les valeurs générées sont verrouillées comme les autres : si une valeur
  saisie disparaît et que la valeur générée diffère, le déploiement s'arrête
  ([secrets verrouillés](../guides/deploy-an-app.md#secrets-verrouillés)).
- Mode compose (legacy) : `generate` marche aussi, les valeurs arrivent dans
  l'env du compose (`generate: [POSTGRES_PASSWORD]`).

Un nom ne peut pas être à la fois dans `generate` et dans `secrets`. Les noms
des accès plateforme (`CF_API_TOKEN`, `DOKPLOY_API_KEY`…) sont refusés.

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
    emailRouting:                      # redirection d'adresses (Cloudflare Email Routing)
      contact@example.com: moi@gmail.com
      commandes@example.com: [moi@gmail.com, resto@gmail.com]
```

Un même hôte ne peut appartenir qu'à un seul environnement (le validateur le
vérifie) : chacun possède ses enregistrements DNS. Il en va de même pour une
adresse de `emailRouting`.

### Redirection d'adresses (`emailRouting`)

Chaque ligne fait suivre une adresse d'une zone du compte vers une ou
plusieurs boîtes, gratuitement (Cloudflare Email Routing) :

- `zones/` active Email Routing sur chaque zone du compte qui n'a pas déjà son
  propre service mail à l'apex (un MX ou un SPF étranger : Google Workspace…).
  Ces zones sont listées dans sa sortie `email_routing_skipped` et le
  déploiement refuse d'y créer une règle ;
- les boîtes de destination sont enregistrées au déploiement. **Une seule
  action à la main, une fois par boîte** : cliquer le lien de confirmation que
  Cloudflare y envoie. D'ici là, le déploiement prévient sans échouer ;
- retirer une ligne supprime la règle ; la boîte reste enregistrée (elle peut
  servir à d'autres apps).

Compatible avec `mail` : Resend utilise le MX de `send.<domaine>`, pas celui
de l'apex.

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
