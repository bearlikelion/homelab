# Convenience wrapper around the OpenTofu stack and the Ansible deploy.
#
# Layers apply in order: network -> node. Each keeps its own state.
#   - network : bridge and address plan (thin; the LAN already exists)
#   - node    : the LXC containers
#
# Usage:
#   make ENV=prod LAYER=node plan
#   make ENV=prod apply-all
#   make deploy                     # Ansible over the running containers

ENV    ?= prod
LAYER  ?= node
LAYERS := network node

.PHONY: help init plan apply destroy apply-all fmt validate inventory deploy check-host

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

init: ## Init one layer:   make ENV=prod LAYER=node init
	cd live/$(ENV)/$(LAYER) && tofu init

plan: ## Plan one layer:   make ENV=prod LAYER=node plan
	cd live/$(ENV)/$(LAYER) && tofu init -input=false && tofu plan

apply: ## Apply one layer:  make ENV=prod LAYER=node apply
	cd live/$(ENV)/$(LAYER) && tofu init -input=false && tofu apply

destroy: ## Destroy one layer: make ENV=prod LAYER=node destroy
	cd live/$(ENV)/$(LAYER) && tofu destroy

apply-all: ## Apply every layer in dependency order
	@for l in $(LAYERS); do \
	  echo "=== apply $(ENV)/$$l ==="; \
	  (cd live/$(ENV)/$$l && tofu init -input=false && tofu apply -auto-approve) || exit 1; \
	done

fmt: ## Format all .tf files
	tofu fmt -recursive

validate: ## Validate one layer:  make ENV=prod LAYER=node validate
	cd live/$(ENV)/$(LAYER) && tofu validate

inventory: ## Regenerate the Ansible inventory from tofu outputs
	@cd live/$(ENV)/node && tofu output -json containers > ../../../ansible/inventory.generated.json
	@echo "wrote ansible/inventory.generated.json"

deploy: inventory ## Run the Ansible playbook against every container
	cd ansible && ansible-playbook site.yml

check-host: ## Print the host facts the build depends on
	@ssh root@$${PVE_HOST:-192.168.1.99} '\
	  printf "lxc-pve:  "; dpkg-query -W -f="\$${Version}\n" lxc-pve; \
	  printf "pve:      "; pveversion | head -1; \
	  printf "render:   "; getent group render || echo none; \
	  echo "--- storage ---"; findmnt -t ext4,xfs,btrfs -o TARGET,SOURCE,FSTYPE | grep -v "^/ "'
