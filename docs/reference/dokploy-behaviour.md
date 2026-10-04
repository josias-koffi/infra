# Comportements Dokploy vérifiés

Comportements observés le 2026-10-04 sur un projet jetable (Dokploy v0.30.6,
provider `vanillauys/dokploy` 1.9). Les garde-fous du repo en découlent.

| Action | Résultat observé | Conséquence dans le repo |
|---|---|---|
| Changer `environment_id` d'un compose | **Déplacement sur place** : même compose, même `appName`, même conteneur (pas même redémarré), mêmes volumes | Les stacks existants passent d'un projet à un environnement sans être recréés |
| Supprimer un compose dont les volumes sont nommés simplement | **Les volumes sont supprimés avec le compose** | `externalVolumes: true` est obligatoire en mode compose ; on libère les anciens states avec `tofu state rm`, jamais `destroy` |
| Supprimer un compose dont les volumes sont `external: true` | Les volumes et leurs données sont conservés | idem |
| Supprimer une application qui monte un volume existant | Le volume est conservé | Une app sortie d'un compose peut remonter le même volume sans risque |
| Ajouter un montage à une application déjà créée | Pas appliqué avant un redéploiement (l'app tourne sans son volume) | Le module redéploie l'app (`application.redeploy`) quand ses montages changent |
| Clé API bridée par le rate limiting | Répond `401`, pas `429` | À garder en tête au moment du diagnostic |
| Nettoyage Docker de Dokploy activé | Les conteneurs arrêtés ont survécu | Le timer `housekeeping` ne supprime pas les conteneurs arrêtés non plus |

Pour vérifier de nouveau après une mise à jour de Dokploy : le test tient en
une vingtaine de lignes OpenTofu. Il crée un projet `zz-*` avec deux
environnements, un compose qui écrit dans un volume nommé et une application
avec un montage. Applique, déplace, supprime, puis contrôle avec
`docker volume inspect` après chaque étape. Le projet se supprime ensuite
avec `tofu destroy`.
