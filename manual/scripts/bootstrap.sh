#!/usr/bin/env bash
set -euo pipefail

# Bootstrap script for self-2026-flux-talk (dev environment only).
#
# This script intentionally uses 'flux install' rather than 'flux bootstrap github'.
# The difference matters:
#
#   flux bootstrap github: generates manifests, commits them to your repo, then
#   installs. The GitRepository branch is baked as a literal string in the
#   committed files. Per-developer dynamic branches require re-bootstrapping or
#   committing to main for each developer.
#
#   flux install: installs controllers only — no commits, no GitRepository.
#   We then apply our hand-written gotk-sync.yaml (which contains ${GITHUB_BRANCH}
#   as a template variable) via envsubst. Flux adopts this resource and manages
#   it going forward. The source of truth stays in our git file, not in a Flux-
#   generated snapshot.
#
# This approach enables the per-developer branch workflow: each developer
# bootstraps with their current feature branch, and their Flux GitRepository
# tracks that branch without any shared-branch collisions.

ENVIRONMENT="${1:-dev}"
CLUSTER_NAME="${CLUSTER_NAME:-dev-cluster}"
GITHUB_USER="${GITHUB_USER:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="${GITHUB_REPO:-self-2026-flux-talk}"
GITHUB_BRANCH="${GITHUB_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
GITHUB_OWNER="${GITHUB_OWNER:-your-org-here}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

check_prerequisites() {
    info "Checking prerequisites..."

    local missing_tools=()
    for tool in kubectl helm minikube flux envsubst; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi

    if ! kubectl cluster-info --context="$CLUSTER_NAME" &>/dev/null; then
        error "Cannot connect to Kubernetes cluster '$CLUSTER_NAME'"
        error "Run: minikube start -p $CLUSTER_NAME --driver=docker --cpus=4 --memory=8192"
        exit 1
    fi

    if [[ -z "$GITHUB_USER" || -z "$GITHUB_TOKEN" ]]; then
        error "GITHUB_USER and GITHUB_TOKEN are required"
        error "Set them in .envrc.\${USER} (gitignored)"
        exit 1
    fi

    success "Prerequisites OK (branch: $GITHUB_BRANCH)"
}

preload_flux_images() {
    info "Pre-loading Flux images into minikube to avoid slow registry pulls..."

    local images
    images=$(flux install --dry-run 2>/dev/null | grep 'image:' | awk '{print $2}' | sort -u)

    if [[ -z "$images" ]]; then
        warn "Could not determine Flux images — skipping pre-load"
        return 0
    fi

    for img in $images; do
        info "Pulling $img to host Docker cache..."
        docker pull "$img" || warn "Could not pull $img, will try from within minikube"
        info "Loading $img into minikube..."
        minikube image load "$img" -p "$CLUSTER_NAME" || warn "Could not load $img into minikube"
    done

    success "Flux images pre-loaded"
}

install_flux() {
    if flux check --context="$CLUSTER_NAME" &>/dev/null; then
        success "Flux already installed — skipping"
        return 0
    fi

    preload_flux_images

    info "Installing Flux controllers via 'flux install'..."
    info "(not 'flux bootstrap' — see script header for why)"
    flux install --context="$CLUSTER_NAME" --timeout=10m

    info "Waiting for Flux controllers..."
    kubectl wait --for=condition=ready pod -l app=helm-controller \
        -n flux-system --timeout=300s --context="$CLUSTER_NAME"
    kubectl wait --for=condition=ready pod -l app=kustomize-controller \
        -n flux-system --timeout=300s --context="$CLUSTER_NAME"
    kubectl wait --for=condition=ready pod -l app=source-controller \
        -n flux-system --timeout=300s --context="$CLUSTER_NAME"

    success "Flux controllers ready"
}

create_git_credentials() {
    if kubectl get secret flux-system -n flux-system --context="$CLUSTER_NAME" &>/dev/null; then
        success "flux-system secret already exists — skipping"
        return 0
    fi

    info "Creating git credentials secret for Flux..."
    kubectl create secret generic flux-system \
        --namespace=flux-system \
        --from-literal=username="$GITHUB_USER" \
        --from-literal=password="$GITHUB_TOKEN" \
        --context="$CLUSTER_NAME"

    success "Git credentials created"
}

create_git_source() {
    if kubectl get gitrepository self-2026-flux-talk -n flux-system --context="$CLUSTER_NAME" &>/dev/null; then
        success "GitRepository already exists — skipping"
        return 0
    fi

    info "Applying gotk-sync.yaml with branch substitution..."
    info "GITHUB_BRANCH=$GITHUB_BRANCH"

    # This is the key step: envsubst substitutes ${GITHUB_BRANCH} (and other
    # variables) into the YAML before applying. The resulting GitRepository
    # has a concrete branch name, but the source file in git keeps the template.
    # Flux adopts this resource into the flux-system Kustomization.
    export GITHUB_BRANCH GITHUB_OWNER GITHUB_REPO
    envsubst < "clusters/dev/flux-system/gotk-sync.yaml" | \
        kubectl apply -f - --context="$CLUSTER_NAME"

    info "Creating cluster-vars ConfigMap for Flux postBuild substitution..."
    kubectl create configmap cluster-vars \
        --from-literal=GITHUB_BRANCH="$GITHUB_BRANCH" \
        --from-literal=GITHUB_OWNER="$GITHUB_OWNER" \
        --from-literal=GITHUB_REPO="$GITHUB_REPO" \
        --from-literal=GHCR_USERNAME="$GITHUB_USER" \
        --namespace=flux-system \
        --context="$CLUSTER_NAME" \
        --dry-run=client -o yaml | kubectl apply -f - --context="$CLUSTER_NAME"

    success "GitRepository created — Flux will now reconcile from branch: $GITHUB_BRANCH"
}

main() {
    info "========================================="
    info "  self-2026-flux-talk bootstrap ($ENVIRONMENT)"
    info "========================================="
    info "Cluster: $CLUSTER_NAME"
    info "Branch:  $GITHUB_BRANCH"
    info "Repo:    $GITHUB_OWNER/$GITHUB_REPO"
    echo ""

    check_prerequisites
    install_flux
    create_git_credentials
    create_git_source

    echo ""
    success "Bootstrap complete!"
    echo ""
    info "Flux is now watching branch: $GITHUB_BRANCH"
    info "Monitor reconciliation: flux get kustomizations --watch"
    info "  or: kubectl get kustomizations -A -w"
}

main "$@"
