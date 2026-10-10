#!/usr/bin/env bash
# Pushes the values of .env to the GitHub secrets/variables of this repo, so
# that CI (platform.yml) runs with the same configuration as `make`. Never
# prints a value. Empty values are skipped; the platform job is enabled only
# once every required secret is set.
#
#   scripts/set-secrets.sh [owner/repo]            (default: the repo of the current checkout)
#   scripts/set-secrets.sh --legacy-app owner/app  the platform settings an app repo on the
#                                                  deprecated deploy.yml needs
# An app repo on dispatch-deploy.yml needs only INFRA_DEPLOY_TOKEN: scripts/onboard-app.sh.
set -euo pipefail

APP_MODE=false
if [ "${1:-}" = --legacy-app ] || [ "${1:-}" = --app ]; then
  APP_MODE=true; shift
  [ -n "${1:-}" ] || { echo "Usage: $0 --legacy-app owner/app"; exit 1; }
fi
REPO=${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
[ -f "$ENV_FILE" ] || { echo "No .env — cp .env.example .env and fill it."; exit 1; }

# Reads KEY=value without sourcing the file.
get() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 | sed 's/^"\(.*\)"$/\1/'; }

REQUIRED=(DOKPLOY_URL TF_STATE_BUCKET R2_BACKUP_BUCKET_PROD R2_BACKUP_BUCKET_STAGING DOKPLOY_API_KEY R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY
  R2_BACKUP_PROD_ACCESS_KEY_ID R2_BACKUP_PROD_SECRET_ACCESS_KEY
  R2_BACKUP_STAGING_ACCESS_KEY_ID R2_BACKUP_STAGING_SECRET_ACCESS_KEY)
OPTIONAL=(GHCR_TOKEN NODE_SSH_PRIVATE_KEY CF_API_TOKEN CF_ACCOUNT_ID CF_ZONE_ID APP_REPOS_READ_TOKEN RESEND_ADMIN_API_KEY)
# Once the zones/ credentials are there, its workflow can run.
ZONES_READY=$(for k in CF_API_TOKEN CF_ACCOUNT_ID RESEND_ADMIN_API_KEY; do [ -n "$(get $k)" ] || echo no; done)
VARIABLES=(DOKPLOY_URL TF_STATE_BUCKET R2_BACKUP_BUCKET_PROD R2_BACKUP_BUCKET_STAGING GHCR_USERNAME NODE_SSH_PUBLIC_KEY)
if $APP_MODE; then
  # The secrets the reusable deploy workflow reads through `secrets: inherit`.
  REQUIRED=(DOKPLOY_URL TF_STATE_BUCKET DOKPLOY_API_KEY R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY)
  OPTIONAL=(CF_API_TOKEN CF_ACCOUNT_ID)
  VARIABLES=(DOKPLOY_URL TF_STATE_BUCKET)
fi

missing=()
is_var() { [[ " ${VARIABLES[*]} " == *" $1 "* ]]; }
for k in "${REQUIRED[@]}" "${OPTIONAL[@]}"; do
  is_var "$k" && { [ -n "$(get "$k")" ] || missing+=("$k"); continue; }
  v=$(get "$k")
  if [ -n "$v" ]; then
    printf '%s' "$v" | gh secret set "$k" -R "$REPO" && echo "✓ secret   $k"
  else
    echo "· skipped  $k (empty)"
    [[ " ${REQUIRED[*]} " == *" $k "* ]] && missing+=("$k")
  fi
done
for k in "${VARIABLES[@]}"; do
  v=$(get "$k")
  [ -n "$v" ] && gh variable set "$k" -R "$REPO" --body "$v" && echo "✓ variable $k"
done

if $APP_MODE; then
  [ ${#missing[@]} -eq 0 ] || { echo "Missing in .env: ${missing[*]}"; exit 1; }
  echo "Manifest secrets go in the GitHub environments (staging, production), not here."
elif [ ${#missing[@]} -eq 0 ]; then
  gh variable set PLATFORM_ENABLED -R "$REPO" --body true && echo "✓ variable PLATFORM_ENABLED=true"
else
  echo "Platform job stays off — missing: ${missing[*]}"
fi
if ! $APP_MODE && [ -z "$ZONES_READY" ]; then
  gh variable set ZONES_ENABLED -R "$REPO" --body true && echo "✓ variable ZONES_ENABLED=true"
fi
