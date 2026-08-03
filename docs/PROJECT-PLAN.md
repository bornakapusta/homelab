# Homelab Agent-Cluster — Project Plan & Guidelines

*Owner: Borna · Last updated: August 3, 2026*

This is the master plan for building a 3-node Kubernetes homelab that hosts your own apps (GitOps) **and** runs AI coding agents in pre-warmed, disposable environments, all viewable through herdr.

It consolidates the decisions and rationale from three companion docs:
- `homelab-decision-doc.md` — why this shape (herdr vs K8s, hardware verdict).
- `linux-k8s-foundations.md` — the deep decisions (distro, kubeadm, security, disks, topology, IaC, monitoring, scheduling).
- `homelab-roadmap.md` — the detailed phase-by-phase build.
- `architecture-diagram.svg` — the visual of how it all fits + the warm-pool lifecycle.

---

## 1. Goals

1. **Learn Kubernetes properly** — the real, upstream way (not a black box).
2. **Run AI coding agents** (Claude Code, Codex; PI later) in isolated, disposable pods, pre-warmed so they start instantly, each preloaded with a project (starting example: a modern Ruby on Rails app).
3. **Host my own apps** on the same cluster, managed by GitOps.
4. **Everything as code** — reproducible nodes and cluster from a git repo; never configure a machine by hand 3×.
5. **Reachable and observable** — access from anywhere over Tailscale, with Grafana dashboards showing cluster health.

## 2. Definition of done (success criteria)

- [ ] Three identical Ubuntu nodes stood up from **one** autoinstall + Ansible run.
- [ ] A working **kubeadm** cluster with CNI, storage, ingress, and a bare-metal load balancer.
- [ ] **Argo CD** syncing all cluster state from a git repo.
- [ ] **Grafana** showing live node/pod metrics; a test alert fires.
- [ ] A **rails-dev** sandbox image; **Agent Sandbox** warm pool hands over a ready pod in ~ms.
- [ ] **herdr** on the laptop driving 2 agents in 2 warm pods at once.
- [ ] Cluster reachable from outside the house over **Tailscale**.
- [ ] At least one **hosted app** deployed via GitOps in its own namespace.
- [ ] An **etcd snapshot** taken and a restore rehearsed once.

## 3. Decisions at a glance

| Layer | Decision | Why (short) |
|---|---|---|
| Hardware | 3× OptiPlex 7050 (i5-7500T, 16 GB, 256 GB) | Enough for a learning cluster; SSD is the limit |
| Node OS | **Ubuntu Server LTS 24.04** | 5-yr support, no SELinux friction, most tutorials |
| Kubernetes | **kubeadm** (upstream) | Learn the real thing; start 1 CP + 2 workers → 3 CP + kube-vip |
| Runtime | containerd | Standard |
| CNI | Cilium | Kubernetes 1.36 support, NetworkPolicy, optional Hubble later |
| Storage | local-path (→ Longhorn later) | Simple start; watch SSD space |
| Ingress / LB | **Traefik** + **MetalLB** | Maintained HTTP ingress + bare-metal LoadBalancer |
| Hostname access | Local DNS (**AdGuard Home**/dnsmasq wildcard) → ingress IP; **ExternalDNS** + **cert-manager**; **Tailscale Split DNS** remote | Reach apps by name over HTTPS (the "internal CDN" ask — really DNS+ingress) |
| IaC | cloud-init/autoinstall → **Ansible** → **Argo CD** | Identical installs, fleet config, GitOps |
| Secrets | kubectl Secrets → **SOPS/Sealed Secrets** | Safe to keep in git |
| Topology | **One physical cluster** (namespaces + taints + quotas + NetworkPolicies) | 3 nodes can't afford a physical split; vCluster later if needed |
| Disposable envs | **Agent Sandbox** (Template/WarmPool/Claim) | Pre-warmed, isolated agent pods |
| Agents | Claude Code + Codex (PI later) | Baked into the image |
| Agent view | **herdr** on laptop | Multi-agent terminal dashboard |
| Monitoring | **kube-prometheus-stack** (Grafana) | Standard; retention capped for small SSDs |
| Scheduling | requests + metrics-server + topology spread → Descheduler → Trimaran | Distribute by load (real-usage later) |
| Remote access | **Tailscale** mesh | No bridge box needed |
| Decided out | **Talos migration — not doing it** (staying on Ubuntu + kubeadm) | Keep it simple; git makes it reproducible anyway |
| Parked (optional futures) | Hetzner box, vCluster, Loki, Trimaran | Add only if a real need appears |

