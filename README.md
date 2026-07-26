# homelab — 3-node Kubernetes cluster (Ubuntu + kubeadm)

Infrastructure-as-code for a 3× Dell OptiPlex 7050 Kubernetes homelab.

**Division of labour:** Ansible owns the *machines*. Argo CD owns everything *inside* the cluster.
Once the cluster is up, you barely touch Ansible again.

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
ssh-keygen -t ed25519             # if you don't already have a key
```

On the **nodes**: Ubuntu Server 24.04 LTS installed, reachable over SSH with your key,
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
- installs **Calico** CNI, with the pod CIDR patched to match
- joins the workers
- fetches the kubeconfig to `./kubeconfig` on your laptop

Then:

```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes -o wide
```

All nodes should reach `Ready` within a minute or two of Calico starting.

---

## Important notes

**`control_plane_endpoint` must resolve.** Point a DNS name (e.g. `k8s.lab.example`) at
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
traffic between your node IPs. Without both, pod networking breaks in confusing ways.

**Versions:** `group_vars/all.yml` pins Kubernetes and Calico. Check the current releases
before your first run — the defaults were correct as of July 2026 but move on.

---

## Not included yet

- `clusters/` — Argo CD, MetalLB, ingress-nginx, cert-manager, monitoring, Agent Sandbox
- `images/rails-dev/` — the agent sandbox image
- HA control plane (kube-vip)

These come after you have a working cluster. See `PROJECT-PLAN.md` for the full roadmap.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Nodes stuck `NotReady` | CNI not running yet — `kubectl -n kube-system get pods` |
| `kubelet` crash-looping | Usually containerd cgroup mismatch — re-run `site.yml` |
| Pods can't reach each other | ufw forward policy, or pod CIDR clashing with your LAN |
| Installer can't see the disk | BIOS `SATA Operation` set to RAID — change to **AHCI** |
