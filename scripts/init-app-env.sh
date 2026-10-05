#!/usr/bin/env bash
# Creates the GitHub environments of an app from its manifest and fills their
# secrets. Run it from the app repo (or point it at one); it never overwrites a
# secret that is already set, so running it again only completes what is missing.
#
#   scripts/init-app-env.sh [-R owner/app] [-e environment] [manifest]
#
#   -R  repo of the app       (default: the repo of the current checkout)
#   -e  only this environment (default: every key of manifest.environments)
#   manifest                  (default: .deploy/manifest.yaml)
#
# For each missing secret of `secrets:` you type a value; Enter generates a
# random one (hex, safe inside URLs) for names with PASSWORD/SECRET/KEY/TOKEN,
# typed hidden. Other names (an email, a user) must be typed, + generates.
# `optionalSecrets:` are skipped on Enter. Values are never printed, and GitHub never shows them again: keep
# the ones you type somewhere safe (password manager).
#
# Needs gh (authenticated, admin on the repo), python3 with pyyaml, openssl.
set -euo pipefail

REPO="" ONLY_ENV=""
while getopts "R:e:h" o; do
  case $o in
    R) REPO=$OPTARG ;;
    e) ONLY_ENV=$OPTARG ;;
    *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
MANIFEST=${1:-.deploy/manifest.yaml}
[ -f "$MANIFEST" ] || { echo "No manifest at $MANIFEST"; exit 1; }
[ -t 0 ] || { echo "Interactive: run it in a terminal (in Claude Code: ! $0 …)"; exit 1; }
REPO=${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}

# environments, then "R NAME" (required) / "O NAME" (optional) lines.
read -r ENVS < <(python3 -c 'import sys,yaml; print(" ".join(yaml.safe_load(open(sys.argv[1]))["environments"]))' "$MANIFEST")
mapfile -t SECRETS < <(python3 - "$MANIFEST" <<'PY'
import sys, yaml
m = yaml.safe_load(open(sys.argv[1]))
for s in m.get("secrets", []): print("R", s)
for s in m.get("optionalSecrets", []): print("O", s)
PY
)
if [ -n "$ONLY_ENV" ]; then
  [[ " $ENVS " == *" $ONLY_ENV "* ]] || { echo "$ONLY_ENV is not in manifest.environments ($ENVS)"; exit 1; }
  ENVS=$ONLY_ENV
fi

echo "Repo $REPO — environments: $ENVS"

# Repo-level settings the deploy workflow needs (scripts/set-secrets.sh --app).
repo_secrets=" $(gh secret list -R "$REPO" --json name --jq '[.[].name]|join(" ")') "
repo_vars=" $(gh variable list -R "$REPO" --json name --jq '[.[].name]|join(" ")') "
missing_repo=()
for k in DOKPLOY_API_KEY R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
  [[ $repo_secrets == *" $k "* ]] || missing_repo+=("$k")
done
for k in DOKPLOY_URL TF_STATE_BUCKET; do
  [[ $repo_vars == *" $k "* ]] || missing_repo+=("$k")
done
if [ ${#missing_repo[@]} -gt 0 ]; then
  echo "! repo settings missing: ${missing_repo[*]} — from infra: scripts/set-secrets.sh --app $REPO"
fi

# Values look secret unless the name says otherwise (an email, a URL…): only
# those are typed hidden.
hidden() { [[ $1 =~ (PASSWORD|SECRET|KEY|TOKEN) ]]; }

for env in $ENVS; do
  echo
  if gh api "repos/$REPO/environments/$env" >/dev/null 2>&1; then
    echo "== $env (exists)"
  else
    gh api -X PUT "repos/$REPO/environments/$env" >/dev/null
    echo "== $env (created)"
  fi
  have=" $(gh secret list -R "$REPO" -e "$env" --json name --jq '[.[].name]|join(" ")') "

  for line in "${SECRETS[@]}"; do
    kind=${line%% *} name=${line#* }
    if [[ $have == *" $name "* ]]; then
      echo "  ✓ $name (already set)"
      continue
    fi
    if [ "$kind" = O ]; then hint="Enter = skip, + = generate"
    elif hidden "$name"; then hint="Enter = generate"
    else hint="required, + = generate"; fi
    while :; do
      if hidden "$name"; then
        read -r -s -p "  $name [$env] ($hint): " v; echo
      else
        read -r -p "  $name [$env] ($hint): " v
      fi
      # An email or a user name is never invented on a bare Enter.
      [ -n "$v" ] || [ "$kind" = O ] || hidden "$name" || continue
      break
    done
    if [ -z "$v" ] && [ "$kind" = O ]; then
      echo "  · $name skipped (optional)"
      continue
    fi
    if [ -z "$v" ] || [ "$v" = + ]; then
      v=$(openssl rand -hex 16)
      how=generated
    else
      how=set
    fi
    printf '%s' "$v" | gh secret set "$name" -R "$REPO" -e "$env" >/dev/null
    echo "  ✓ $name ($how)"
  done
done

echo
echo "Done. Protect production (required reviewer): https://github.com/$REPO/settings/environments"
