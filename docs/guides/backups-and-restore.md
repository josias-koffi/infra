# Sauvegardes et restauration

## Ce qui est sauvegardé, sans rien configurer

| Quoi | Où (bucket / préfixe) | Quand | Rétention |
|---|---|---|---|
| Chaque base (`databases:`, ou base d'un compose) | `<bucket env>/db/<app>/<env>/…` | tous les jours à 3h | 35 jours en prod, 7 en staging |
| Chaque volume nommé d'une app (`volumes:`, ou `compose.backupVolumes`) | `<bucket env>/volumes/<app>/<env>/<volume>/` | tous les jours à 4h | idem |
| Dokploy lui-même (sa base et `/etc/dokploy`) | `<bucket prod>/dokploy/` | tous les jours à 2h30 | 14 copies |

Le bucket dépend de l'environnement : `R2_BACKUP_BUCKET_PROD` pour la
production, `R2_BACKUP_BUCKET_STAGING` pour tout le reste. Chacun a son propre
token, pour que le staging n'ait jamais accès aux sauvegardes de prod.

Réglages, dans le manifest :

```yaml
backups:
  cron: "0 2 * * *"                 # bases
  volumeCron: "0 5 * * *"           # volumes
  keep: { production: 60, staging: 3 }
  prefix:                           # garder une arborescence existante
    db: { production: db/production/ }
```

Désactiver les sauvegardes demande une justification, que le schéma vérifie :
`backups: { enabled: false, reason: "données recalculables depuis X" }`.

Dokploy envoie les échecs de sauvegarde dans ses notifications (à configurer
dans le panel si tu veux des alertes).

## Restaurer une base

**Depuis le panel** : ouvre le service de base (mode services) ou le compose,
onglet *Backups*, puis *Restore* sur une sauvegarde.

**À la main**, à partir d'un fichier R2 :

```bash
# lister puis télécharger (n'importe quel client S3 ; ici l'AWS CLI)
export AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…   # token du bucket concerné
aws s3 ls  s3://<bucket>/db/<app>/<env>/ --endpoint-url "$R2_ENDPOINT" --recursive
aws s3 cp  s3://<bucket>/db/<app>/<env>/<fichier>.sql.gz . --endpoint-url "$R2_ENDPOINT"

# restaurer dans le conteneur Postgres
gunzip -c <fichier>.sql.gz | ssh root@<serveur> "docker exec -i <conteneur-postgres> psql -U <user> -d <db>"
```

Restaure d'abord en staging, ou dans une base temporaire, et compare le
nombre de lignes avant de toucher la prod.

## Restaurer un volume

```bash
aws s3 cp s3://<bucket>/volumes/<app>/<env>/<volume>/<archive> . --endpoint-url "$R2_ENDPOINT"
scp <archive> root@<serveur>:/tmp/
ssh root@<serveur> 'docker run --rm -v <volume>:/v -v /tmp:/in alpine sh -c "cd /v && tar xzf /in/<archive>"'
```

Arrête d'abord le service qui utilise le volume.

## Reconstruire un serveur perdu

1. Nouveau serveur : mets à jour son IP dans `ansible/inventory/hosts`,
   `platform/nodes.yaml` et le DNS du panel.
2. `make setup-manager` : installe Docker et Dokploy, à la version figée.
3. Restaure Dokploy depuis la dernière archive `dokploy/` de R2 :
   - arrête le service `dokploy` ;
   - remets `/etc/dokploy` en place ;
   - charge le dump dans `dokploy-postgres`
     (`gunzip -c <dump> | docker exec -i <conteneur> psql -U dokploy`) ;
   - relance `dokploy`.
4. `make platform-apply`, puis relance le workflow de déploiement de chaque
   app (staging, puis production) : les services sont recréés depuis leurs
   manifests.
5. Restaure les bases et les volumes, comme décrit plus haut.
6. Le DNS des apps (`dns: cloudflare`) est réécrit au déploiement, avec la
   nouvelle IP.
