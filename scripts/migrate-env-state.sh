#!/usr/bin/env bash
# One-time state migrations of apps/env, run before every plan (idempotent).
#
#   scripts/migrate-env-state.sh <tofu -chdir directory, already initialised>
#
# Cloudflare provider v4 -> v5: OpenTofu cannot decode the old cloudflare_record
# type any more (the provider's state move does not answer OpenTofu), so those
# entries leave the state. The records themselves are untouched: deploy-app.sh
# imports them back as cloudflare_dns_record (they carry our comment).
set -euo pipefail
DIR=$1
STATE=$(mktemp)
trap 'rm -f "$STATE"' EXIT
tofu -chdir="$DIR" state pull > "$STATE"
if python3 - "$STATE" <<'PY'
import json, sys
raw = open(sys.argv[1]).read().strip()
s = json.loads(raw) if raw else {}
old = [r for r in s.get("resources", []) if r["mode"] == "managed" and r["type"] == "cloudflare_record"]
if not old:
    sys.exit(1)
s["resources"] = [r for r in s["resources"] if r not in old]
s["serial"] += 1
json.dump(s, open(sys.argv[1], "w"))
for r in old:
    for i in r["instances"]:
        print(f"State: {r['name']}[{i.get('index_key')!r}] ({i['attributes']['name']}) left the state as cloudflare_record")
PY
then
  tofu -chdir="$DIR" state push "$STATE"
fi
