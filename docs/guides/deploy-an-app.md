# Déployer une app

Une app décrit ce qu'elle exécute dans **un seul fichier**,
`.deploy/manifest.yaml`, placé dans son propre repo. Tout le reste (projet
Dokploy, environnements, services, domaines, sauvegardes, DNS, smoke tests)
est généré à partir de ce fichier.

## 1. Le manifest

Pars de [`examples/sample-services/.deploy/manifest.yaml`](../../examples/sample-services/.deploy/manifest.yaml) :

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/josias-koffi/infra/main/schema/manifest.v1.json
apiVersion: deploy/v1
name: sample                     # = nom du projet Dokploy
server: vps20                    # clé de platform/nodes.yaml
secrets: [DB_PASSWORD, CACHE_PASSWORD, SESSION_SECRET]

apps:
  web: { image: ghcr.io/me/sample-web, port: 3000, domain: web, uses: [api], resources: { cpus: 0.5, memory: 512m } }
  api:
    image: ghcr.io/me/sample-api
    port: 8080
    domain: api
    healthcheck: /health         # vérifié par le smoke test
    uses: [db, cache]            # injecte DATABASE_URL, REDIS_URL…
    volumes: { uploads: /app/uploads }
workers:
  jobs: { image: ghcr.io/me/sample-api, command: node, args: [dist/worker.js], uses: [db, cache] }
databases:
  db: { type: postgres, version: 16-alpine, database: sample, user: sample }
caches:
  cache: { type: redis }

environments:
  production: { branch: main,    domains: { web: sample.example.com, api: api.example.com } }
  staging:    { branch: develop, domains: { web: sample-staging.example.com, api: api-staging.example.com } }
```

Valide-le localement :

```bash
<chemin>/infra/scripts/validate-manifest.py .deploy/manifest.yaml
```

Toutes les clés sont décrites dans la [référence du manifest](../reference/manifest.md).

## 2. Le workflow

Copie [`templates/app-deploy.yml`](../../templates/app-deploy.yml) dans
`.github/workflows/deploy.yml`, puis remplace `CHANGE-ME` par le nom de ton
image (ajoute une étape `build-push` par image s'il y en a plusieurs).

Ce workflow ne contient **aucune règle**. Il enchaîne trois jobs :

1. **`resolve`** (workflow réutilisable de ce repo) lit le manifest et décide
   si cet événement déploie, vers quel environnement, et avec quel tag ;
2. **`build`** construit et pousse l'image, seulement si `resolve` le demande
   (pas de build quand on redéploie un tag existant) ;
3. **`deploy`** (workflow réutilisable) déploie.

Tu peux ajouter tes propres jobs entre `build` et `deploy`, par exemple un
démarrage de l'image contre une base jetable :
[exemple dans jemima-portfolio](https://github.com/josias-koffi/jemima-portfolio/blob/develop/.github/workflows/deploy-platform.yml).

Le tag d'image est le SHA court du commit, et le manifest l'ajoute
automatiquement aux images déclarées sans tag explicite. Si l'image est
privée, déclare `registry: ghcr` sur le composant ; le registre est créé par
`platform/` quand `GHCR_TOKEN` est renseigné.

## 3. Secrets et variables du repo de l'app

*Settings → Secrets and variables → Actions*, au niveau du repo :

| Type | Nom | Valeur |
|---|---|---|
| Variable | `DOKPLOY_URL` | URL du panel |
| Variable | `TF_STATE_BUCKET` | bucket R2 des states |
| Secret | `DOKPLOY_API_KEY` | clé API Dokploy |
| Secret | `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | token du bucket de state |
| Secret | `CF_API_TOKEN`, `CF_ZONE_ID` | seulement avec `dns: cloudflare` (le défaut) ; token *Zone → DNS → Edit* |

Raccourci : `scripts/set-secrets.sh --app <owner>/<app>` pousse ces variables
et secrets depuis le `.env` d'infra.

*Settings → Environments* : crée `staging` et `production`. Dans **chacun**,
ajoute les secrets listés par le manifest (`secrets:` et `optionalSecrets:`),
avec des valeurs différentes par environnement.

Raccourci, depuis le repo de l'app :

```bash
<chemin>/infra/scripts/init-app-env.sh            # ou -R owner/app -e staging
```

Il crée les environnements du manifest et demande chaque secret manquant :
Entrée en génère un aléatoire pour les mots de passe, clés et tokens, les
autres (email, utilisateur) sont à saisir. Il ne réécrit jamais un secret
déjà posé : relancé, il ne complète que ce qui manque. Chaque base et chaque cache
attend un secret `<CLÉ>_PASSWORD` (par exemple `DB_PASSWORD`), sauf si
`passwordSecret` dit autre chose.

Astuce : protège l'environnement `production` avec un reviewer obligatoire.
Chaque déploiement en prod attendra alors une validation.

## 4. Déployer

Les règles de déclenchement vivent **dans le manifest** :

```yaml
environments:
  staging:    { branch: develop }                  # deploy: auto (défaut) : chaque push sur develop déploie
  production: { branch: main, deploy: manual }     # un push sur main ne déploie jamais
```

| Événement | Effet |
|---|---|
| push sur la `branch` d'un environnement en `deploy: auto` | build, puis déploiement de cet environnement |
| push sur la `branch` d'un environnement en `deploy: manual` | rien (le run s'arrête après `resolve` avec une notice) |
| push sur une autre branche | rien |
| *Actions → Deploy → Run workflow*, lancé **depuis la branche de l'environnement** | déploiement de cet environnement (`environment` vide = celui de la branche) |
| idem avec `image_tag` | redéploie un tag existant : **promotion** du tag validé en staging, ou **rollback** |
| idem avec `plan_only` | affiche le plan sans rien appliquer |

