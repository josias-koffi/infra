# GitHub App de déploiement

`deploy-app.yml` et `purge-env.yml` lisent le repo de l'app (manifeste, compose).
Les repos d'apps sont répartis sur plusieurs comptes GitHub, et un token
fine-grained ne couvre qu'un compte : la lecture passe donc par une GitHub App,
installée sur chaque compte. Chaque run en tire un jeton valable une heure,
limité au repo déployé et à *Contents: Read*. Aucun token à renouveler.

## Créer l'app (une fois)

1. Sur le compte qui possède `infra` : *Settings → Developer settings → GitHub
   Apps → New GitHub App*.
   - Nom : libre (unique sur GitHub), Homepage URL : l'URL du repo `infra`.
   - *Webhook* : décocher *Active*.
   - *Repository permissions* : *Contents → Read-only* (*Metadata → Read-only*
     vient avec). Rien d'autre.
   - *Where can this GitHub App be installed?* : **Any account**, sinon elle ne
     s'installe pas sur les autres comptes. Elle ne lit que les repos où elle
     est installée.
2. Noter le **Client ID**, puis *Generate a private key* (fichier `.pem`).
3. Poser les deux valeurs dans `infra` :

   ```bash
   gh variable set DEPLOY_APP_CLIENT_ID -R <owner>/infra --body "<Client ID>"
   gh secret set DEPLOY_APP_PRIVATE_KEY -R <owner>/infra < chemin/vers/cle.pem
   ```

   Ou via `.env` + `scripts/set-secrets.sh` (clé sur une ligne, voir
   `.env.example`). Supprimer ensuite le `.pem` local.

## Installer l'app sur un compte

Pour chaque compte qui possède un repo d'app : page publique de l'app
(*Settings → Developer settings → GitHub Apps → l'app → Install App*), choisir
le compte, puis *Only select repositories* et cocher les repos d'apps.

Brancher une nouvelle app d'un compte déjà installé : ajouter son repo à
l'installation (*Settings → Applications → l'app → Configure* sur ce compte).

## Diagnostic

- `Failed to create token for "<owner>"` / 404 : l'app n'est pas installée sur
  ce compte, ou le repo n'est pas dans la sélection.
- `client-id input must be set` : `DEPLOY_APP_CLIENT_ID` manque (c'est une
  *variable*, pas un secret).
