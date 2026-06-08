# self-2026-flux-talk

Demo repository for the talk: **"GitOps with FluxCD: Making K8s Deployments Repeatable and Reversible"**

This is a minimal but structurally faithful version of a production GitOps platform. It shows:

- `flux install` + predeclared state vs `flux bootstrap` — and why this choice matters
- Per-developer branch isolation via `${GITHUB_BRANCH}` template variable + direnv
- The three-layer Kustomization dependency chain (infrastructure → helmresources → apps)
- `postBuild.substitute` instead of base/overlays duplication
- The `$patch: delete` pattern for dev-specific resource removal
- Offline validation stack

## Prerequisites

- [minikube](https://minikube.sigs.k8s.io/docs/start/)
- [direnv](https://direnv.net/)
- [flux CLI](https://fluxcd.io/flux/installation/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/docs/intro/install/)
- [envsubst](https://www.gnu.org/software/gettext/manual/html_node/envsubst-Invocation.html) (usually included with `gettext`)

## Quick Start

```bash
# 1. Clone and configure credentials
git clone https://github.com/josephtate/self-2026-flux-talk.git
cd self-2026-flux-talk

# 2. Create your credentials file (gitignored)
cat > .envrc.${USER} << 'EOF'
export GITHUB_USER=your-github-username
export GITHUB_TOKEN=ghp_your_token_here
export GITHUB_OWNER=josephtate
export GITHUB_REPO=self-2026-flux-talk
EOF

# 3. Load environment
direnv allow .
echo $GITHUB_BRANCH   # should show your current branch

# 4. Bootstrap
make bootstrap-dev

# 5. Watch Flux reconcile
flux get kustomizations --watch
```

## Developer Workflow

```bash
git checkout -b feature/my-change
direnv allow .
make update-dev-branch   # repoints Flux to your new branch

# Make changes
vim apps/base/demo-app/deployment.yaml

git add -p
git commit -m "describe the change"
git push origin feature/my-change
# Flux picks it up in ~30s

# Revert if needed
git revert HEAD --no-edit
git push origin feature/my-change
```

## Directory Structure

```
clusters/dev/flux-system/
  gotk-sync.yaml        # GitRepository (with ${GITHUB_BRANCH}) + Kustomizations
  gotk-patches.yaml     # Resource limits for minikube

infrastructure/         # HelmRelease operators (traefik)
  base/
  dev/

helmresources/          # Resources using Helm-installed CRDs
                        # dependsOn: infrastructure (so CRDs exist first)
  self-signed-issuer.yaml   # ClusterIssuer

apps/                   # Application deployments
  base/demo-app/
    deployment.yaml     # nginx, replicas controllable for demo
    ingress.yaml
  dev/
    kustomization.yaml  # Shows $patch: delete pattern

.validation/
  external-resources.yaml   # Resources created by bootstrap, not in git

manual/scripts/
  bootstrap.sh          # flux install + envsubst + kubectl apply
```

## Why `flux install` not `flux bootstrap`?

See [manual/scripts/bootstrap.sh](manual/scripts/bootstrap.sh) — the script header explains the decision. Short version: `flux bootstrap` bakes the branch name as a literal string in committed files; `flux install` lets us keep `${GITHUB_BRANCH}` as a template variable, enabling per-developer branch isolation without any commits to main.

## Validation

```bash
make lint              # yamlfmt + shellcheck + kustomize build
make validate-kustomize  # kustomize build for all overlays
```

All validation runs offline — no cluster required. CI runs these on every PR.
