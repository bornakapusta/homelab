# metrics_server

Installs one pinned Metrics Server replica and proves that the Kubernetes
Resource Metrics API returns CPU and memory for every inventory node. The role
runs on the Ansible controller with the admin kubeconfig fetched by
`control_plane`; it installs no node package and exposes no LAN-facing service.

This is the first observability rung, not the finished monitoring stack.
Metrics Server keeps short-lived samples in memory for `kubectl top` and
autoscaling APIs. It does not retain history or report disk, filesystem,
temperature, detailed network, logs, dashboards, or alerts. The later
storage-capped Prometheus/Grafana phase remains required.

## Data path

```text
operator -> Kubernetes API -> metrics.k8s.io APIService
         -> Metrics Server on one worker's host network
         -> each node's kubelet -> current CPU/memory sample
```

The pod uses worker label `node-role.kubernetes.io/worker=worker`, host networking,
and reserved host/container port `4443`. This reuses the firewall's existing
node-to-node trust instead of opening kubelet port `10250` to the Pod CIDR.
`hostPort` prevents a rolling update from placing two listeners on the same
node. The pod retains upstream non-root, read-only-root-filesystem, dropped
capabilities, RuntimeDefault seccomp, probes, and minimal RBAC settings.

## Supply chain, ownership, and idempotency

- `group_vars/all.yml` pins the official release manifest and multi-architecture
  image index with SHA-256 values.
- The role verifies the downloaded manifest before parsing it, requires the
  exact nine upstream objects and expected transform-sensitive fields, and then
  renders YAML from parsed objects.
- Every object receives an Ansible ownership annotation and source-manifest
  checksum. If any well-known object already exists without that owner, the role
  refuses silent adoption.
- `kubectl diff` compares the complete rendered set. The role only runs
  server-side apply when that diff reports drift; an unchanged second run is
  read-only.
- After reconciliation, the role requires one ready worker pod, an Available
  `v1beta1.metrics.k8s.io` APIService, the immutable image/network contract, and
  a CPU/memory row for exactly every node in `metrics_server_cluster_hosts`.

When Argo CD later adopts Metrics Server, add the GitOps resource and remove the
role from `platform.yml` in the same change. Never leave both controllers
reconciling these objects.

## Temporary transport-security exceptions

This first rung has two independent TLS verification exceptions:

1. Metrics Server uses `--kubelet-insecure-tls` because kubeadm currently gives
   kubelets self-signed serving certificates. The operator must explicitly set
   `metrics_server_kubelet_insecure_tls_acknowledged=true`.
2. The upstream APIService uses `insecureSkipTLSVerify: true` because the simple
   deployment generates an ephemeral Metrics Server serving certificate and
   has no stable CA bundle.

Traffic remains on the trusted private node path, but these settings still
permit a compromised node or LAN-path attacker to spoof metrics or intercept
the projected Metrics Server token. Before Agent Sandbox or any other untrusted
workload runs, enable signed kubelet serving certificates with a reviewed CSR
approval/rotation procedure and give the APIService a stable CA bundle. Then
remove both exceptions and this acknowledgement.

## Operate

From the repository root:

```bash
make metrics
```

That command reconciles only the `metrics`-tagged role and ends with:

```bash
kubectl top nodes
```

Expect one row each for `node-1`, `node-2`, and `node-3`, with CPU and memory
usage. The first sample may take one or two 15-second collection intervals. Pod
samples are available separately:

```bash
KUBECONFIG=ansible/kubeconfig kubectl top pods --all-namespaces
```

Use check mode for a read-only manifest download, validation, ownership check,
and cluster diff:

```bash
cd ansible
ansible-playbook platform.yml --tags metrics --check --diff
```

## Troubleshoot

If `kubectl top` says the Metrics API is unavailable or omits a node, inspect
the complete path rather than only Deployment readiness:

```bash
KUBECONFIG=ansible/kubeconfig kubectl get apiservice v1beta1.metrics.k8s.io -o yaml
KUBECONFIG=ansible/kubeconfig kubectl -n kube-system get pods -l k8s-app=metrics-server -o wide
KUBECONFIG=ansible/kubeconfig kubectl -n kube-system logs deployment/metrics-server --tail=100
KUBECONFIG=ansible/kubeconfig kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes
```

Common boundaries are an unavailable aggregated API, a worker host-port
collision, a kubelet that is not Ready/reachable, or inventory names that no
longer match API Node names. The role prints APIService state and recent logs
when its live verification fails.

## Rollback

Rollback intentionally removes only the nine objects in the checksum-verified
manifest; it does not delete the `kube-system` namespace or unrelated
workloads. First confirm the owner annotation on the existing objects is
`ansible-metrics-server`, then run from the repository root:

```bash
kubectl --kubeconfig ansible/kubeconfig --namespace kube-system delete \
  deployment/metrics-server service/metrics-server \
  serviceaccount/metrics-server rolebinding/metrics-server-auth-reader \
  --ignore-not-found

kubectl --kubeconfig ansible/kubeconfig delete \
  apiservice/v1beta1.metrics.k8s.io \
  clusterrole/system:aggregated-metrics-reader \
  clusterrole/system:metrics-server \
  clusterrolebinding/metrics-server:system:auth-delegator \
  clusterrolebinding/system:metrics-server \
  --ignore-not-found
```

Then remove the `metrics_server` role from `platform.yml` (or revert the
feature change) before another platform run. `kubectl top` and any future HPA
that depends on resource metrics will remain unavailable after rollback.
