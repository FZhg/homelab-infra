# Homelab bootstrap. `make up` runs every phase in order; each phase is safe to re-run.
SHELL         := /bin/bash
.SHELLFLAGS   := -euo pipefail -c
.ONESHELL:
.DEFAULT_GOAL := help

INV  := inventory.yaml
TF   := tofu -chdir=terraform
SSH  := ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$(CURDIR)/.local/known_hosts
export KUBECONFIG := $(CURDIR)/.local/kubeconfig

ADMIN          = $(shell yq '.admin.user' $(INV))
CP_IP          = $(shell yq '[.nodes[] | select(.role == "k8s_control")][0].ip' $(INV))
K8S_NODES      = $(shell yq '[.nodes[] | select(.role == "k8s_control" or .role == "k8s_worker")] | length' $(INV))
ETCD_ENDPOINTS = $(shell yq '[.nodes[] | select(.role == "etcd") | "https://" + .ip + ":2379"] | join(",")' $(INV))
CILIUM_VERSION = $(shell yq '.versions.cilium' $(INV))

.PHONY: help up check pki tf-init openbao openbao-init unseal cluster kubeconfig cni argocd \
        openbao-k8s-auth status etcdctl argocd-password destroy

help: ## List targets
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-18s %s\n", $$1, $$2}'

up: check pki openbao openbao-init cluster kubeconfig cni argocd openbao-k8s-auth ## Bootstrap everything, in order
	@echo; echo "Lab is up. Try: make status"

check: ## Check workstation tools, token and repo URL
	@for t in tofu kubectl helm bao yq jq openssl ssh curl git; do
	  command -v $$t >/dev/null || { echo "missing tool: $$t"; exit 1; }
	done
	test -n "$${PROXMOX_VE_API_TOKEN:-}" || { echo "export PROXMOX_VE_API_TOKEN='tofu@pve!homelab=<uuid>' first"; exit 1; }
	if grep -rq 'YOU/homelab-infra' $(INV) k8s; then
	  echo "Replace YOU/homelab-infra with your repo URL in inventory.yaml and k8s/ (grep -rn YOU/ .)"; exit 1
	fi
	if grep -q 'CHANGE-ME' $(INV); then echo "Set admin.ssh_public_key in inventory.yaml"; exit 1; fi
	grep -q "$$(yq '.nodes.openbao.ip' $(INV)):8200" k8s/platform/external-secrets/cluster-secret-store.yaml ||
	  { echo "Set the OpenBao IP in k8s/platform/external-secrets/cluster-secret-store.yaml"; exit 1; }
	echo "workstation OK"

pki: ## Generate CAs, certs and the kubeadm join token (.local/pki)
	./scripts/pki.sh

tf-init:
	@$(TF) init -input=false >/dev/null

openbao: tf-init ## Phase 1: create the OpenBao VM
	$(TF) apply -target='proxmox_virtual_environment_vm.node["openbao"]'

openbao-init: ## Phase 2: init + unseal OpenBao, load secrets, create AppRoles
	./scripts/openbao.sh init
	./scripts/openbao.sh unseal
	./scripts/openbao.sh seed

unseal: ## Unseal OpenBao (needed after it reboots)
	./scripts/openbao.sh unseal

cluster: tf-init ## Phase 3: create etcd, control-plane and worker VMs
	test -f .local/approle.json || { echo "Run 'make openbao-init' first"; exit 1; }
	$(TF) apply

kubeconfig: ## Phase 4: wait for kubeadm init, fetch the admin kubeconfig
	echo "Waiting for the control plane on $(CP_IP) (10-15 min on first boot)..."
	for i in $$(seq 1 120); do
	  if $(SSH) -o ConnectTimeout=5 $(ADMIN)@$(CP_IP) sudo test -f /etc/kubernetes/admin.conf 2>/dev/null; then
	    $(SSH) $(ADMIN)@$(CP_IP) sudo cat /etc/kubernetes/admin.conf > $(KUBECONFIG)
	    chmod 600 $(KUBECONFIG)
	    echo "Wrote $(KUBECONFIG)"
	    exit 0
	  fi
	  sleep 15
	done
	echo "Timed out. Check on cp1: sudo journalctl -u puppet-apply -e"
	exit 1

cni: ## Phase 5: install Cilium, wait for all nodes to be Ready
	# Kubernetes IPAM so pod IPs come from the node CIDRs kubeadm allocated
	# (k8s_pod_subnet). kube-proxy stays; Cilium's kube-proxy replacement is off.
	helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \
	  --version $(CILIUM_VERSION) \
	  --namespace kube-system \
	  --set ipam.mode=kubernetes
	kubectl -n kube-system rollout status ds/cilium --timeout=5m
	echo "Waiting for $(K8S_NODES) nodes to register..."
	until [ "$$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -ge $(K8S_NODES) ]; do sleep 15; done
	kubectl wait --for=condition=Ready nodes --all --timeout=15m
	kubectl get nodes -o wide

argocd: ## Phase 6: install Argo CD and hand the cluster to GitOps
	kubectl apply --server-side --force-conflicts -k k8s/bootstrap/argocd
	kubectl wait --for=condition=established crd/applications.argoproj.io --timeout=180s
	# ESO needs the homelab CA to trust OpenBao. Generated per lab, so it isn't in git.
	kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n external-secrets create configmap homelab-ca \
	  --from-file=ca.crt=.local/pki/homelab-ca.crt --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k8s/bootstrap/root-app.yaml
	kubectl -n argocd rollout status deploy/argocd-server --timeout=10m
	$(MAKE) --no-print-directory argocd-password

openbao-k8s-auth: ## Phase 7: let External Secrets Operator log in to OpenBao
	./scripts/openbao.sh k8s-auth

status: ## Nodes, Argo CD apps and the demo secret
	kubectl get nodes -o wide
	kubectl -n argocd get applications
	kubectl -n demo get externalsecret,secret 2>/dev/null || true

etcdctl: ## Run etcdctl against the cluster, e.g. make etcdctl ARGS="member list -w table"
	etcdctl --endpoints=$(ETCD_ENDPOINTS) \
	  --cacert=.local/pki/etcd-ca.crt --cert=.local/pki/etcd-admin.crt --key=.local/pki/etcd-admin.key \
	  $(ARGS)

argocd-password: ## Print the initial Argo CD admin password
	echo "Argo CD admin password: $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
	echo "UI: kubectl -n argocd port-forward svc/argocd-server 8080:443  ->  https://localhost:8080"

destroy: tf-init ## Destroy every VM (keeps .local/pki)
	$(TF) destroy
	rm -f $(KUBECONFIG) .local/known_hosts .local/approle.json .local/openbao-init.json