## 4. Architecture (summary)

**Diagram 1 — whole project (the full stack):**

![Whole-project architecture](whole-project-diagram.svg)

**Diagram 2 — how agents run (herdr + Agent Sandbox + warm pools):**

![Agent execution and warm-pool lifecycle](architecture-diagram.svg)

*(Both diagrams are also embedded in `project-plan.html` for easy viewing.)*

In one paragraph: your laptop runs **herdr** and reaches the cluster over **Tailscale**. The **kubeadm cluster** on the three OptiPlex boxes runs **Argo CD** (GitOps for everything), the **Agent Sandbox controller** maintaining a **warm pool** of pre-booted Rails+agent pods, your **hosted apps** in separate namespaces, and **Grafana/Prometheus** monitoring. To work, you issue a **SandboxClaim**, get a hot pod instantly, and herdr `kubectl exec`s into it to run Claude Code or Codex — watching each agent go working → done. When you're finished the pod is recycled and the pool refills.

## 5. Guiding principles

1. **Everything as code, in one git repo.** If it's not in git, it doesn't exist. Nodes and cluster are rebuildable from the repo.
2. **Learn first, automate second.** Do a step by hand once to understand it, then capture it in Ansible/Argo. (This is *why* we chose kubeadm over k3s.)
3. **Climb the ladder — don't start at the top.** Single control-plane before HA; requests-based scheduling before load-aware; metrics before logs; plain warm Deployment before full Agent Sandbox if needed. Each rung is a working system.
4. **One cluster, logical isolation.** Separate concerns with namespaces, taints, quotas, and NetworkPolicies — not more hardware.
5. **Security baseline is non-negotiable** (see §7 of foundations): named sudo user, Ed25519 keys, SSH locked down, default-deny firewall, encrypted secrets, manual drained reboots.
6. **Mind the SSD.** 256 GB is the tightest resource. Lean images, capped log/metric retention, `/var` on its own LVM volume, `df -h` is your friend.
7. **Keep the blast radius contained.** `--dangerously-skip-permissions` only *inside* sandbox pods, never on the host. Spend caps on agent API keys.

## 6. The build plan (phases, tasks, done-criteria)

> Full detail in `homelab-roadmap.md`. This is the checklist view. Do phases in order; each ends in a working state.

### Phase 0 — Prep & prerequisites
- [ ] Plan node names + static IPs (DHCP reservations, e.g. `.11/.12/.13`).
- [ ] BIOS on each: USB boot, enable VT-x, AC-power-recovery = On.
- [ ] Collect keys/accounts (Anthropic, OpenAI, Tailscale) into a password manager.
- [ ] Create the infra **git repo** (`autoinstall/`, `ansible/`, `clusters/`).
- [ ] Download **Ubuntu Server 24.04 LTS** ISO, flash the USB.
- **Done:** install USB in hand, empty repo created, IP plan set.

### Phase 1 — Base OS (all three)
- [ ] Install **node-1 manually** with the LVM + separate `/var` layout, swap off.
- [ ] Harvest `/var/log/installer/autoinstall-user-data` from node-1 → commit to `autoinstall/` → use it to install nodes 2 & 3 **unattended**.
- [ ] Confirm key-only SSH from laptop to each node.
- **Done:** `ssh node1/2/3` works with keys, no passwords.

### Phase 1.5 — Ansible fleet control
- [ ] Ansible inventory of 3 hosts; `ansible all -m ping` succeeds.
- [ ] Baseline playbooks: sudo user, SSH hardening, ufw, unattended-upgrades (no auto-reboot), chrony, containerd, swap off, kernel sysctls, install kubelet/kubeadm/kubectl. ansible-vault for secrets.
- **Done:** `ansible-playbook site.yml` brings all nodes to an identical, hardened, kubeadm-ready state.

