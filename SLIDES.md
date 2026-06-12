---
marp: true

---

<!-- theme: default -->
<!-- class: invert -->
# GitOps with FluxCD
## Making K8s Deployments Repeatable and Reversible

**Joseph Tate**
SELF 2026

Slides and code: https://github.com/josephtate/self-2026-flux-talk

---

# What Is GitOps?

- Git is the source of truth for cluster state
- A controller reconciles the cluster toward git — continuously
- Drift is automatically corrected
- If it's not in git, it doesn't belong in the cluster*

<sub>* Except in a few very special circumstances</sub>

<!-- "GitOps is the practice of using a git repository as the single source of truth for the desired state of your system. A controller — not you, not a CI job — continuously watches that repo and reconciles the live system to match." GitOps is a principle, not a product. FluxCD is one implementation. ArgoCD is another popular one. -->

---

# Why Does This Matter?

- `kubectl edit` gets reverted — git wins
- Rollback is `git revert && git push`
- Audit trail is `git log`
- Reproduce the cluster from scratch, any time

<!-- Opener: "How many people have a deploy.sh or a set of kubectl apply -f commands? How many are documented? How many are different between dev and prod?" -->
<!-- Key reassurance: if a broken config gets merged, Flux doesn't explode your cluster — it stops reconciling and holds the last known good state. The deployment stalls until you fix the commit. That's a much better failure mode than kubectl apply --all-the-things. -->

---

# FluxCD

- Pull-based: cluster reaches out to git — no inbound access needed
- Kubernetes-native: just CRDs and controllers
- Composable: Kustomize and Helm natively supported
- Manages its own upgrades through GitOps

---

# Separation of Concerns

- FluxCD owns application deployment and configuration management
- **Not** application data — bulk data has its own lifecycle, tooling, and teams
- **Not** secret contents — don't belong in git, rotate on their own schedule
- Schema migrations and data init are app concerns: sidecars, init containers, Jobs

---

# Resource Adoption

<sub>Here are the specific reasons for non-git resources</sub>

