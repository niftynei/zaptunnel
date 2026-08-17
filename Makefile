# Zaptunnel DigitalOcean provisioning and deployment commands.
# Run `make help` to list the workflow. Authentication comes from either the
# DIGITALOCEAN_TOKEN environment variable or the active doctl context.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

DIGITALOCEAN_TOKEN ?= $(shell doctl auth token 2>/dev/null)
export DIGITALOCEAN_TOKEN

TERRAFORM := $(shell if command -v terraform >/dev/null 2>&1; then printf 'terraform'; elif command -v tofu >/dev/null 2>&1; then printf 'tofu'; else printf 'nix develop --command tofu'; fi)
NIXOS_REBUILD := $(shell if command -v nixos-rebuild >/dev/null 2>&1; then printf 'env TMPDIR=/tmp nixos-rebuild'; else printf 'nix develop --command env TMPDIR=/tmp nixos-rebuild'; fi)
IP = $(shell cd terraform 2>/dev/null && $(TERRAFORM) output -raw ipv4 2>/dev/null)
SSH := ssh -o StrictHostKeyChecking=accept-new
SCP := scp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10
HOST_COPY_ATTEMPTS ?= 12
SSH_PUBLIC_KEY ?= $(HOME)/.ssh/id_ed25519.pub
SSH_KEY_FINGERPRINT = $(shell if [ -f "$(SSH_PUBLIC_KEY)" ]; then ssh-keygen -E md5 -lf "$(SSH_PUBLIC_KEY)" | awk '{sub(/^MD5:/, "", $$2); print $$2}'; fi)
export TF_VAR_ssh_key_fingerprint := $(SSH_KEY_FINGERPRINT)

.PHONY: help check-token check-ip init register-key plan create provision ip \
	wait-for-nixos pull-host-config install-acme-token verify-acme-token deploy \
	deploy-local-build deploy-dry build-host build check update ssh status \
	logs acme-logs prometheus-logs grafana-logs alert-logs tor-logs website health ready metrics smoke prometheus grafana alerts dns destroy

help: ## Show available commands.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} \
	      /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

check-token:
	@if [ -z "$${DIGITALOCEAN_TOKEN:-}" ]; then \
		echo "ERROR: no DigitalOcean token found." >&2; \
		echo "Set DIGITALOCEAN_TOKEN or run 'doctl auth init'." >&2; \
		exit 1; \
	fi

check-ip:
	@if [ -z "$(IP)" ]; then \
		echo "ERROR: Terraform has no Zaptunnel droplet IP." >&2; \
		echo "Run 'make create' first." >&2; \
		exit 1; \
	fi

init: ## Initialize the Terraform/OpenTofu working directory.
	cd terraform && $(TERRAFORM) init

register-key: check-token ## Register the deployment key unless its fingerprint already exists.
	@if [ ! -f "$(SSH_PUBLIC_KEY)" ]; then \
		echo "ERROR: $(SSH_PUBLIC_KEY) does not exist." >&2; \
		exit 1; \
	elif [ -z "$(SSH_KEY_FINGERPRINT)" ]; then \
		echo "ERROR: could not calculate the fingerprint for $(SSH_PUBLIC_KEY)." >&2; \
		exit 1; \
	elif doctl compute ssh-key list --format FingerPrint --no-header | grep -Fxiq "$(SSH_KEY_FINGERPRINT)"; then \
		echo "DigitalOcean already has deployment key $(SSH_KEY_FINGERPRINT); reusing it."; \
	else \
		doctl compute ssh-key import zapptunnel-deploy --public-key-file "$(SSH_PUBLIC_KEY)"; \
	fi

plan: check-token register-key ## Preview droplet, firewall, and DNS changes.
	cd terraform && $(TERRAFORM) plan

create: check-token register-key ## Create the droplet, firewall, and DNS records.
	cd terraform && $(TERRAFORM) apply
	@echo
	@echo "The droplet is converting itself to NixOS. Next run:"
	@echo "  make wait-for-nixos"
	@echo "  make pull-host-config"
	@echo "  make deploy"

