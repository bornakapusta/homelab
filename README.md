# homelab — 3-node Kubernetes cluster (Ubuntu + kubeadm)

Infrastructure-as-code for a 3× Dell OptiPlex 7050 Kubernetes homelab.

**Division of labour:** Ansible owns the machines, kubeadm bootstrap, and the
small pre-Argo platform layer. Argo CD will later adopt in-cluster ownership;
the same object must never be reconciled by both at once.

```
autoinstall/   cloud-init file to install Ubuntu identically on every node
ansible/       node config + kubeadm cluster bootstrap
clusters/      (later) Argo CD app-of-apps — platform + your apps
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

## Step 3 — Install the first platform services

Until Argo CD exists, a small bootstrap playbook installs pinned MetalLB, a
minimal Traefik ingress controller, and Metrics Server for current CPU/memory:

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
in `ansible/roles/metrics_server/README.md`. Prometheus, Grafana, retained
history, dashboards, disk/network metrics, alerts, and logs remain later work.

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

**Versions:** `group_vars/all.yml` pins Kubernetes, Cilium, MetalLB, Traefik, and
Metrics Server. Check current releases and their matching digests before a bump.

---

## Not included yet

- `clusters/` — Argo CD ownership, cert-manager, full Prometheus/Grafana monitoring, Agent Sandbox
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
