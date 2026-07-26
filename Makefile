.PHONY: deps check ping nodes cluster all status hosts reset-help

ANSIBLE_DIR := ansible

# Read from the single sources of truth rather than duplicating them here.
CP_ENDPOINT := $(shell awk '/^control_plane_endpoint:/{print $$2}' $(ANSIBLE_DIR)/group_vars/all.yml)
CP_IP       := $(shell awk '/ansible_host=/{sub(/.*ansible_host=/, ""); print $$1; exit}' $(ANSIBLE_DIR)/inventory.ini)

## install the Ansible collections the roles depend on
deps:
	ansible-galaxy collection install -r $(ANSIBLE_DIR)/requirements.yml

## parse and lint every playbook and role without touching a node
check:
	cd $(ANSIBLE_DIR) && ansible-playbook --syntax-check site.yml cluster.yml
	cd $(ANSIBLE_DIR) && ansible-lint

## check SSH connectivity to all nodes
ping:
	cd $(ANSIBLE_DIR) && ansible all -m ping

## configure all nodes (idempotent, safe to re-run; also runs apt upgrade)
nodes:
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml

## bootstrap the kubeadm cluster + CNI + join workers
cluster:
	cd $(ANSIBLE_DIR) && ansible-playbook cluster.yml

## nodes + cluster in one go
all: nodes cluster

## print the /etc/hosts line this laptop needs to reach the cluster
hosts:
	@echo "The fetched kubeconfig points at $(CP_ENDPOINT), which only the nodes"
	@echo "can resolve. Add it to /etc/hosts on this laptop:"
	@echo ""
	@echo "  echo '$(CP_IP) $(CP_ENDPOINT)' | sudo tee -a /etc/hosts"
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
