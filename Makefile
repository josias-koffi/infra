SHELL := /bin/bash

ifneq (,$(wildcard .env))
include .env
export $(shell sed -n 's/=.*//p' .env)
endif

export AWS_ENDPOINT_URL_S3=$(R2_ENDPOINT)
export AWS_ACCESS_KEY_ID=$(R2_ACCESS_KEY_ID)
export AWS_SECRET_ACCESS_KEY=$(R2_SECRET_ACCESS_KEY)
export CLOUDFLARE_API_TOKEN=$(CF_API_TOKEN)
export TF_VAR_cf_account_id=$(CF_ACCOUNT_ID)
export TF_VAR_resend_api_key=$(RESEND_ADMIN_API_KEY)
export TF_VAR_eu_backup_buckets=$(or $(EU_BACKUP_BUCKETS),false)
export TF_VAR_dokploy_endpoint=$(DOKPLOY_URL)
export TF_VAR_state_bucket=$(TF_STATE_BUCKET)
export TF_VAR_r2_endpoint=$(R2_ENDPOINT)
export TF_VAR_r2_backup_buckets={"production":"$(R2_BACKUP_BUCKET_PROD)","staging":"$(R2_BACKUP_BUCKET_STAGING)"}
export TF_VAR_r2_backup_credentials={"production":{"access_key":"$(R2_BACKUP_PROD_ACCESS_KEY_ID)","secret_access_key":"$(R2_BACKUP_PROD_SECRET_ACCESS_KEY)"},"staging":{"access_key":"$(R2_BACKUP_STAGING_ACCESS_KEY_ID)","secret_access_key":"$(R2_BACKUP_STAGING_SECRET_ACCESS_KEY)"}}
export TF_VAR_ghcr_username=$(GHCR_USERNAME)
export TF_VAR_ghcr_token=$(GHCR_TOKEN)
export TF_VAR_node_ssh_public_key=$(NODE_SSH_PUBLIC_KEY)
export TF_VAR_node_ssh_private_key=$(NODE_SSH_PRIVATE_KEY)

.PHONY: help setup-manager add-node node-key platform-plan platform-apply zones-plan zones-apply app-plan app-deploy verify-backups test

help: ## List commands
	@grep -hE '^[a-z-]+:.*## ' Makefile | awk 'BEGIN {FS = ":.*## "}; {printf "  %-16s %s\n", $$1, $$2}'

setup-manager: ## Provision the Dokploy manager — never reinstalls a running Dokploy. CHECK=1 for a dry run
	@ansible-playbook ansible/playbooks/setup-manager.yml $(if $(CHECK),--check --diff,)

add-node: ## Prepare a server the manager deploys to. NODE=<inventory host>
	@test -n "$(NODE)" || (echo "NODE=<inventory host> is required" && exit 1)
	@DOKPLOY_NODE_PUBLIC_KEY="$(NODE_SSH_PUBLIC_KEY)" ansible-playbook ansible/playbooks/add-node.yml -e node=$(NODE)

node-key: ## Generate the key pair the manager uses for remote nodes (prints .env lines)
	@tmp=$$(mktemp -d) && ssh-keygen -q -t ed25519 -N '' -C dokploy-nodes -f $$tmp/k && \
	  echo "NODE_SSH_PUBLIC_KEY=$$(cat $$tmp/k.pub)" && \
	  echo "NODE_SSH_PRIVATE_KEY=\"$$(awk 'BEGIN{ORS="\\n"}1' $$tmp/k)\"" && rm -rf $$tmp

platform-plan: ## Plan the Dokploy instance (settings, backup destinations, nodes)
	@tofu -chdir=platform init -input=false -reconfigure -backend-config="bucket=$(TF_STATE_BUCKET)" >/dev/null && tofu -chdir=platform plan

platform-apply: ## Apply the Dokploy instance configuration
	@tofu -chdir=platform init -input=false -reconfigure -backend-config="bucket=$(TF_STATE_BUCKET)" >/dev/null && tofu -chdir=platform apply

zones-plan: ## Plan zones/ (sending domains and their records, zones/zones.yaml)
	@tofu -chdir=zones init -input=false -reconfigure -backend-config="bucket=$(TF_STATE_BUCKET)" >/dev/null && tofu -chdir=zones plan

zones-apply: ## Apply zones/
	@tofu -chdir=zones init -input=false -reconfigure -backend-config="bucket=$(TF_STATE_BUCKET)" >/dev/null && tofu -chdir=zones apply

app-plan: ## Plan one env of an app. MANIFEST=… ENV=staging [TAG=…]
	@test -n "$(MANIFEST)" -a -n "$(ENV)" || (echo "MANIFEST= and ENV= are required" && exit 1)
	@scripts/deploy-app.sh $(MANIFEST) $(ENV) $(or $(TAG),current) plan

app-deploy: ## Deploy one env of an app from a workstation (CI does it on push). MANIFEST=… ENV=… TAG=…
	@test -n "$(MANIFEST)" -a -n "$(ENV)" -a -n "$(TAG)" || (echo "MANIFEST=, ENV= and TAG= are required" && exit 1)
	@scripts/deploy-app.sh $(MANIFEST) $(ENV) $(TAG) apply

verify-backups: ## Freshness and real restore of the backups (scripts/backups.py). [APP=…] [ENV=…] [FAST=1: freshness only]
	@scripts/backups.py verify $(if $(APP),--app $(APP),) $(if $(ENV),--env $(ENV),) $(if $(FAST),--no-restore,)

test: ## Validate manifests, run the module tests, validate every root
	@scripts/validate-manifest.py examples/*/.deploy/manifest.yaml modules/dokploy-app/tests/fixtures/*.yaml modules/dokploy-app/tests/fixtures/*/.deploy/manifest.yaml apps/env/tests/fixtures/*/.deploy/manifest.yaml
	@cd modules/dokploy-app && tofu init -backend=false -input=false >/dev/null && tofu test
	@cd apps/env && tofu init -backend=false -input=false >/dev/null && tofu test
	@cd zones && tofu init -backend=false -input=false >/dev/null && tofu test
	@for d in platform apps/project apps/env zones; do tofu -chdir=$$d init -backend=false -input=false >/dev/null && tofu -chdir=$$d validate >/dev/null && echo "✓ $$d"; done