- Flux can adopt resources it didn't create: pre-existing resource + matching manifest = Flux takes over
- Secret *references* live in git (ExternalSecret, Volume mounts) — secret *contents* do not
- CA certificates, TLS certs, and issued keys are provisioned externally; Flux references them
- `prune: true` only removes what Flux applied — externally created resources (that aren't adopted) are never in its inventory

<!-- Example: Our secret scripts create full ExternalSecrets and their mount points so that we can test that the secret was created successfully and is accessible through K8s, but then it must be adopted by Flux in case the application configuration changes. -->

---

# FluxCD: Core Resources

**`GitRepository`** — where to watch
```yaml
url: https://github.com/org/repo
ref: { branch: main }
interval: 10m
```

**`Kustomization`** — what to apply, and when
```yaml
path: ./apps
dependsOn: [{ name: infrastructure }]
```

<!-- Kustomization is carrying a lot of weight here: this is the layout of all of the K8s deployment and configuration management in a single repository directory tree, processed through Kustomize for the target environment. Specifically for the production environment.-->

---

# Kustomize

- Base manifests define the canonical (ideally production) resource
- `kustomization.yaml` defines patches applied on top — the base is unchanged
- Patches can add, remove, or modify any field
- Output is the merged set, rendered at apply time

---

# Repository Layout

```
base-git-repository/
├── clusters/
│   ├── dev/flux-system/     ← GitRepository + Kustomizations (per env)
│   └── prod/flux-system/
├── infrastructure/           ← operators: traefik, cert-manager, ESO
├── apps/                     ← application HelmReleases
└── config/                   ← Vault policies, ESO config
```

---

# The Dependency Tree

```
flux-system      (Flux manages itself)
     ↓
infrastructure   wait: true
     ↓ dependsOn
apps             (IngressRoutes, resources that use operator CRDs)
```

`dependsOn` + `wait: true` — infrastructure is healthy before apps start.

---
# The Standard Path: `flux bootstrap`

- Installs Flux controllers into the cluster
- Commits `GitRepository` + root `Kustomization` to your repo
- Flux reconciles from that baseline
- Designed for: greenfield, one team, one cluster, one branch

<!-- Setup: "Flux needs a GitRepository to know where to look — but that resource lives in the repo. How does Flux know where to look before it exists?" -->
<!-- Pause after explaining what bootstrap does: "Is this a one-time operation, or does it keep overwriting your files?" — it IS genuinely one-time. After the initial commit, Flux reads from git. But the branch is baked in as a literal string. -->

---

# Our Approach: `flux install` + Predeclared State

- `flux install` — controllers only, no commits to your repo
- We write `gotk-sync.yaml` with `${GITHUB_BRANCH}`
- `envsubst` substitutes the branch at bootstrap time
- Flux adopts the resources it is supposed to; never needs to commit

<!-- GITHUB_BRANCH is set in the shell environment before bootstrap runs — automatically reflects the current git branch -->

---

# The Result

- One `clusters/dev/` directory, shared by all developers
- The branch is the per-developer identifier
- N developers × N branches × N local clusters — no conflicts
- Merge to main = deployed to prod

<!-- Key framing: flux bootstrap → Flux generates and commits, you manage alongside what it wrote. flux install → you write the template, Flux manages what you wrote. The canonical source is different. -->

---

# Why: Dev Mirrors Production

- Your local cluster runs the same Flux manifests as prod
- Same operators, same ingress, same secrets pipeline
- The merge to main is not (as much of) a leap of faith
- Reduces bad deploys, quickfix PRs
- Lets you squash debug commits before merging to main

---

# How: `bootstrap.sh` = Dev's Ansible

- Prod: Ansible provisions infrastructure before Flux starts
- Dev: `bootstrap.sh` does the same thing locally
- Creates what Flux will reference or adopt

---

# One Repo, Two Environments

```yaml
postBuild:
  substitute:
    NAMESPACE_PREFIX: "dev"
    DOMAIN:           "dev-cluster.lan"
```

```yaml
namespace: ${NAMESPACE_PREFIX}-traefik
host:       ingress.${DOMAIN}
```

One HelmRelease. Environment differences are variable values, not duplicate files.

---

# The Out-of-Scope Delta

- **Secret Contents** — Vault exists; ESO syncs from it via an ExternalSecret ConfigMap
- **Certificates** — Vault CA exists; trust-manager distributes it
- **Standalone services** — MinIO, PostgreSQL (dev stand-ins for external prod services)
- Scale is smaller. The architecture is identical.

---

# What Runs Locally

- HashiCorp Vault + External Secrets Operator
- Vault CA + trust-manager + cert-manager
- Full ingress stack with real TLS

_Deep dive: previous talk._

---

# Lessons Learned

- Fast Feedback Loops are key to rapid development
- Offline validation doesn't exist out of the box — you build it
- Cross-resource reference errors are silent until apply time
- Squash your feature branch before merging to main

<!-- Commit loop: "I tried to shortcut this with file:/// URLs and bind mounts into minikube. Multiple attempts, none worked cleanly. The push loop is the reality — plan for it." -->

---

# What do I wish was better?

- Validation should be first class in all of K8s, but especially Kustomize and FluxCD
- I couldn't figure out how to skip the "push" step
- Despite the explicit design decisions, Dev and Prod deviate
  - Keeping dev in line with prod requires constant dedication.


---

# DEMO

```bash
# 1. Show branch + direnv
echo $GITHUB_BRANCH   # → demo/live-talk

# 2. Bootstrap
make bootstrap-dev

# 3. Watch Flux
flux get kustomizations --watch

# 4. Make a change, observe, revert
git commit -am "scale demo-app" && git push
git revert HEAD --no-edit && git push
```

---

# Questions?

_Vault, PKI, External Secrets Operator, and the full secrets pipeline: previous talk._

https://github.com/josephtate/self-2026-flux-talk

<!-- Common questions:
  "Why Flux over ArgoCD?" — Both are good. Flux has no UI (some see this as a feature), composable with native K8s patterns. ArgoCD has a great dashboard.
  "Does this work multi-cluster?" — Yes, Flux has multi-tenant/multi-cluster patterns. Not covered today.
  "Can you use Flux without Helm?" — Absolutely, raw Kustomize works fine.
  "What about secrets in git?" — Next talk: Vault + External Secrets Operator. -->