provision: check-token ## Run the complete first-deployment workflow.
	@$(MAKE) init
	@$(MAKE) create
	@$(MAKE) wait-for-nixos
	@$(MAKE) pull-host-config
	@$(MAKE) deploy
	@$(MAKE) smoke

ip: check-ip ## Print the droplet IPv4 address.
	@echo "$(IP)"

wait-for-nixos: check-ip ## Wait until nixos-infect finishes and the droplet reboots.
	@echo "Waiting for NixOS on $(IP)..."
	@for attempt in $$(seq 1 60); do \
		if $(SSH) -o ConnectTimeout=5 -o BatchMode=yes root@$(IP) \
			'test -e /etc/NIXOS' >/dev/null 2>&1; then \
			echo "NixOS is ready."; \
			exit 0; \
		fi; \
		echo "  attempt $$attempt/60: not ready; retrying in 10 seconds"; \
		sleep 10; \
	done; \
	echo "Timed out waiting for NixOS." >&2; \
	exit 1

pull-host-config: check-ip ## Pull the droplet's generated hardware and network configuration.
	@copy_from_host() { \
		remote_path="$$1"; \
		destination="$$2"; \
		temporary="$$destination.tmp"; \
		for attempt in $$(seq 1 $(HOST_COPY_ATTEMPTS)); do \
			if $(SCP) "root@$(IP):$$remote_path" "$$temporary"; then \
				mv "$$temporary" "$$destination"; \
				return 0; \
			fi; \
			echo "  copy attempt $$attempt/$(HOST_COPY_ATTEMPTS) failed; retrying in 5 seconds"; \
			sleep 5; \
		done; \
		rm -f "$$temporary"; \
		return 1; \
	}; \
	copy_from_host /etc/nixos/hardware-configuration.nix nix/hosts/hardware-configuration.nix; \
	if copy_from_host /etc/nixos/networking.nix nix/hosts/networking.nix; then \
		echo "Pulled DigitalOcean networking configuration."; \
	else \
		echo "No generated networking.nix found; retaining DHCP configuration."; \
	fi

install-acme-token: check-token check-ip ## Install the DigitalOcean DNS token used by ACME.
	@TOKEN="$${DIGITALOCEAN_DNS_TOKEN:-$${DIGITALOCEAN_TOKEN}}"; \
	printf '%s\n' "$$TOKEN" | $(SSH) root@$(IP) \
		'install -d -m 0700 -o root -g root /var/lib/zapptunnel-secrets && \
		 install -m 0400 -o root -g root /dev/stdin /var/lib/zapptunnel-secrets/digitalocean-dns-token'
	@echo "Installed the ACME DNS token outside the Nix store."

verify-acme-token: check-ip ## Verify that the installed token can read the DO domain list.
	@$(SSH) root@$(IP) 'token=$$(tr -d "\r\n" </var/lib/zapptunnel-secrets/digitalocean-dns-token); \
		curl --fail --silent --show-error \
		-H "Authorization: Bearer $$token" https://api.digitalocean.com/v2/domains >/dev/null'
	@echo "The installed DigitalOcean token is valid."

deploy: check-ip ## Install secrets, build on the droplet, and activate Zaptunnel.
	@$(MAKE) install-acme-token
	@$(MAKE) verify-acme-token
	$(NIXOS_REBUILD) switch \
		--flake path:.#zapptunnel \
		--target-host root@$(IP) \
		--build-host root@$(IP)

deploy-local-build: check-ip ## Build locally, copy, and activate on the droplet.
	@$(MAKE) install-acme-token
	@$(MAKE) verify-acme-token
	$(NIXOS_REBUILD) switch \
		--flake path:.#zapptunnel \
		--target-host root@$(IP)

deploy-dry: check-ip ## Validate activation on the droplet without switching.
	$(NIXOS_REBUILD) dry-activate \
		--flake path:.#zapptunnel \
		--target-host root@$(IP) \
		--build-host root@$(IP)

build-host: ## Build the complete NixOS system locally without deploying.
	nix build path:.#nixosConfigurations.zapptunnel.config.system.build.toplevel

build: ## Build the production relay package locally.
	nix build path:.#relay

check: ## Run all relay, SDK, integration, module, and host checks.
	nix flake check path:. -L

update: ## Update pinned flake inputs.
	nix flake update

