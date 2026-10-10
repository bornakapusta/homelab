# homelab — 3-node Kubernetes cluster (Ubuntu + kubeadm)

Infrastructure-as-code for a 3× Dell OptiPlex 7050 Kubernetes homelab.

**Division of labour:** Ansible owns the machines, kubeadm bootstrap, a small
bootstrap platform layer, and Argo CD itself. Argo CD owns everything declared
under `clusters/home/` (cert-manager, Rancher, Prometheus/Grafana). The same
object must never be reconciled by both at once.

| UI | URL | Login |
|---|---|---|
| Argo CD | https://argocd.home.arpa | `admin` + generated password ([how](#step-4--gitops-apps-rancher-grafana)) |
| Rancher | https://rancher.home.arpa | generated bootstrap password, then set your own |
| Grafana | https://grafana.home.arpa | `admin` + generated password |

All three sit behind Traefik at `192.168.178.240`. Run `make hosts` for the
`/etc/hosts` line your laptop needs until local DNS serves `*.home.arpa`.
Certificates are self-signed for now, so expect a browser warning.

```
autoinstall/   cloud-init file to install Ubuntu identically on every node
ansible/       node config + kubeadm cluster bootstrap
clusters/      Argo CD app-of-apps — one Application per Helm chart
images/        (later) the rails-dev sandbox image
```

---

## Prerequisites

On your **laptop**:

```bash
sudo apt install ansible          # or: brew install ansible / pipx install ansible
brew install helm                 # macOS; use `brew upgrade helm` for Helm 4.2.x
ssh-keygen -t ed25519             # if you don't already have a key
```

On the **nodes**: Ubuntu Server 26.04 LTS installed, reachable over SSH with your key,
static IPs (DHCP reservations), and swap either off or ignorable (a playbook disables it).

---

## Step 0 — Fill in your details

Edit these two files before running anything:

| File | What to change |
|---|---|
| `ansible/inventory.ini` | node hostnames + IPs |
| `ansible/group_vars/all.yml` | admin user, timezone, `control_plane_endpoint`, versions, `node_ips` |

Then verify Ansible can reach all three:

```bash
cd ansible
ansible all -m ping
```

Expect three `SUCCESS` / `pong` replies. If not, fix SSH before continuing.

---

## Step 1 — Configure the nodes

```bash
ansible-playbook site.yml
```

Idempotent — safe to re-run any time. This does:

- **base** — hostname, timezone, chrony time sync, useful packages, apt upgrade
- **hardening** — SSH drop-in (no root, no passwords), ufw default-deny, unattended *security* upgrades with **auto-reboot off**
- **kubernetes_node** — swap off, kernel modules + sysctls, containerd with `SystemdCgroup=true`, `kubelet`/`kubeadm`/`kubectl` installed **and version-held**

After this all three nodes are identical and kubeadm-ready.

## Step 2 — Bootstrap the cluster

```bash
ansible-playbook cluster.yml
```

- `kubeadm init` on the control-plane node (with `--control-plane-endpoint`, so you can grow to HA later without rebuilding)
- installs the pinned **Cilium** CNI chart with Kubernetes PodCIDR IPAM
- joins the workers
- fetches the kubeconfig to `./kubeconfig` on your laptop

Then:

```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes -o wide
```

All nodes should reach `Ready` within a minute or two of Cilium starting.

## Step 3 — Install the bootstrap platform services

A small bootstrap playbook installs pinned MetalLB, a minimal Traefik ingress
controller, local-path-provisioner (the default StorageClass), Metrics Server
for current CPU/memory, and finally Argo CD:

```bash
ansible-playbook platform.yml
```

The FRITZ!Box DHCP range was confirmed as `192.168.178.20-192.168.178.200`, so
the committed MetalLB pool uses `192.168.178.240-192.168.178.250`. The explicit
safety gate in `group_vars/all.yml` prevents a pool from being created before
that boundary is checked. See `roles/metallb/README.md` for the exact rollout.

MetalLB uses native Layer 2 mode here: one node answers ARP for a LoadBalancer
address and Kubernetes forwards the traffic to the selected Service pods.

Traefik then requests `192.168.178.240` from that pool and listens for HTTP/HTTPS.
Applications use ordinary Kubernetes Ingress objects with
`ingressClassName: traefik`. The complete path is:

```text
LAN client -> 192.168.178.240 -> MetalLB -> Traefik -> Ingress rule
           -> application Service -> application pod
```

The bootstrap runs one hardened Traefik replica with its dashboard, custom CRD
provider, Gateway API provider, and telemetry disabled. See
`ansible/roles/traefik/README.md` for its exact scope and rollback procedure.

Metrics Server is the first observability rung. It supplies the short-lived
Resource Metrics API used by `kubectl top`; it is not historical monitoring.
From the repository root, reconcile only that role and print every node's
current CPU/memory usage with:

```bash
make metrics
```

The worker host-network and temporary TLS-verification tradeoffs are documented
in `ansible/roles/metrics_server/README.md`.

local-path-provisioner gives PersistentVolumeClaims a home: volumes are
directories under `/var/lib/local-path-provisioner` on **workers only** (never
the control plane). A volume is tied to the node it was created on. See
`ansible/roles/local_path_provisioner/README.md`.