### Phase 2 — kubeadm cluster (single control-plane first)
- [ ] `kubeadm init` on node 1; join nodes 2 & 3 as workers.
- [ ] Install the pinned **Cilium** CNI chart; nodes go `Ready`.
- [ ] kubeconfig + `kubectl` + `k9s` on laptop; deploy a throwaway nginx.
- [ ] *(Later)* rebuild/expand to 3 control-plane + **kube-vip** for HA.
- **Done:** all nodes `Ready`; a test pod runs.

### Phase 2.5 — The batteries kubeadm omits
- [x] Install **MetalLB** with a confirmed LAN IP pool.
- [ ] Install **Traefik** ingress, then **local-path-provisioner** (default StorageClass).
- Traefik replaces the retired ingress-nginx project; this bootstrap uses only
  standard Kubernetes Ingress resources, not Traefik CRDs.
- **Done:** an app with a PVC is reachable via MetalLB + Ingress on the LAN.

### Phase 2.75 — Hostname access (internal DNS + TLS)
- [ ] Serve `*.home.arpa` from **local DNS** (AdGuard Home/dnsmasq wildcard, or Pi-hole) → ingress MetalLB IP.
- [ ] Install **cert-manager** for HTTPS; optionally **ExternalDNS** to auto-create records from Ingress objects.
- [ ] Later: **Tailscale Split DNS** so the same names resolve remotely.
- **Done:** `https://app.home.arpa` reaches an app by name with a locally trusted cert.

### Phase 3 — Cluster hygiene
- [ ] **etcd** snapshot save + rehearse a restore.
- [ ] Install **Argo CD**; move manifests into the git repo (app-of-apps).
- [ ] **SOPS/Sealed Secrets**; store `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`.
- [ ] Calendar reminder: `kubeadm certs renew` (~1 yr).
- **Done:** etcd snapshot exists, Argo CD syncs from git, secrets encrypted.

### Phase 3.5 — Monitoring (Grafana)
- [ ] Deploy **kube-prometheus-stack** via Argo CD in `monitoring` ns; cap retention/size for the SSDs.
- [ ] Install **metrics-server**; `kubectl top nodes` works.
- **Done:** Grafana shows live metrics; a test alert fires.

### Phase 4 — Rails sandbox image
- [ ] Dockerfile: `ruby:3.x` + node/yarn + git + postgres-client + Claude Code + Codex CLI; optional example Rails app pre-bundled.
- [ ] Push to an in-cluster registry (TLS + auth) or GHCR.
- [ ] Test as a one-off pod: Rails runs, `claude`/`codex` launch.
- **Done:** `kubectl exec` into the image → Rails + agents work.

### Phase 5 — Agent Sandbox (warm pool)
- [ ] Install controller + CRDs (`sandbox-with-extensions.yaml`).
- [ ] **SandboxTemplate** `rails-dev` (limits sized ~1–2 cores / 2–4 GB).
- [ ] **SandboxWarmPool** (start N=2).
- [ ] Decide agent node placement: **taint one node** (isolation) *or* let them spread (topology + quotas).
- [ ] Test: **SandboxClaim** → hot pod in ms → exec in → recycle → pool refills.
- **Done:** claiming a sandbox yields a warm Rails+agents pod instantly.

### Phase 6 — herdr cockpit
- [ ] Install herdr on laptop; one pane per agent = `kubectl exec` into a sandbox pod → `claude`/`codex`.
- [ ] Optional: herdr's Claude Code / Codex integrations.
- **Done:** two agents in two warm pods, both visible/controllable in herdr.

### Phase 7 — Tailscale mesh
- [ ] Tailscale on laptop + one home node as **subnet router**; approve the route.
- [ ] Keep pod-to-pod traffic on the native LAN; Tailscale only for your access.
- **Done:** from outside home you `kubectl get nodes` and drive herdr.

### Ongoing / later
- Hosted apps via GitOps in their own namespaces (do this anytime after Phase 3).
- Add **Descheduler**, then **Trimaran** (load-aware) once you observe imbalance.
- Add **Loki** for logs. Consider **Longhorn** if you add disks.
- Parked: HA control plane details, vCluster, Talos.

