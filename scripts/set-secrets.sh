#!/usr/bin/env bash
# Pushes the values of .env to the GitHub secrets/variables of this repo, so
# that CI (platform.yml) runs with the same configuration as `make`. Never
# prints a value. Empty values are skipped; the platform job is enabled only
# once every required secret is set.
#
#   scripts/set-secrets.sh [owner/repo]     (default: josias-koffi/infra)
set -euo pipefail

REPO=${1:-josias-koffi/infra}
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
[ -f "$ENV_FILE" ] || { echo "No .env — cp .env.example .env and fill it."; exit 1; }

# Reads KEY=value without sourcing the file.
get() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 | sed 's/^"\(.*\)"$/\1/'; }

REQUIRED=(DOKPLOY_API_KEY R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY
  R2_BACKUP_PROD_ACCESS_KEY_ID R2_BACKUP_PROD_SECRET_ACCESS_KEY
  R2_BACKUP_STAGING_ACCESS_KEY_ID R2_BACKUP_STAGING_SECRET_ACCESS_KEY)
OPTIONAL=(GHCR_TOKEN NODE_SSH_PRIVATE_KEY)
VARIABLES=(GHCR_USERNAME NODE_SSH_PUBLIC_KEY)

missing=()
for k in "${REQUIRED[@]}" "${OPTIONAL[@]}"; do
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

if [ ${#missing[@]} -eq 0 ]; then
  gh variable set PLATFORM_ENABLED -R "$REPO" --body true && echo "✓ variable PLATFORM_ENABLED=true"
else
  echo "Platform job stays off — missing: ${missing[*]}"
fi
