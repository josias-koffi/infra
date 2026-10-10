# Architecture

## Vue d'ensemble

```
            ton poste / GitHub Actions
                       │  OpenTofu (provider vanillauys/dokploy) + Ansible
                       ▼
 ┌──────────────── serveur « manager » ─────────────────┐      ┌── serveur distant ──┐
 │  Dokploy (panel, API) ── Docker Swarm ── Traefik     │ SSH  │  Traefik            │
 │   projet A : env production │ env staging           │─────▶│  services des apps  │
 │     app · worker · postgres · redis · volumes        │      │  avec server: node2 │
 └──────────────────────────────────────────────────────┘      └─────────────────────┘
          │ sauvegardes quotidiennes            ▲ states OpenTofu
          ▼                                     │
   Cloudflare R2 : bucket de prod, bucket de staging, bucket de state
```

## Qui possède quoi

| Couche | Code | State |
|---|---|---|
| Serveurs (OS, Docker, Dokploy, purge) | `ansible/` | aucun : rôles idempotents |
| Instance Dokploy (réglages, destinations de sauvegarde, auto-sauvegarde, registre, serveurs distants) | `platform/` | `platform/dokploy.tfstate` |
| Projet d'une app et ses environnements | `apps/project` | `apps/<app>/project.tfstate` |
| Un environnement d'une app (services, domaines, montages, sauvegardes, DNS) | `apps/env` + `modules/dokploy-app` | `apps/<app>/<env>.tfstate` |

Un state par environnement : un apply de staging ne peut ni lire ni modifier
la prod. `apps/env` lit `platform` (destinations, serveurs) et `apps/project`
(ID de l'environnement) en lecture seule, via `terraform_remote_state`.

**Le repo de l'app ne contient que son manifest.** Le moteur (roots, module,
script, schéma) et tous les accès (Dokploy, R2, Cloudflare, Resend) vivent
ici : le déploiement tourne dans ce repo (`deploy-app.yml`), l'app ne fait
que le déclencher avec `INFRA_DEPLOY_TOKEN`.

| Ressource | Root | State |
|---|---|---|
| Domaines d'envoi Resend, activation d'Email Routing par zone | `zones` | `zones/zones.tfstate` |

## Un déploiement, pas à pas

```
push / run ─▶ resolve.yml (réutilisable) : manifest → déployer ? où ? quel tag ?
           │     (environments.<env>.branch, deploy: auto|manual)
           ├▶ build des images (repo de l'app, tag = SHA court), si demandé
           └▶ dispatch-deploy.yml (réutilisable) ─▶ deploy-app.yml (ce repo, ses secrets)
                  1. resolve      : environnement reçu, commit sur la branche de l'env
                  2. checkout     : repo de l'app (au commit) + ce repo
                  3. validate     : schéma + cohérence + noms réservés
                  4. DNS          : zone de chaque domaine, enregistrements étrangers refusés
                  5. apps/project : projet + environnements
                  6. apps/env     : plan  ── garde-fou : refuse toute suppression
                                              de base / cache / compose / montage / bucket,
                                              et tout changement de secret verrouillé
                  7.              : apply (secrets générés, bucket R2, clé Resend, règles mail)
                  8. smoke test   : domaines, puis healthchecks en 2xx
              le run de l'app suit celui d'infra et prend son statut
```

## Conventions de nommage

| Objet | Nom |
|---|---|
| Projet Dokploy | `name` du manifest |
| Service Dokploy (app, base…) | préfixe `<app>-<env>-<composant>` + suffixe aléatoire de Dokploy |
| Volume nommé | `<volumePrefix>_<volume>`, avec `volumePrefix` qui vaut par défaut `<app>-<env>` |
| Sauvegarde de base | `<bucket env>/db/<app>/<env>/<base>/` |
| Sauvegarde de volume | `<bucket env>/volumes/<app>/<env>/<volume>/` |
| Sauvegarde de Dokploy | `<bucket prod>/dokploy/` |

## Garde-fous

- **Le manifest est validé** avant tout plan : schéma, références, secrets de
  mot de passe déclarés.
- **Aucune suppression implicite d'état** : `deploy-app.sh` refuse un plan qui
  détruit une base, un cache, un compose ou un montage.
- **Volumes externes en mode compose** : un mauvais préfixe fait échouer le
  déploiement au lieu de démarrer sur un volume vide, et supprimer le compose
  ne supprime pas les données.
- **Pas de réinstallation de Dokploy** : le rôle Ansible détecte le panel et
  refuse toute dérive de version non demandée.
- **Purge protégée** : environnement GitHub avec reviewer, confirmation tapée,
  dry run par défaut, archivage des volumes avant toute destruction.
- **Destinations testées** : Dokploy vérifie l'accès au bucket avant
  d'enregistrer un token.
- **Secrets hors du state quand c'est possible** : les tokens R2 des
  destinations, le token GHCR et la clé SSH des serveurs utilisent des
  attributs *write-only*. En revanche, les variables d'env des services sont
  dans le state, qui reste privé dans R2.

## Limites connues

- Pas de réseau entre serveurs : une app et toutes ses dépendances vivent sur
  un seul serveur.
- Le nom interne d'un service (`app_name`) n'est connu qu'après sa création :
  un appel d'app à app passe par un alias réseau posé par l'infra
  (`<APP>_INTERNAL_URL`, voir le manifest), jamais par l'`app_name`.
- Les preview deployments par PR ne sont pas encore modélisés.
- Testé avec Dokploy v0.30.6 et le provider `vanillauys/dokploy` 1.9.
