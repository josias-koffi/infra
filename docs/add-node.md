# Adding a server to the PaaS

Extra servers are **Dokploy remote servers**: each runs its own Traefik and
containers, driven over SSH by the panel on VPS20. No overlay network between
nodes, so an app (all its services) lives on one node.

1. **Key** (once): `make node-key`, paste both lines into `.env`. In GitHub
   (this repo): variable `NODE_SSH_PUBLIC_KEY`, secret `NODE_SSH_PRIVATE_KEY`.
2. **Inventory**: add the host under `[dokploy_nodes]` in
   `ansible/inventory/hosts`, e.g. `node2_host ansible_host=203.0.113.20 ansible_user=root`.
3. **Prepare**: `make add-node NODE=node2_host` (base hardening, Docker,
   authorises the Dokploy key for root, housekeeping timer).
4. **Register**: add the node to `platform/nodes.yaml` with `role: remote`,
   open a PR (plan), merge (apply creates the `dokploy_server`).
5. **Setup**: in the panel, *Settings → Servers → node2 → Setup Server* (the
   provider does not run this long SSH job).
6. **Use**: `server: node2` in an app manifest. The DNS records of its domains
   follow the node IP on the next deploy.

Moving an existing app to another node recreates its services there: plan it
like a migration (backup, restore of the database, volumes copied).
