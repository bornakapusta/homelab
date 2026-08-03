# traefik

Installs one reproducible Traefik ingress-controller replica after MetalLB is
healthy. Helm and kubectl run on the Ansible controller using the admin
kubeconfig fetched by `control_plane`; no package is installed on a node.

The bootstrap is intentionally small. It enables only standard Kubernetes
`Ingress`, creates a non-default `traefik` IngressClass, and exposes HTTP/HTTPS
through a single MetalLB address. The dashboard, Traefik CRD provider, Gateway
API provider, anonymous telemetry, and version checks are disabled.

## Traffic path

```text
LAN client
  -> 192.168.178.240 (MetalLB)
  -> traefik-system/traefik Service
  -> Traefik pod
  -> an Ingress rule
  -> an application Service
  -> application pod
```

MetalLB makes the address reachable on the LAN. Traefik is the HTTP router that
reads Ingress rules and chooses the application Service. They solve different
parts of the path and both are required.

## Supply-chain and security controls

- The official OCI Helm chart is selected by `traefik_chart_sha256`; its chart
  and application versions are checked before Helm can reconcile it.
- The multi-architecture proxy image is selected by immutable OCI index digest.
- The pod runs as UID/GID 65532, drops all Linux capabilities, blocks privilege
  escalation, and uses a read-only root filesystem.
- The dashboard and non-standard API providers are disabled.
- The Service explicitly requests `lan-pool` and `192.168.178.240`; the role
  rejects an address outside the confirmed MetalLB range.

## Interface and idempotency

`meta/argument_specs.yml` is the enforced interface. The operator-owned pins and
LAN address live in `group_vars/all.yml`; safe names and the kubeconfig path have
role defaults.

The role compares the deployed Helm chart, application version, and complete
user-supplied values with the desired dictionary. An unchanged run performs
read-only cluster checks and does not contact the OCI registry or restart the
controller. Drift causes a Helm upgrade with rollback-on-failure.

Run from the repository root:

```bash
make platform
```

Applications opt in explicitly:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example
spec:
  ingressClassName: traefik
  rules: []
```

TLS certificates and authentication are separate layers. Add cert-manager and
the chosen SSO proxy only after plain HTTP routing has been verified.

## Rollback

Removing Traefik immediately stops every application reached through its
Ingress rules. When that interruption is intentional, run from the repository
root:

```bash
helm uninstall traefik \
  --namespace traefik-system \
  --kubeconfig ansible/kubeconfig \
  --kube-apiserver https://192.168.178.11:6443 \
  --wait
```

MetalLB remains installed and the address returns to its pool. The later Argo CD
phase should adopt this release and exact values; after adoption, do not let
both Argo CD and Ansible reconcile the same Helm release.