Argo CD is installed last, from its digest-pinned Helm chart, together with one
root Application, `homelab-root`, that watches `clusters/home/apps/` on `main`.
Reconcile only Argo CD with `make argocd`. See `ansible/roles/argocd/README.md`.

## Step 4 — GitOps apps (Rancher, Grafana)

Everything under `clusters/home/apps/` is deployed by Argo CD, not Ansible.
Each file is one Argo CD `Application` wrapping an upstream **Helm chart** at an
exact version, with images pinned by digest. **To change or add an app, edit or
add a file there and push to `main`** — Argo CD syncs it within a few minutes.
See [`clusters/README.md`](clusters/README.md) for the layout and an example.

| App | What it gives you |
|---|---|
| `cert-manager` | issues Rancher's TLS certificate |
| `rancher` | web UI to browse and inspect the cluster |
| `kube-prometheus-stack` | Prometheus + Grafana: CPU, memory, disk, network and temperatures per node, 15 days of history |

Argo-managed charts are rendered by Argo CD, so they do **not** appear in
`helm list`; check them with `kubectl -n argocd get applications` or the Argo CD
UI. Never `helm upgrade` them by hand.

First logins (passwords are generated in-cluster, never committed):

```bash
export KUBECONFIG=$PWD/ansible/kubeconfig

# Argo CD (user: admin)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# Rancher bootstrap password (Rancher then asks you to set your own)
kubectl -n cattle-system get secret bootstrap-secret \
  -o go-template='{{.data.bootstrapPassword|base64decode}}{{"\n"}}'

# Grafana (user: admin)
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o go-template='{{index .data "admin-password"|base64decode}}{{"\n"}}'
```

In Grafana, open **Dashboards → Node Exporter / Nodes** for per-server
resources, or **Kubernetes / Compute Resources / Node** for per-pod usage.

**Treat Rancher as read-only** for anything Ansible or Argo CD manages. An edit
made in its UI is either reverted by Argo CD's self-heal or silently drifts from
git. Rancher's bundled Fleet stays unused.

---

## Important notes

**`control_plane_endpoint` must resolve.** Point a DNS name (here, `k8s.home.arpa`) at
node-1's IP, or add it to `/etc/hosts` on your laptop and the nodes. Using a *name* now is
what lets you add control-plane nodes later without regenerating certificates.

**The control-plane node won't run your workloads** by default (it carries a taint).
That's fine — you have two workers. To reclaim its 16 GB later:

```bash
kubectl taint nodes node-1 node-role.kubernetes.io/control-plane-
```

**Never run exactly 2 control-plane nodes.** etcd needs a majority; with 2, losing either
breaks the cluster. Use 1 (now) or 3 (Stage B, with kube-vip).

**ufw + Kubernetes:** the playbook sets `DEFAULT_FORWARD_POLICY=ACCEPT` and fully trusts
traffic between your node IPs. This includes Cilium's VXLAN (`8472/udp`) and health
traffic (`4240/tcp` and ICMP). Without that peer trust, pod networking breaks in
confusing ways.

**Prometheus lives on node-3.** Prometheus, Grafana and the operator are pinned to
`monitoring_host` (node-3) and Prometheus' volume is bound there. Prometheus uses
the host network so its scrapes come from a node IP that ufw already trusts; the
only extra firewall rule lets Grafana reach port `9090` on node-3.

**Versions:** `group_vars/all.yml` pins Kubernetes, Cilium, MetalLB, Traefik,
local-path-provisioner, Metrics Server and Argo CD; the GitOps charts are pinned
in their files under `clusters/home/apps/`. Check current releases and their
matching digests before a bump. Rancher's chart caps the Kubernetes version
(2.15.x: `< 1.37`), so check the Rancher support matrix before bumping Kubernetes.

---

## Not included yet

- Alertmanager + phone alerts (ntfy), trusted TLS and local DNS for `*.home.arpa`
- Moving MetalLB, Traefik, local-path and Metrics Server from Ansible into Argo CD
- Agent Sandbox
- `images/rails-dev/` — the agent sandbox image
- HA control plane (kube-vip)

These come after you have a working cluster. See `PROJECT-PLAN.md` for the full roadmap.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Nodes stuck `NotReady` | Cilium not running yet — `kubectl -n kube-system get pods -l k8s-app=cilium` |
| `kubelet` crash-looping | Usually containerd cgroup mismatch — re-run `site.yml` |
| Pods can't reach each other | ufw forward policy, or pod CIDR clashing with your LAN |
| `kubectl top` is unavailable or misses a node | Inspect the Metrics APIService, Metrics Server logs, and kubelet reachability; see the role README |
| Installer can't see the disk | BIOS `SATA Operation` set to RAID — change to **AHCI** |
| `*.home.arpa` doesn't open in the browser | Missing `/etc/hosts` line — run `make hosts` |
| An Argo CD app is `OutOfSync`/`Degraded` | `kubectl -n argocd get applications`, then open the app in the Argo CD UI for the failing resource |
| Grafana shows "No data" | Prometheus targets: `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090` → http://localhost:9090/targets |
| A PVC stays `Pending` | Normal until a pod uses it (`WaitForFirstConsumer`); otherwise check `kubectl -n local-path-storage logs deploy/local-path-provisioner` |
