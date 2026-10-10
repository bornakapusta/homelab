# clusters/ — the GitOps layer

Argo CD deploys everything in this directory. Ansible installs Argo CD itself
(`ansible/roles/argocd`) and one root Application, `homelab-root`, which watches
`clusters/home/apps/` on the `main` branch of
`https://github.com/bornakapusta/homelab` (the repo is public, so Argo CD needs
no credentials).

```
clusters/home/apps/
  cert-manager.yaml           wave 0  cert-manager    TLS for Rancher
  rancher.yaml                wave 1  cattle-system   rancher.home.arpa
  kube-prometheus-stack.yaml  wave 1  monitoring      grafana.home.arpa
  home-dns.yaml               -       home-dns        LAN DNS at 192.168.178.241
```

Each file is one Argo CD `Application` that wraps an upstream **Helm chart**:

- `targetRevision` is an exact chart version, never a range.
- `helm.valuesObject` holds the values, with every image pinned by digest
  (`docker buildx imagetools inspect <image>` prints the index digest).
- `syncPolicy.automated` with `prune` + `selfHeal`: git is the truth, and
  manual edits in the cluster are reverted.
- Sync waves order dependencies: cert-manager (0) before Rancher (1).

## How changes reach the cluster

Push to `main`. Argo CD polls the repo (about every 3 minutes) and syncs. You
don't need to run Ansible for anything in this directory.

Argo CD renders the charts itself, so these releases do **not** show up in
`helm list`. Inspect them with:

```bash
kubectl -n argocd get applications
```

or in the UI at https://argocd.home.arpa. Never `helm install`/`helm upgrade`
something Argo CD manages: two controllers would fight over the same objects.

## Adding an app

Add one file to `clusters/home/apps/`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.example.com    # Helm repo, or oci://... registry
    chart: my-app
    targetRevision: 1.2.3                  # exact version
    helm:
      valuesObject:
        image:
          digest: sha256:...               # key name depends on the chart
        ingress:
          enabled: true
          className: traefik
          hosts: [my-app.home.arpa]
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Before committing, render it locally and check every image is pinned:

```bash
yq '.spec.source.helm.valuesObject' clusters/home/apps/my-app.yaml > /tmp/v.yaml
helm template my-app my-app --repo https://charts.example.com --version 1.2.3 \
  -f /tmp/v.yaml | grep 'image:'
```

For a chart you write yourself, keep it in this repo and point the Application
at it with `repoURL: https://github.com/bornakapusta/homelab.git` and
`path: <chart folder>` instead of `chart:`.

Workloads land on the workers, because the control plane keeps its
`NoSchedule` taint. PVCs use the default `local-path` StorageClass, which pins
each volume to the worker it was created on.

## Ownership rules

- **One controller per object.** Ansible owns `kube-system`, `metallb-system`,
  `traefik-system`, `local-path-storage` and `argocd`. Argo CD owns what is
  declared here. To move an Ansible component under Argo CD, add its
  Application and delete its role **in the same change**.
- **Rancher is read-only** for objects that Ansible or Argo CD own. Its bundled
  Fleet is unused; never create Fleet `GitRepo` objects.
- **No secrets in git.** Initial passwords are generated in-cluster; each app
  file's header says how to read its password.
- `monitoring_host` (node-3) appears in both `ansible/group_vars/all.yml` and
  the nodeSelectors in `kube-prometheus-stack.yaml`. Change both together.

## Removing an app

Deleting a file prunes its Application, but the child Applications have no
resources finalizer, so the workloads are **orphaned, not deleted**. To remove
the workloads too, first delete the app in the Argo CD UI with "Foreground"
cascade, then delete the file. Rancher also needs its own cleanup; see the
Rancher docs ("Rancher Resource Cleanup").
