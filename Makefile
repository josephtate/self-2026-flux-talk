ENVIRONMENT ?= dev
CLUSTER_NAME ?= dev-cluster
NAMESPACE_PREFIX ?= dev

.PHONY: bootstrap-dev teardown-dev lint validate-kustomize update-dev-branch minikube-start reconcile open-app

# ── Bootstrap / Teardown ─────────────────────────────────────────────────────

bootstrap-dev: minikube-start
	./manual/scripts/bootstrap.sh dev

teardown-dev:
	minikube delete -p $(CLUSTER_NAME)

minikube-start:
	@if ! minikube status -p $(CLUSTER_NAME) | grep -q "Running"; then \
		echo "Starting minikube cluster $(CLUSTER_NAME)..."; \
		minikube start -p $(CLUSTER_NAME) --driver=docker --cpus=4 --memory=8192; \
	else \
		echo "Minikube cluster $(CLUSTER_NAME) already running"; \
	fi

# ── Branch management ─────────────────────────────────────────────────────────

# Update the GitRepository to track a new branch without full re-bootstrap.
# Run after switching to a new feature branch: make update-dev-branch
update-dev-branch:
	@echo "Updating GitRepository to track branch: $(GITHUB_BRANCH)"
	envsubst < clusters/dev/flux-system/gotk-sync.yaml | \
		kubectl apply -f - --context=$(CLUSTER_NAME)
	@echo "Flux will now reconcile from branch: $(GITHUB_BRANCH)"

# ── Validation ────────────────────────────────────────────────────────────────

lint: lint-yaml lint-shell lint-k8s

lint-yaml:
	yamllint .

lint-shell:
	find manual/scripts -name "*.sh" -exec shellcheck --severity=warning {} \;

lint-k8s: validate-kustomize

validate-kustomize:
	@echo "--- kustomize build clusters/dev/flux-system ---"
	kustomize build clusters/dev/flux-system
	@echo "--- kustomize build infrastructure ---"
	kustomize build infrastructure
	@echo "--- kustomize build apps ---"
	kustomize build apps
	@echo "All kustomize builds succeeded"

# ── Flux operations ───────────────────────────────────────────────────────────

flux-status:
	flux get kustomizations -A
	flux get helmreleases -A

flux-watch:
	flux get kustomizations --watch

open-app:
	@echo "Opening http://localhost:8080 — Ctrl-C to stop"
	kubectl port-forward -n $(NAMESPACE_PREFIX)-demo-app svc/demo-app 8080:80 --context=$(CLUSTER_NAME)

reconcile:
	flux reconcile source git self-2026-flux-talk --timeout=30s
	flux reconcile kustomization flux-system --timeout=30s
	flux reconcile kustomization infrastructure --with-source --timeout=30s
	flux reconcile kustomization apps --with-source --timeout=30s