Un lancement manuel vers un environnement depuis une autre branche que la
sienne est refusé. Pour une protection de plus, ajoute dans GitHub une règle
de branche sur l'environnement `production` et un reviewer obligatoire.

Mettre en prod ce qui tourne en staging : merge `develop` → `main`, puis
*Run workflow* sur `main` avec `image_tag` = le tag du staging.

Déroulement du job `deploy` (`scripts/deploy-app.sh`) :

1. validation du manifest (schéma et cohérence) ;
2. vérification du DNS (`scripts/check-dns.py`, avec `dns: cloudflare`) : voir [DNS](#dns) ;
3. `apps/project` : projet et environnements ;
4. `apps/env` : plan de l'environnement visé (state séparé : un apply de
   staging ne touche jamais la prod) ;
5. **garde-fous** : le plan est refusé s'il supprime une base, un cache, un
   compose ou un montage, ou s'il change un secret verrouillé (voir
   [Secrets verrouillés](#secrets-verrouillés)) ;
6. apply ;
7. smoke test : chaque domaine doit répondre, et chaque `healthcheck` doit
   renvoyer un 2xx (jusqu'à 5 minutes d'attente).

Pour planifier depuis ton poste, sans rien appliquer :

```bash
cd <chemin>/infra
make app-plan MANIFEST=../mon-app/.deploy/manifest.yaml ENV=staging
```

## DNS

Avec `dns: cloudflare` (le défaut), il suffit d'écrire le domaine dans
`environments.<env>.domains` : le déploiement crée un enregistrement A vers
l'IP du serveur, non proxifié (challenge HTTP de Let's Encrypt), et le
supprime quand le domaine disparaît du manifest.

**Un enregistrement n'a qu'un propriétaire.** Avant le plan,
`scripts/check-dns.py` refuse le déploiement si :

- un domaine n'appartient pas à la zone `CF_ZONE_ID` ;
- un enregistrement A, AAAA ou CNAME existe déjà sur ce nom sans avoir été
  créé par `apps/env` (commentaire `<app> <env> — infra apps/env`) ni déclaré
  dans `apps/adopt/<app>.yaml`. Sans ce contrôle, l'apply ajouterait un
  second enregistrement à côté de celui d'un autre state.

Reprendre un enregistrement géré ailleurs (autre OpenTofu, console) :

1. noter son id (`tofu state show <ressource>` dans l'autre state, ou l'API
   Cloudflare) ;
2. le retirer de l'autre state (`tofu state rm <ressource>`) et supprimer son
   bloc, sans `apply` qui le détruirait ;
3. le déclarer pour l'import :

   ```yaml
   # apps/adopt/<app>.yaml
   environments:
     production:
       dnsRecords: { web: <id> }    # clé de environments.production.domains
   ```

4. déployer l'environnement : l'enregistrement est importé, puis aligné sur
   le manifest (IP du serveur, non proxifié) ;
5. supprimer l'entrée `dnsRecords` du fichier d'adoption.

`dns: external` désactive tout cela, pour une app dont les enregistrements
restent gérés ailleurs.

## Secrets verrouillés

Une base ne lit son mot de passe qu'à la création de son volume. Changer
`DB_PASSWORD` ensuite met à jour la variable du service, pas le rôle : les
apps ne peuvent plus se connecter. Il en va de même pour un secret qui signe
ou chiffre des données stockées (`PAYLOAD_SECRET`, une clé de chiffrement…).

Sont donc verrouillés :

- le mot de passe de chaque base et de chaque cache (`passwordSecret`, par
  défaut `<CLÉ>_PASSWORD`) et le mot de passe root de mysql/mariadb, dans les
  deux modes ;
- chaque nom listé dans `lockedSecrets` :

  ```yaml
  secrets: [DB_PASSWORD, PAYLOAD_SECRET, ADMIN_PASSWORD]
  lockedSecrets: [PAYLOAD_SECRET]
  ```

Au premier déploiement, l'empreinte SHA-256 de chacun est gardée dans le
state. Un déploiement dont le plan change une empreinte est refusé avant
l'apply : remets l'ancienne valeur dans l'environnement GitHub. Un secret
optionnel encore vide peut toujours être renseigné une première fois.

Ne verrouille que des valeurs longues et aléatoires : l'empreinte est lisible
dans le state.

Rotation volontaire, depuis ton poste :

1. change le mot de passe dans le service lui-même, par exemple
   `ALTER ROLE <user> WITH PASSWORD '…'` dans le conteneur Postgres ;
2. mets la nouvelle valeur dans l'environnement GitHub ;
3. déploie en levant le verrou pour ce nom seulement :

   ```bash
   ALLOW_SECRET_CHANGE=DB_PASSWORD make app-deploy MANIFEST=… ENV=staging TAG=<sha>
   ```

## 5. Faire évoluer l'app

| Besoin | Dans le manifest |
|---|---|
| Plus de mémoire en prod seulement | `environments.production.overrides.apps.api.resources.memory: 2g` |
| Une variable de config | `vars:` (commune à tous les environnements) ou `environments.<env>.vars:` |
| Une valeur qui contient un secret | `DATABASE_URL: 'postgres://u:${secrets.DB_PASSWORD}@…'` |
| Un nouvel environnement | une entrée de plus sous `environments:` (avec ses domaines et sa branche) |
| Un service de plus | une entrée sous `apps:`, `workers:`, `databases:` ou `caches:` |
| Retirer un service sans état | supprimer l'entrée |
| Retirer une base ou un environnement | le déploiement refuse ; passe par la [purge](purge.md) |
