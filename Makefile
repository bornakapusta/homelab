.PHONY: deps check hooks test ping nodes cluster platform metrics storage argocd all status hosts reset-help

ANSIBLE_DIR := ansible

# The Docker socket, taken from whatever context is active. Not hardcoded to
# /var/run/docker.sock: on macOS that is often a symlink into a Docker Desktop
# path that does not exist under OrbStack/Colima, and the Python docker SDK that
# community.docker uses cannot fall back the way the docker CLI does.
DOCKER_HOST_FROM_CTX := $(shell docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)

# Read from the single sources of truth rather than duplicating them here.
CP_ENDPOINT := $(shell awk '/^control_plane_endpoint:/{print $$2}' $(ANSIBLE_DIR)/group_vars/all.yml)
CP_IP       := $(shell awk '/ansible_host=/{sub(/.*ansible_host=/, ""); print $$1; exit}' $(ANSIBLE_DIR)/inventory.ini)
INGRESS_IP  := $(shell awk '/^traefik_load_balancer_ip:/{print $$2}' $(ANSIBLE_DIR)/group_vars/all.yml)
# Ingress hostnames served by Traefik. Keep in sync with the Ingress hosts in
# the argocd role and clusters/home/apps/ (rancher, kube-prometheus-stack).
INGRESS_HOSTS := argocd.home.arpa rancher.home.arpa grafana.home.arpa

## install the Ansible collections the roles depend on
deps:
	ansible-galaxy collection install -r $(ANSIBLE_DIR)/requirements.yml

## parse, test controller-only safety gates, and lint without touching a node
check:
	cd $(ANSIBLE_DIR) && ansible-playbook --syntax-check site.yml cluster.yml platform.yml
	cd $(ANSIBLE_DIR) && \
	  ANSIBLE_ROLES_PATH="$(CURDIR)/$(ANSIBLE_DIR)/roles" \
	  ANSIBLE_REMOTE_TEMP="/tmp/homelab-ansible-remote" \
	  ansible-playbook --inventory localhost, tests/metallb_validation.yml
	cd $(ANSIBLE_DIR) && \
	  ANSIBLE_ROLES_PATH="$(CURDIR)/$(ANSIBLE_DIR)/roles" \
	  ANSIBLE_REMOTE_TEMP="/tmp/homelab-ansible-remote" \
	  ansible-playbook --inventory localhost, tests/traefik_validation.yml
	cd $(ANSIBLE_DIR) && \
	  ANSIBLE_ROLES_PATH="$(CURDIR)/$(ANSIBLE_DIR)/roles" \
	  ANSIBLE_REMOTE_TEMP="/tmp/homelab-ansible-remote" \
	  ansible-playbook --inventory localhost, tests/metrics_server_validation.yml
	cd $(ANSIBLE_DIR) && \
	  ANSIBLE_ROLES_PATH="$(CURDIR)/$(ANSIBLE_DIR)/roles" \
	  ANSIBLE_REMOTE_TEMP="/tmp/homelab-ansible-remote" \
	  ansible-playbook --inventory localhost, tests/local_path_provisioner_validation.yml
	cd $(ANSIBLE_DIR) && \
	  ANSIBLE_ROLES_PATH="$(CURDIR)/$(ANSIBLE_DIR)/roles" \
	  ANSIBLE_REMOTE_TEMP="/tmp/homelab-ansible-remote" \
	  ansible-playbook --inventory localhost, tests/argocd_validation.yml
	cd $(ANSIBLE_DIR) && ansible-lint

## install the git pre-commit hooks (lint + secret scanning)
hooks:
	pre-commit install
	@echo "Hooks installed. Run 'pre-commit run --all-files' for a full sweep."

