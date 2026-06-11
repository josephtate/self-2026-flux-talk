ENVIRONMENT ?= dev
CLUSTER_NAME ?= dev-cluster

.PHONY: bootstrap-dev teardown-dev lint validate-kustomize update-dev-branch minikube-start reconcile

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
	yamlfmt -lint -conf .yamlfmt.yaml .

lint-shell:
	find manual/scripts -name "*.sh" -exec shellcheck --severity=warning {} \;

lint-k8s: validate-kustomize

validate-kustomize:
	@echo "--- kustomize build clusters/dev ---"
	kustomize build clusters/dev
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

reconcile:
	flux reconcile source git self-2026-flux-talk
	flux reconcile kustomization flux-system
	flux reconcile kustomization infrastructure --with-source
	flux reconcile kustomization apps --with-source