## 7. Repository structure

```
homelab/
├─ autoinstall/        # cloud-init user-data (identical OS installs)
├─ ansible/
│  ├─ inventory.ini
│  ├─ site.yml
│  └─ roles/           # base, hardening, containerd, kubeadm, ...
├─ clusters/
│  └─ home/
│     ├─ bootstrap/    # Argo CD install
│     ├─ platform/     # MetalLB, Traefik, monitoring, agent-sandbox
│     └─ apps/         # your hosted apps
├─ images/
│  └─ rails-dev/       # Dockerfile for the sandbox
└─ docs/               # these planning docs
```

## 8. Day-2 operating guidelines

- **Node reboots/upgrades:** always `kubectl drain <node>` → reboot → `kubectl uncordon`. Never let all nodes auto-reboot together (unattended-upgrades has auto-reboot **off**).
- **Add a node:** one line in Ansible inventory → re-run `site.yml` → `kubeadm join`.
- **Backups:** scheduled **etcd snapshots**; back up PVs that matter. Rehearse a restore.
- **Certs:** renew kubeadm control-plane certs before the ~1-year expiry.
- **Secrets:** rotate API keys periodically; keep spend caps on them.
- **Capacity:** watch Grafana for CPU/RAM pressure and `df -h` for SSD; keep images and retention lean.
- **Change flow:** edit git → Argo CD syncs. Avoid manual `kubectl apply` for anything Argo manages.

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| **SSD fills up** (images, warm pool, metrics) | `/var` on own LVM volume; lean images; cap retention; monitor `df -h`; add SSD if needed |
| **kubeadm maintenance burden** for a beginner | Start single-CP; automate with Ansible; k3s is a legit fallback |
| **Agent Sandbox is young** (API churn) | Fallback = plain Deployment of N dev pods as a manual warm pool |
| **Runaway agent starves the cluster** | resource requests/limits + quotas; taint a node for agents |
| **Secrets leak / token burn** | SOPS/Sealed Secrets; spend caps; skip-permissions only inside pods |
| **Losing HA on a node failure** | Move to 3-CP + kube-vip once comfortable; etcd snapshots |
| **Learning overload** | Follow the ladder; one phase at a time; each rung is usable |

## 10. Prerequisites checklist

- [ ] Ubuntu Server LTS ISO + a USB stick.
- [ ] Ethernet for all three nodes; router access for static leases.
- [ ] Accounts/keys: Anthropic API, OpenAI API, Tailscale, a git host (GitHub/GitLab).
- [ ] A password manager for secrets.
- [ ] Laptop tools: `kubectl`, `k9s`, `ansible`, `tailscale`, an SSH keypair (Ed25519).

## 11. Beginner glossary (quick reference)

- **Node** — one physical machine in the cluster.
- **Pod** — the smallest deployable unit; one or more containers.
- **Namespace** — a logical partition for grouping/limiting workloads.
- **Deployment** — keeps N identical pods running.
- **Service / Ingress / LoadBalancer** — how traffic reaches pods (MetalLB gives real LAN IPs on bare metal).
- **CNI** — the pod network plugin (Cilium).
- **etcd** — the cluster's database (quorum needs an odd number of control-plane nodes).
- **requests/limits** — what a pod reserves vs its hard ceiling (the scheduler places by *requests*).
- **taint/toleration** — keep pods off a node unless they explicitly tolerate it.
- **GitOps / Argo CD** — cluster state lives in git; the controller makes reality match it.
- **SandboxTemplate / WarmPool / Claim** — Agent Sandbox: env definition / pool of pre-booted pods / request for one.

## 12. Companion documents

- `homelab-decision-doc.md` — the "why this shape" decision doc.
- `linux-k8s-foundations.md` — deep decisions (distro, kubeadm, security, disks, topology, IaC, monitoring, scheduling).
- `homelab-roadmap.md` — full phase-by-phase detail with sizing and sources.
- `architecture-diagram.svg` — visual architecture + warm-pool lifecycle.

---

*Next deliverable when ready: the starter repo — autoinstall `user-data`, Ansible inventory + baseline roles, and a kubeadm role skeleton — to take you from bare metal to a cluster-ready fleet.*
