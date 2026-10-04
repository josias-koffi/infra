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
`.github/workflows/deploy.yml`, puis place le build de tes images avant le job
`deploy`. Exemple de build :

```yaml
jobs:
  build:
    if: inputs.image_tag == ''
    runs-on: ubuntu-latest
    outputs:
      tag: ${{ steps.t.outputs.tag }}
    steps:
      - uses: actions/checkout@v4
      - id: t
        run: echo "tag=${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"
      - uses: docker/login-action@v3
        with: { registry: ghcr.io, username: "${{ github.actor }}", password: "${{ secrets.GITHUB_TOKEN }}" }
      - uses: docker/build-push-action@v6
        with:
          push: true
          tags: ghcr.io/${{ github.repository_owner }}/sample-api:${{ steps.t.outputs.tag }}

  deploy:
    needs: build
    if: ${{ !failure() && !cancelled() }}
    uses: josias-koffi/infra/.github/workflows/deploy.yml@main
    with:
      environment: ${{ inputs.environment }}
      image_tag: ${{ inputs.image_tag || needs.build.outputs.tag }}
    secrets: inherit
```

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

*Settings → Environments* : crée `staging` et `production`. Dans **chacun**,
ajoute les secrets listés par le manifest (`secrets:` et `optionalSecrets:`),
avec des valeurs différentes par environnement. Chaque base et chaque cache
attend un secret `<CLÉ>_PASSWORD` (par exemple `DB_PASSWORD`), sauf si
`passwordSecret` dit autre chose.

Astuce : protège l'environnement `production` avec un reviewer obligatoire.
Chaque déploiement en prod attendra alors une validation.

## 4. Déployer

| Action | Effet |
|---|---|
| push sur `develop` | build, puis déploiement en **staging** |
| merge sur `main` | build, puis déploiement en **production** |
| *Run workflow* avec `environment` et `image_tag` | redéploie un tag existant : c'est le **rollback** |

Déroulement d'un déploiement (`scripts/deploy-app.sh`) :

1. validation du manifest (schéma et cohérence) ;
2. `apps/project` : projet et environnements ;
3. `apps/env` : plan de l'environnement visé (state séparé : un apply de
   staging ne touche jamais la prod) ;
4. **garde-fou** : le plan est refusé s'il supprime une base, un cache, un
   compose ou un montage ;
5. apply ;
6. smoke test : chaque domaine doit répondre, et chaque `healthcheck` doit
   renvoyer un 2xx (jusqu'à 5 minutes d'attente).

Pour planifier depuis ton poste, sans rien appliquer :

```bash
cd <chemin>/infra
make app-plan MANIFEST=../mon-app/.deploy/manifest.yaml ENV=staging
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
