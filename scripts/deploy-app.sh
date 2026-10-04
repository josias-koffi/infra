#!/usr/bin/env bash
# Deploys one environment of one app from its manifest. Called by the thin
# workflow of each app repo (templates/app-deploy.yml) and usable locally.
#
#   scripts/deploy-app.sh <manifest> <environment> <image_tag> [plan|apply]
#
# Environment:
#   DOKPLOY_URL, DOKPLOY_API_KEY                      Dokploy panel and API key
#   TF_STATE_BUCKET                                   R2 bucket of the states
#   AWS_ENDPOINT_URL_S3, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   R2 state backend
#   CLOUDFLARE_API_TOKEN, CF_ZONE_ID                  DNS (manifests with dns: cloudflare)
#   SECRETS_JSON                                      JSON object of secret values (toJSON(secrets))
set -euo pipefail

MANIFEST=$(realpath "$1")
ENVIRONMENT=$2
IMAGE_TAG=$3
ACTION=${4:-apply}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
: "${DOKPLOY_URL:?DOKPLOY_URL is required}" "${TF_STATE_BUCKET:?TF_STATE_BUCKET is required}"
export TF_VAR_dokploy_endpoint="$DOKPLOY_URL" TF_VAR_state_bucket="$TF_STATE_BUCKET"

python3 "$ROOT/scripts/validate-manifest.py" "$MANIFEST"

APP=$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["name"])' "$MANIFEST")
python3 - "$MANIFEST" "$ENVIRONMENT" <<'PY'
import sys, yaml
m = yaml.safe_load(open(sys.argv[1]))
if sys.argv[2] not in m["environments"]:
    sys.exit(f"environment '{sys.argv[2]}' is not declared in {sys.argv[1]}")
PY

echo "::group::${APP} — project (apps/${APP}/project.tfstate)"
tofu -chdir="$ROOT/apps/project" init -input=false -reconfigure \
  -backend-config="bucket=${TF_STATE_BUCKET}" -backend-config="key=apps/${APP}/project.tfstate" >/dev/null
if [ "$ACTION" = apply ]; then
  tofu -chdir="$ROOT/apps/project" apply -input=false -auto-approve -var "manifest_path=${MANIFEST}"
else
  tofu -chdir="$ROOT/apps/project" plan -input=false -var "manifest_path=${MANIFEST}"
fi
echo "::endgroup::"

echo "::group::${APP} — ${ENVIRONMENT} (apps/${APP}/${ENVIRONMENT}.tfstate)"
export TF_VAR_secrets_json="${SECRETS_JSON:-{\}}"
export TF_VAR_cf_zone_id="${CF_ZONE_ID:-}"
tofu -chdir="$ROOT/apps/env" init -input=false -reconfigure \
  -backend-config="bucket=${TF_STATE_BUCKET}" -backend-config="key=apps/${APP}/${ENVIRONMENT}.tfstate" >/dev/null
# -detailed-exitcode: 0 = no change, 1 = error, 2 = changes to apply.
set +e
tofu -chdir="$ROOT/apps/env" plan -input=false -detailed-exitcode -out=tfplan \
  -var "manifest_path=${MANIFEST}" -var "environment=${ENVIRONMENT}" -var "image_tag=${IMAGE_TAG}"
rc=$?
set -e
[ $rc -eq 1 ] && exit 1

# A plan that destroys a stateful service is never applied unattended.
if tofu -chdir="$ROOT/apps/env" show -json tfplan | python3 -c '
import json, sys
plan = json.load(sys.stdin)
stateful = ("dokploy_postgres", "dokploy_mysql", "dokploy_mariadb", "dokploy_mongo", "dokploy_redis", "dokploy_compose", "dokploy_mount")
bad = [r["address"] for r in plan.get("resource_changes", [])
       if r["type"] in stateful and "delete" in r["change"]["actions"]]
if bad:
    print("Refusing to destroy stateful resources:", *bad, sep="\n  ")
    print("Use the purge-env workflow (protected) for an intended removal.")
    sys.exit(1)
'; then :; else exit 1; fi

if [ "$ACTION" = apply ] && [ $rc -eq 2 ]; then
  tofu -chdir="$ROOT/apps/env" apply -input=false tfplan
fi
echo "::endgroup::"

[ "$ACTION" = apply ] || exit 0

# Smoke test: every domain answers, and declared health checks return 2xx.
echo "::group::smoke test"
python3 - "$MANIFEST" "$ENVIRONMENT" <<'PY' > /tmp/smoke-urls
import sys, yaml
m = yaml.safe_load(open(sys.argv[1])); env = m["environments"][sys.argv[2]]
domains = env.get("domains", {})
checks = {f"https://{h}/": "any" for h in domains.values()}
for c in {**m.get("apps", {})}.values():
    if c.get("healthcheck") and c.get("domain") in domains:
        checks[f"https://{domains[c['domain']]}{c['healthcheck']}"] = "2xx"
for url, want in checks.items():
    print(url, want)
PY
fail=0
while read -r url want; do
  code=000
  for _ in $(seq 1 30); do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)
    if [ "$want" = 2xx ]; then [[ $code == 2* ]] && break; else [[ $code != 000 && $code != 5* ]] && break; fi
    sleep 10
  done
  echo "$code $url"
  if [ "$want" = 2xx ]; then [[ $code == 2* ]] || fail=1; else [[ $code != 000 && $code != 5* ]] || fail=1; fi
done < /tmp/smoke-urls
echo "::endgroup::"
exit $fail
