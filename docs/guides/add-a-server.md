# Ajouter un serveur

Les serveurs supplémentaires sont des **serveurs distants Dokploy**. Chacun
fait tourner son propre Traefik et ses conteneurs, et le panel le pilote par
SSH. Il n'y a pas de réseau overlay entre les serveurs : tous les services
d'une app vivent sur le même serveur.

## Étapes

1. **Clé SSH** (une seule fois) : `make node-key` affiche deux lignes à coller
   dans `.env` (`NODE_SSH_PUBLIC_KEY`, `NODE_SSH_PRIVATE_KEY`). Lance ensuite
   `scripts/set-secrets.sh` pour que la CI les ait aussi.
2. **Inventaire** : ajoute le serveur sous `[dokploy_nodes]` dans
   `ansible/inventory/hosts` :
   ```ini
   [dokploy_nodes]
   node2 ansible_host=203.0.113.20 ansible_user=root
   ```
3. **Préparer le serveur** : `make add-node NODE=node2`. Ce playbook applique
   la sécurisation de base, installe Docker, autorise la clé de Dokploy pour
   `root` et pose le timer de nettoyage.
4. **Le déclarer** : ajoute-le dans `platform/nodes.yaml`.
   ```yaml
   node2:
     role: remote
     ip: 203.0.113.20
     description: second serveur
   ```
   Ouvre une PR (`plan`), puis merge (`apply` : crée le `dokploy_server`). En
   local : `make platform-apply`.
5. **Setup** : dans le panel, *Settings → Servers → node2 → Setup Server*. Le
   provider ne lance pas cette longue tâche SSH lui-même.
6. **L'utiliser** : `server: node2` dans le manifest d'une app. Les
   enregistrements DNS de ses domaines suivent l'IP du serveur au déploiement
   suivant.

## Déplacer une app existante vers un autre serveur

Changer `server:` recrée les services de l'app sur l'autre machine. Les
données ne suivent pas toutes seules. Traite-le comme une migration :
sauvegarde, restauration des bases sur le nouveau serveur, copie des volumes,
puis bascule.