ssh: check-ip ## Open a root shell on the droplet.
	$(SSH) root@$(IP)

status: check-ip ## Show relay, ACME, Prometheus, Grafana, and exporter service status.
	$(SSH) root@$(IP) 'systemctl --no-pager --full status \
		zaptunnel-relay.service acme-zapptunnel.com.service \
		prometheus.service prometheus-node-exporter.service grafana.service \
		alertmanager.service alertmanager-webhook-logger.service tor.service'

logs: check-ip ## Follow Zaptunnel relay logs.
	$(SSH) root@$(IP) 'journalctl -u zaptunnel-relay.service -f'

acme-logs: check-ip ## Follow certificate issuance and renewal logs.
	$(SSH) root@$(IP) 'journalctl -u acme-zapptunnel.com.service -f'

prometheus-logs: check-ip ## Follow Prometheus logs.
	$(SSH) root@$(IP) 'journalctl -u prometheus.service -f'

grafana-logs: check-ip ## Follow Grafana logs.
	$(SSH) root@$(IP) 'journalctl -u grafana.service -f'

alert-logs: check-ip ## Follow firing and resolved Alertmanager notifications.
	$(SSH) root@$(IP) 'journalctl -u alertmanager-webhook-logger.service -f'

tor-logs: check-ip ## Follow Tor client logs.
	$(SSH) root@$(IP) 'journalctl -u tor.service -f'

health: ## Check the public relay health endpoint.
	curl --fail --silent --show-error https://relay.zapptunnel.com/healthz
	@echo

ready: ## Check whether the public relay is accepting new admissions.
	curl --fail --silent --show-error https://relay.zapptunnel.com/readyz
	@echo

website: ## Check the public documentation and demo site.
	curl --fail --silent --show-error https://zapptunnel.com/ | grep -Fq '<title>Zaptunnel — your node, from anywhere</title>'
	@echo "Zaptunnel website is available."

metrics: ## Print the public Prometheus exposition from the relay.
	curl --fail --silent --show-error https://relay.zapptunnel.com/metrics

smoke: ## Wait for DNS/ACME, then verify HTTPS health and Prometheus exposition.
	@for attempt in $$(seq 1 60); do \
		if curl --fail --silent https://zapptunnel.com/ 2>/dev/null | \
			grep -Fq '<title>Zaptunnel — your node, from anywhere</title>' && \
			curl --fail --silent https://relay.zapptunnel.com/readyz >/dev/null 2>&1 && \
			curl --fail --silent https://relay.zapptunnel.com/metrics 2>/dev/null | \
			grep -q '^zaptunnel_sessions'; then \
			echo "Zaptunnel website, HTTPS relay, and metrics smoke checks passed."; \
			exit 0; \
		fi; \
		echo "  smoke attempt $$attempt/60 failed; retrying in 5 seconds"; \
		sleep 5; \
	done; \
	echo "Zaptunnel did not become healthy within five minutes." >&2; \
	exit 1

prometheus: check-ip ## Tunnel the private Prometheus UI to http://127.0.0.1:9090.
	@echo "Prometheus: http://127.0.0.1:9090 (Ctrl-C to close)"
	$(SSH) -N -L 9090:127.0.0.1:9090 root@$(IP)

grafana: check-ip ## Tunnel the private Grafana dashboard to http://127.0.0.1:3000.
	@echo "Grafana: http://127.0.0.1:3000 (Ctrl-C to close)"
	$(SSH) -N -L 3000:127.0.0.1:3000 root@$(IP)

alerts: check-ip ## Tunnel the private Alertmanager UI to http://127.0.0.1:9093.
	@echo "Alertmanager: http://127.0.0.1:9093 (Ctrl-C to close)"
	$(SSH) -N -L 9093:127.0.0.1:9093 root@$(IP)

dns: ## Show the current apex and relay DNS records.
	dig +short A zapptunnel.com
	dig +short AAAA zapptunnel.com
	dig +short A relay.zapptunnel.com
	dig +short AAAA relay.zapptunnel.com

destroy: check-token ## Destroy the droplet, firewall, and managed DNS records.
	cd terraform && $(TERRAFORM) destroy

.DEFAULT_GOAL := help
