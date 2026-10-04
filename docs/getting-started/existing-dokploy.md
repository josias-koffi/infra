# Reprendre un Dokploy existant

Ce guide s'applique quand un Dokploy tourne déjà avec des apps en production.
Le principe : on **importe** dans le code ce qui existe, sans rien recréer.
Chaque étape commence par un `plan` qui ne doit montrer que des imports et des
mises à jour en place, jamais de `destroy` ni de `replace`.

Exemple réel, commandes comprises : [migration de VPS20](../case-studies/vps20-migration.md).

## 0. Filet de sécurité, avant tout

Pour chaque base : un dump frais copié hors du serveur, plus un comptage exact
des lignes par table, pour comparer après chaque étape. Archive aussi les
volumes de fichiers (uploads, MinIO) qui n'ont pas de sauvegarde hors du
serveur. La [migration de VPS20, §0](../case-studies/vps20-migration.md#0-safety-net)
donne le script.

## 1. Repo et configuration

Mêmes étapes 1 et 2 que l'[installation neuve](fresh-install.md#1-récupérer-le-repo),
à une différence près : `DOKPLOY_URL` et `DOKPLOY_API_KEY` existent déjà (clé
créée dans *Settings → Profile*).

## 2. Le serveur : jamais de réinstallation

Dans `ansible/roles/dokploy/defaults/main.yml`, mets `dokploy_version` à la
**version qui tourne** (`docker service inspect dokploy --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'`).
Puis :

```bash
make setup-manager CHECK=1   # le rôle dokploy doit afficher « running: vX — pinned: vX »
make setup-manager
```

Garanties du rôle :
- si un Dokploy tourne, il ne lance jamais l'installateur ;
- si les versions diffèrent, il s'arrête au lieu de mettre à jour, sauf avec
  `-e dokploy_allow_upgrade=true` ;
- si Swarm est actif sans service Dokploy, il s'arrête et demande une
  inspection manuelle.

Lis le diff du dry run : les rôles `base` et `docker` peuvent modifier la
config SSH ou le pare-feu s'ils diffèrent de l'existant.

## 3. Adopter l'instance (`platform/`)

Récupère les identifiants des enregistrements existants, en lecture seule.
Exemple dans la base Dokploy :

```bash
ssh root@<serveur> 'C=$(docker ps -q -f name=dokploy-postgres)
  docker exec $C psql -U dokploy -d dokploy -At -c "select \"destinationId\", name, bucket from destination"
  docker exec $C psql -U dokploy -d dokploy -At -c "select id from \"webServerSettings\""'
```

Reporte ces IDs dans `platform/adopt.yaml` :

```yaml
settings: <id des réglages>
destinations:
  production: <id destination prod>    # doit pointer sur R2_BACKUP_BUCKET_PROD
  staging: <id destination staging>
```

Puis `make platform-plan` doit montrer **uniquement** des imports (avec
éventuellement des mises à jour en place) et des créations (la sauvegarde de
Dokploy). Aligne la config sur l'existant tant qu'un changement non voulu
apparaît. Par exemple, `enable_docker_cleanup` doit refléter la valeur qui
tourne. Ensuite `make platform-apply`.

Si un autre state OpenTofu gérait déjà ces destinations (un ancien pipeline
d'app), retire-les d'abord de ce state, **sans détruire** :
`tofu state rm dokploy_destination.<nom>`.

## 4. Adopter les apps déjà dans Dokploy

Pour chaque app, staging d'abord :

1. **Relever les volumes réellement montés**, conteneur par conteneur :
   `docker inspect <conteneur> --format '{{range .Mounts}}{{.Name}} {{end}}'`.
   Ne te fie jamais au nom du projet ou du compose : à l'origine de ce repo,
   la prod de Jobspark tournait sous un compose nommé `cvspark-*` et montait
   des volumes `jobspark_*`.
2. **Écrire le manifest en mode `compose`**, qui reprend le stack tel quel
   ([exemple](../../examples/jobspark/.deploy/manifest.yaml)) :
   - `volumePrefix` = le préfixe exact relevé au point 1 ;
   - `externalVolumes: true` sur chaque environnement, obligatoire : sans ça,
     supprimer le compose supprime aussi ses volumes
     ([comportement vérifié](../reference/dokploy-behaviour.md)) ;
   - les variables d'env : compare **les noms** avec le `.env` du stack sur le
     serveur (`/etc/dokploy/compose/<appName>/code/.env`) ; il ne doit en
     manquer aucun.
3. **Écrire `apps/adopt/<app>.yaml`** avec les IDs du projet, des composes,
   des domaines et des sauvegardes ([exemple](../../apps/adopt/jobspark.yaml)).
   Si l'app avait deux projets (`app` et `app-staging`), garde le premier : le
   compose de staging va s'y **déplacer**.
4. **Libérer l'ancien state**, s'il y en avait un : `tofu state rm`, **jamais**
   `destroy`, et désactive l'ancien workflow de déploiement.
5. **Plan avec l'image qui tourne déjà**, pour ne livrer aucun nouveau code
   pendant le déplacement :
   `make app-plan MANIFEST=…/.deploy/manifest.yaml ENV=staging TAG=<tag en cours>`.
   Attendu : projet importé, environnement `staging` créé, compose importé et
   mis à jour en place (`environment_id`, env), domaines importés, sauvegardes
   créées ou importées. Aucun `destroy` ni `replace`.
6. **Apply** (`make app-deploy …`). Le déplacement ne redémarre rien ; un seul
   redéploiement a lieu, celui qui passe les volumes en `external`.
7. **Vérifier** : les domaines répondent, les mêmes volumes sont montés, les
   comptages de lignes sont identiques. Ensuite, branche
   `templates/app-deploy.yml` dans le repo de l'app et supprime le projet
   devenu vide dans le panel.

## 5. Les services qui tournent hors Dokploy

Pour un compose lancé à la main ou une app gérée par systemd :

- **Sans état** : écris un manifest en mode `services`, déploie sous un domaine
  temporaire, vérifie, arrête l'ancien service, puis bascule le domaine.
- **Avec état** :
  - les volumes de fichiers se remontent tels quels (`volumes:` d'une app,
    même nom de volume) ;
  - les bases passent par un dump suivi d'une restauration dans un service
    `databases:`, avec une fenêtre de maintenance ;
  - l'ancien volume reste comme rollback.

## 6. Passer en mode services (plus tard)

Le mode `compose` sert à faire entrer l'existant sans risque. Une fois stable,
découpe chaque stack en un service Dokploy par composant : la
[migration de VPS20, §3b](../case-studies/vps20-migration.md) décrit l'ordre
(sans état, puis volumes, puis cache, puis base).
