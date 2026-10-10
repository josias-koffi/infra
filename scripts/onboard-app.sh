#!/usr/bin/env bash
# Plugs an app repo into the platform, once:
#   - INFRA_DEPLOY_TOKEN (from .env) as the app repo's only deploy secret;
#   - the infra environments <app>-<env>, and the secrets a human must give
#     (scripts/init-app-env.sh, interactive);
#   - templates/app-deploy.yml copied to the app checkout if it has no deploy
#     workflow yet (fill in its build steps, then commit it there).
#
#   scripts/onboard-app.sh owner/app [path/to/app/checkout]
#
# Everything else — database and cache passwords, `generate:` secrets, buckets,
# mail keys, DNS in any zone of the Cloudflare account — infra creates itself.
set -euo pipefail

REPO=${1:?Usage: $0 owner/app [path/to/app/checkout]}
CHECKOUT=${2:-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
get() { sed -n "s/^$1=//p" "$ROOT/.env" | tail -1 | sed 's/^"\(.*\)"$/\1/'; }

token=$(get INFRA_DEPLOY_TOKEN)
[ -n "$token" ] || { echo "INFRA_DEPLOY_TOKEN is empty in .env (see .env.example)"; exit 1; }
printf '%s' "$token" | gh secret set INFRA_DEPLOY_TOKEN -R "$REPO" && echo "✓ $REPO: secret INFRA_DEPLOY_TOKEN"

if [ -z "$CHECKOUT" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  gh api "repos/$REPO/contents/.deploy/manifest.yaml" --jq .content | base64 -d > "$tmp/manifest.yaml"
  MANIFEST=$tmp/manifest.yaml
else
  MANIFEST=$CHECKOUT/.deploy/manifest.yaml
  wf=$CHECKOUT/.github/workflows/deploy.yml
  if [ -f "$wf" ]; then
    grep -q dispatch-deploy.yml "$wf" || echo "! $wf still uses the old deploy: switch its deploy job to dispatch-deploy.yml (templates/app-deploy.yml)"
  else
    mkdir -p "$(dirname "$wf")" && cp "$ROOT/templates/app-deploy.yml" "$wf"
    echo "✓ $wf created from templates/app-deploy.yml — fill in the build steps"
  fi
fi
python3 "$ROOT/scripts/validate-manifest.py" "$MANIFEST"

"$ROOT/scripts/init-app-env.sh" "$MANIFEST"
