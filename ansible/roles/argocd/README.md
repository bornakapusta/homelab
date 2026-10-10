# argocd

Installs one reproducible Argo CD and the single root Application that makes
`clusters/home/apps/` the source of truth for everything Argo CD manages. Helm
and kubectl run on the Ansible controller using the admin kubeconfig fetched by
`control_plane`; no package is installed on a node.

## Ownership boundary

Two controllers must never reconcile the same object, so the line is explicit:

| Owner | Objects |
|---|---|
| Ansible (`platform.yml`) | MetalLB, Traefik, Metrics Server, **Argo CD itself** |
| Argo CD (`clusters/home/`) | everything declared there, through `homelab-root` |

Argo CD does not manage its own release: a self-managing GitOps controller can
sync itself into a broken state with nothing left to repair it. Moving an
Ansible-owned component under Argo CD is a separate change that adds the
Application and removes the Ansible role together.

## What gets installed

- `argocd` namespace: server, repo-server, application-controller and Redis,
  one replica each. Dex, notifications and (scaled to zero) ApplicationSet are
  off.
- The chart's CRDs (`Application`, `AppProject`, `ApplicationSet`). Helm keeps
  them on uninstall (`helm.sh/resource-policy: keep`).
- A standard Ingress for `argocd.home.arpa` on the `traefik` IngressClass.
  `argocd-server` runs with `server.insecure: true`; TLS terminates at Traefik.
- `homelab-root`: an Application syncing `clusters/home/apps` from
  `argocd_root_repo_url` at `main`, with automated prune and self-heal. The
  repository is public, so no repository credential exists anywhere.

The root Application deliberately has **no** `resources-finalizer`. Deleting
it leaves the child Applications and their workloads running.

## Supply-chain controls

- The official OCI chart is selected by `argocd_chart_sha256`; its chart and
  application versions are checked before Helm reconciles it.
- The Argo CD and Redis images are selected by multi-architecture index digest
  (the chart renders `<repository>:<tag>`, so the digest rides in the tag).
- `validate.yml` rejects a repository URL that is not anonymous HTTPS, and a
  root path that escapes the repository.

Child Applications under `clusters/` pin exact chart versions and image
digests in their values. Argo CD cannot check a classic Helm repository chart
against a digest the way this role does, so that layer is weaker than the
Ansible-installed components — keep chart versions exact, never ranges.

## Interface and idempotency

`meta/argument_specs.yml` is the enforced interface. Pins and the repository
URL live in `group_vars/all.yml`; names, host name and the root path have role
defaults.

The role compares the deployed Helm chart, application version and complete
user-supplied values with the desired dictionary. An unchanged run performs
read-only checks, and the root Application apply reports `unchanged`.

```bash
make argocd      # or: make platform
```

First login: user `admin`, password from

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

Change it, then delete that Secret. `argocd.home.arpa` must resolve to the
Traefik address on your laptop (`make hosts`).

## Rollback

Removing Argo CD stops all GitOps reconciliation; workloads it created keep
running unmanaged. Delete the root Application first so nothing is half-synced,
then uninstall:

```bash
kubectl --kubeconfig ansible/kubeconfig -n argocd delete application homelab-root
helm uninstall argocd \
  --namespace argocd \
  --kubeconfig ansible/kubeconfig \
  --kube-apiserver https://192.168.178.11:6443 \
  --wait
```

The CRDs remain (resource-policy keep). Remove them only after every child
Application is gone, because deleting the `applications.argoproj.io` CRD deletes
every Application object with it.