## run the molecule scenarios (needs Docker; touches no node)
#
# Only the hardening role has a scenario. base, kubernetes_node, control_plane
# and worker need a real kernel or a live API server, so a container would prove
# nothing about them — see ansible/molecule/hardening/molecule.yml.
#
# EXPECTED NOISE: molecule prints
#   CRITICAL 'molecule/default/molecule.yml' glob failed.  Exiting.
# once at the start. It is molecule's `test` command probing for a scenario named
# `default`, which this repo does not have. It does not exit, the run proceeds
# normally, and the exit code is 0. Judge the run by the SCENARIO RECAP line.
test:
	@command -v molecule >/dev/null 2>&1 || \
	  { echo "ERROR: molecule not installed. pip install molecule molecule-plugins docker requests"; exit 1; }
	@[ -n "$(DOCKER_HOST_FROM_CTX)" ] || \
	  { echo "ERROR: no Docker context found. Is Docker running?"; exit 1; }
	cd $(ANSIBLE_DIR) && \
	  DOCKER_HOST="$(DOCKER_HOST_FROM_CTX)" \
	  ANSIBLE_ROLES_PATH="$(CURDIR)/$(ANSIBLE_DIR)/roles" \
	  molecule test -s hardening

## check SSH connectivity to all nodes
ping:
	cd $(ANSIBLE_DIR) && ansible all -m ping

## configure all nodes (idempotent, safe to re-run; also runs apt upgrade)
nodes:
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml

## bootstrap the kubeadm cluster + CNI + join workers
cluster:
	cd $(ANSIBLE_DIR) && ansible-playbook cluster.yml

## bootstrap pre-Argo cluster services (MetalLB + Traefik ingress)
platform:
	cd $(ANSIBLE_DIR) && ansible-playbook platform.yml

## reconcile Metrics Server and show current CPU/memory for every node
metrics:
	cd $(ANSIBLE_DIR) && ansible-playbook platform.yml --tags metrics
	KUBECONFIG=$(ANSIBLE_DIR)/kubeconfig kubectl \
	  --server https://$(CP_IP):6443 top nodes

## reconcile local-path-provisioner and list StorageClasses (local-path = default)
storage:
	cd $(ANSIBLE_DIR) && ansible-playbook platform.yml --tags storage
	KUBECONFIG=$(ANSIBLE_DIR)/kubeconfig kubectl \
	  --server https://$(CP_IP):6443 get storageclass

## reconcile Argo CD and its root Application (GitOps for clusters/home/)
argocd:
	cd $(ANSIBLE_DIR) && ansible-playbook platform.yml --tags argocd

## nodes + cluster in one go
all: nodes cluster

## print the /etc/hosts line this laptop needs to reach the cluster
hosts:
	@echo "The fetched kubeconfig points at $(CP_ENDPOINT), which only the nodes"
	@echo "can resolve. Add it to /etc/hosts on this laptop:"
	@echo ""
	@echo "  echo '$(CP_IP) $(CP_ENDPOINT)' | sudo tee -a /etc/hosts"
	@echo ""
	@echo "The web UIs sit behind Traefik's MetalLB address. Until local DNS serves"
	@echo "*.home.arpa (PROJECT-PLAN Phase 2.75), add them too:"
	@echo ""
	@echo "  echo '$(INGRESS_IP) $(INGRESS_HOSTS)' | sudo tee -a /etc/hosts"
	@echo ""

## show cluster state using the fetched kubeconfig
status:
	@getent hosts $(CP_ENDPOINT) >/dev/null 2>&1 || \
	  { echo "ERROR: $(CP_ENDPOINT) does not resolve on this machine."; \
	    echo "Run 'make hosts' for the line to add to /etc/hosts."; exit 1; }
	KUBECONFIG=$(ANSIBLE_DIR)/kubeconfig kubectl get nodes -o wide
	KUBECONFIG=$(ANSIBLE_DIR)/kubeconfig kubectl get pods -A

## how to start over if the cluster is broken
reset-help:
	@echo "On each node:  sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d"
	@echo "Then re-run:   make cluster"
