# Homelab Build Roadmap — kubeadm + Agent Sandbox + herdr

*Prepared for Borna · July 18, 2026 · Linux comfort: 3/5*

## Locked-in decisions

> **Stack updated** (see `linux-k8s-foundations.md`): base OS is **Ubuntu Server LTS 24.04**; Kubernetes is **kubeadm (standard/upstream)**, not k3s — start 1 control-plane + 2 workers, then expand to 3× control-plane + **kube-vip** for HA. kubeadm gives you no batteries, so we add CNI (Calico), storage (local-path), and ingress-nginx + **MetalLB** ourselves.

- **Hardware:** 3× Dell OptiPlex 7050 (i5-7500T, 16 GB, 256 GB NVMe). Wipe Windows on all three.
- **OS / K8s:** **Ubuntu Server LTS 24.04 + kubeadm** (upstream Kubernetes) — this is the end state. **Talos migration is parked** (optional future, not planned now).
- **Monitoring:** **kube-prometheus-stack** (Grafana + Prometheus + Alertmanager), retention/size capped for the small SSDs; Loki for logs later. (Details in `linux-k8s-foundations.md` §7.)
- **Disposable environments layer:** **Agent Sandbox** (`kubernetes-sigs/agent-sandbox`) — `SandboxTemplate` + `SandboxWarmPool` + `SandboxClaim`. Yes, this is exactly the layer you described, and we'll use it for it.
- **Agents:** Claude Code + Codex now; PI later. Baked into the sandbox image.
- **Example project:** a modern plain Ruby on Rails app.
- **Networking:** private wired LAN now. Later: **Tailscale** mesh (no bridge box needed — Tailscale handles NAT traversal itself). A home node acts as subnet router. Hetzner box is **optional** and only useful for other reasons (see Phase 7).
- **herdr:** runs on your laptop as the multi-agent dashboard; each pane is an agent living inside a warm pod (via `kubectl exec`) or reached over SSH/Tailscale.
- **Topology:** **one physical cluster** hosting *both* long-running GitOps apps and the ephemeral agent sandboxes, separated by namespaces + node taints + quotas + NetworkPolicies. **No physical two-cluster split** (kills HA on 3 nodes). **Argo CD** is the single GitOps engine for platform + apps; **vCluster** is a later option if you want true cluster-level isolation. (Reasoning in `linux-k8s-foundations.md` §5.)
- **Infrastructure as code (3 layers, all in one git repo):** **cloud-init/Ubuntu autoinstall** for identical unattended installs → **Ansible** for fleet config + kubeadm bootstrap (one command → all 3 nodes, so nothing is done 3×) → **Argo CD** for in-cluster state. (Details in `linux-k8s-foundations.md` §6.)

## How the pieces fit (target architecture)

```
   Your laptop / phone
        │  herdr (dashboard: 🔴 blocked / 🟡 working / 🔵 done)
        │  kubectl, on the Tailscale mesh
        ▼
   Tailscale mesh (direct, NAT-traversed — no bridge box)
        │
        ▼
   Home LAN
        (one home node = subnet router, advertises 10.0.0.0/24 into the tailnet)
                                              │
                          ┌───────────────────┼───────────────────┐
                          ▼                   ▼                   ▼
                     optiplex-1          optiplex-2          optiplex-3
                  (control-plane)     (worker/CP)         (worker/CP)   ← kubeadm; start 1 CP + 2 workers
                          │                   │                   │
                          └────────── kubeadm cluster ────────────┘
                                              │
                    Agent Sandbox controller (CRDs installed)
                       ├── SandboxTemplate "rails-dev"  (Ruby+Rails+Node+CLI agents baked in)
                       ├── SandboxWarmPool  (N pods kept hot → no cold start)
                       └── SandboxClaim     → hand you a ready pod in milliseconds
```

Kubernetes owns pre-warming and isolation. herdr owns the human view. Tailscale owns remote reach. Clean separation.

---

## The plan, in phases

Each phase ends in a **milestone** you can verify. Do them in order; don't skip ahead. Rough time estimates assume evenings/weekends and comfort level 3.

### Phase 0 — Prep & prerequisites (before touching the machines)
*Goal: everything staged so installs go smoothly. ~1 evening.*

- Decide node names/IPs: `optiplex-1/2/3`, static LAN IPs (set DHCP reservations on your router, e.g. `.11/.12/.13`).
- Collect accounts/keys you'll need later: Anthropic API key (Claude Code), OpenAI API key (Codex), a Tailscale account, your Hetzner box SSH access.
- On each OptiPlex: enter BIOS (**F2** at power-on; **F12** = one-time boot menu; or from Windows hold **Shift** + Restart → Troubleshoot → Advanced options → UEFI Firmware Settings):
  - **SATA Operation → AHCI** (*System Configuration*). ⚠️ Dells often ship as "RAID On", which makes the Linux installer **not see the NVMe drive**. Change this first — it's the most common install blocker.
  - **Virtualization Support** → enable VT-x + VT for Direct I/O.
  - **Power Management → AC Recovery → Power On** (nodes return after a power cut).
  - **Boot Sequence** → UEFI, USB first. Secure Boot can stay enabled (Ubuntu supports it).
- Make one Ubuntu Server LTS install USB (Rufus/balenaEtcher from your laptop). **Use 24.04 LTS** (battle-tested, supported to 2029); 26.04 LTS is also fine if you prefer the longer runway to 2031.
- Create the infra repo skeleton (`autoinstall/`, `ansible/`, `clusters/`).
- **Milestone:** three machines with known IPs planned, BIOS ready, install USB in hand, keys collected in a password manager, empty infra git repo created.

> **Autoinstall shortcut — don't hand-write the YAML.** The Ubuntu installer writes the effective autoinstall config to **`/var/log/installer/autoinstall-user-data`** after *any* install, including an interactive one. So: install **node-1 manually** (getting the disk layout right), then copy that file off, tidy it, and reuse it to install nodes 2 and 3 unattended. Far easier than authoring cloud-init from scratch as a beginner.

### Phase 1.5 — Ansible fleet control
*Goal: never configure a node by hand again. ~1 evening.*

- Install Ansible on your laptop; write the **inventory** (3 hosts) and confirm `ansible all -m ping` reaches all three.
- Write playbooks/roles for the §3 baseline (sudo user, SSH hardening, ufw, unattended-upgrades, chrony) + Kubernetes prereqs (containerd, swap off, kernel sysctls, install kubelet/kubeadm/kubectl). Use **ansible-vault** for any secrets.
- From here on, cluster steps below are **run via Ansible across all nodes**, not typed 3×.
- **Milestone:** `ansible-playbook site.yml` brings all three nodes to an identical, hardened, kubeadm-ready state.

### Phase 1 — Base OS on all three
*Goal: three clean, reachable Linux servers. ~1 evening.*

- Install **Ubuntu Server LTS** on each (minimal, install OpenSSH server, no desktop).
- Same admin user on all three; add your laptop's SSH public key; disable password SSH login.
- Set the static IPs/hostnames; run `apt update && apt upgrade`.
- Quick "learn Linux" wins at your level: practice `ssh`, `sudo`, `systemctl status`, `journalctl`, `ip a`, editing files with `nano`.
- **Milestone:** you can `ssh optiplex-1/2/3` from your laptop with keys, no password.

### Phase 2 — kubeadm cluster (start single control-plane)
*Goal: a real upstream Kubernetes cluster. ~2 evenings.*

- On all nodes: install **containerd**, disable **swap**, set the required kernel networking sysctls (`br_netfilter`, `overlay`, IP forwarding), install `kubelet`/`kubeadm`/`kubectl`.
- **Stage A:** `kubeadm init` on node 1 (single control-plane), join nodes 2 and 3 as **workers**. Simpler first cluster — get the core flow working before HA.
  - ⚠️ **Pass `--control-plane-endpoint=<dns-name-or-future-VIP>` even now**, e.g. `k8s.lab.example`. If you `init` without it, promoting to HA later means regenerating certs and effectively rebuilding the cluster. Costs nothing today, saves a painful redo at Stage B.
  - **Control-plane taint:** by default node-1 won't run your workloads. Leave that taint while learning (2 workers is plenty); remove it later with `kubectl taint nodes node-1 node-role.kubernetes.io/control-plane-` to reclaim its 16 GB / 4 cores.
- Install a **CNI**: Calico (start) or Cilium. Nodes won't go `Ready` until the CNI is up.
- Copy the admin kubeconfig to your laptop; install `kubectl` + `k9s` locally.
- Learn: `kubectl get nodes/pods -A`, `describe`, `logs`; deploy a throwaway nginx.
- **Stage B (later):** rebuild/expand to **3 stacked-etcd control-plane nodes + kube-vip** (API virtual IP) for true HA. Don't start here.
- **Milestone:** `kubectl get nodes` shows all nodes `Ready`; a test nginx pod runs.

### Phase 2.5 — The batteries kubeadm doesn't include
*Goal: replace what k3s used to give for free. ~1 evening.*

- **Bare-metal load balancer:** install **MetalLB** so `LoadBalancer` services get a LAN IP.
- **Ingress:** install **ingress-nginx**.
- **Storage:** install **local-path-provisioner** (the default StorageClass). Longhorn is a later, optional upgrade — note the 256 GB limit; watch `df -h`.
- **Hostname access (DNS + TLS):** point a **local DNS server** (AdGuard Home/dnsmasq wildcard, or Pi-hole) at the ingress MetalLB IP so apps resolve by name; add **cert-manager** for HTTPS and optionally **ExternalDNS** to auto-create records from Ingress objects. (This is the "internal CDN" ask — it's DNS + ingress, not a CDN. Details in `linux-k8s-foundations.md` §9.)
- **Milestone:** deploy an app, give it a PVC, reach it at `https://app.lab.example` by name on the LAN.

### Phase 3 — Cluster hygiene
*Goal: backups, GitOps, secrets done right. ~1–2 evenings.*

- **etcd backups:** practice `etcdctl snapshot save`/restore; schedule snapshots. (A core reason you chose kubeadm — actually do a restore once.)
- **GitOps:** put every manifest in a **git repo** from the start (Argo CD/Flux later). Makes any rebuild reproducible.
- **Secrets:** create Kubernetes Secrets for `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` now; before anything touches git, adopt **SOPS** or **Sealed Secrets**. Never bake keys into images.
- **Cert reminder:** kubeadm control-plane certs expire in ~1 year — calendar a `kubeadm certs renew`.
- **Milestone:** you have a working etcd snapshot, a git repo of manifests, and encrypted secrets.

### Phase 3.5 — Monitoring & observability (Grafana)
*Goal: see what the cluster is doing. ~1 evening.*

- Deploy **kube-prometheus-stack** via Argo CD into a `monitoring` namespace (Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics, with dashboards preloaded).
- **Tune for the small SSDs:** ~15-day retention + a `retentionSize` cap (~10–20 GB) on a local-path PVC; set resource requests/limits; schedule Prometheus off the agent-tainted node.
- Open Grafana over Tailscale/ingress; watch node CPU/RAM/disk and pod health.
- Later: add **Loki** for logs; if Prometheus feels heavy, consider **VictoriaMetrics** or offloading to **Grafana Cloud** free tier.
- **Milestone:** Grafana shows live cluster/node/pod metrics; a test alert fires.

### Phase 4 — The Rails sandbox image
*Goal: a container image = "my project, ready to code in." ~1–2 evenings.*

- Write a Dockerfile for a **Rails dev environment**: base `ruby:3.x`, plus `nodejs`+`yarn` (for asset pipeline), `git`, `postgresql-client`, `build-essential`, then the agent CLIs (`npm i -g @anthropic-ai/claude-code` and the Codex CLI). Optionally pre-create/`bundle install` an example Rails app so it's genuinely warm.
- Decide the database story: simplest for dev pods is **SQLite inside the pod**; more realistic is a **shared Postgres** running as its own pod/StatefulSet that sandboxes connect to. Start with SQLite, graduate to Postgres.
- Build the image and push it somewhere the cluster can pull it: run a tiny **in-cluster registry** or use GitHub Container Registry. (In-cluster keeps everything on the LAN.)
- Test it as a one-off pod: `kubectl run`, `kubectl exec -it`, confirm `rails new` / `rails server` works and `claude` + `codex` launch.
- **Milestone:** `kubectl exec` into a pod from this image, run the Rails app, and start Claude Code inside it.

### Phase 5 — Agent Sandbox (the disposable-environments layer)
*Goal: pre-warmed, claimable Rails environments. ~2 evenings.*

- Install the controller + CRDs: `kubectl apply -f .../releases/download/<VERSION>/sandbox-with-extensions.yaml` (single collision-free asset with extensions enabled).
- Define a **SandboxTemplate** `rails-dev` pointing at your Phase 4 image, with CPU/RAM limits sized for the OptiPlex (e.g. 1–2 cores, 2–4 GB per sandbox).
- Define a **SandboxWarmPool** that keeps N pods hot (start with N=2 given RAM/SSD limits).
- Test the flow: create a **SandboxClaim** → get a ready pod in ~milliseconds → exec in → the Rails app + agents are already there → delete the claim → the pool refills.
- **Milestone:** claiming a sandbox hands you a warm Rails+agents pod with no cold start; deleting it recycles cleanly.

### Phase 6 — herdr as the cockpit
*Goal: run and watch multiple agents across sandboxes from one screen. ~1 evening.*

- Install herdr on your laptop (`curl -fsSL https://herdr.dev/install.sh | sh`).
- Workflow: one herdr pane per agent. Each pane runs `kubectl exec -it <sandbox-pod> -- bash` then launches `claude` or `codex` inside the warm pod. herdr shows you which agents are blocked/working/done at a glance and keeps sessions alive if you disconnect.
- Optional: install herdr's official Claude Code / Codex integrations for nicer state reporting.
- For truly detached "close the laptop" work, run herdr's server on a node (or the Hetzner box) and use `herdr --remote`.
- **Milestone:** two agents working in two warm Rails sandboxes, both visible/controllable in one herdr window.

### Phase 7 — Tailscale mesh (remote access, no bridge box)
*Goal: reach the cluster securely from anywhere. ~1 evening.*

- Install Tailscale on your laptop and on at least one home node. Sign both into the same tailnet.
- Make a home node (or the router) a **subnet router** advertising your LAN (e.g. `10.0.0.0/24`) into the tailnet, and approve the route in the Tailscale admin console. Now your laptop can reach every node/service by its LAN IP from anywhere.
- **No Hetzner box needed for this** — Tailscale does its own NAT traversal (and falls back to its DERP relays if a direct connection can't form), so there's no public entry node to run or expose.
- Keep **pod-to-pod cluster traffic on the native LAN** (don't force it through Tailscale) — Tailscale is only for *your* remote access. This is the common-mistake pitfall to avoid.
- Nothing is exposed to the public internet; access is limited to devices you've added to the tailnet.
- **Milestone:** from a coffee shop, you `kubectl get nodes` and drive herdr against the home cluster over Tailscale.

**Where the Hetzner box could still earn its keep (all optional):**

- An **always-on herdr server** (`herdr --remote`) so agents keep running even when every home machine is off — though a home node already does this.
- A **self-hosted Headscale** control server if you'd rather not depend on Tailscale's coordination service (more advanced).
- Offloading **heavier build/CI** or public-facing services that you don't want on the home boxes.

None of these are required for remote access — add the Hetzner box later only if one of those needs shows up.

### Talos migration — DECIDED OUT
Not happening. The end state is **Ubuntu + kubeadm**. (Everything is still in git via Ansible + Argo CD, so the cluster stays fully reproducible regardless.)

---

## Sizing reality check (your 3× 16 GB / 256 GB)

- Reserve ~2–3 GB/node for Kubernetes + system. That leaves ~13 GB/node, ~39 GB cluster-wide for workloads.
- At 2–4 GB per Rails sandbox, a warm pool of 2–4 pods is realistic; don't over-provision the pool.
- **SSD is the real limit.** A Rails+Node+agents image can be 1.5–3 GB; warm pools and image layers add up. Watch `df -h`; keep images lean (multi-stage builds, `--no-install-recommends`). Budget a bigger SSD in one node if you scale the pool.

## Risks & things to watch

- **Agent Sandbox is young (2025–2026).** Great fit and great for learning, but expect API churn. Fallback if it fights you: a plain **Deployment** of N identical dev pods = a manual "warm pool." Same benefit, less magic.
- **Secrets hygiene:** API keys via Kubernetes Secrets/env only, never in images or git. Consider a spend cap on the API keys since agents can burn tokens.
- **`--dangerously-skip-permissions`:** only use it *inside* sandboxed pods with no host mounts (that's the whole point of the sandbox) — never on your host.
- **Single points of failure:** your in-cluster registry and shared Postgres. Fine for a lab; just know a node loss can disrupt them until rescheduled.

## Suggested learning order (so it's not overwhelming)

1. Linux/SSH basics (Phase 1) → 2. Core K8s objects: pod, deployment, service, ingress, secret, PVC (Phases 2–3) → 3. Building/running your own image (Phase 4) → 4. CRDs & the sandbox model (Phase 5) → 5. Everything else is glue. Learn just-in-time, one phase at a time.

## What I can produce next (pick any)

- A **detailed Phase 0–2 step-by-step guide** (BIOS → Ubuntu → kubeadm cluster) with exact commands for your IP plan.
- The **Rails sandbox Dockerfile** (Phase 4) ready to build.
- The **Agent Sandbox YAML** (SandboxTemplate + WarmPool + Claim) for `rails-dev` (Phase 5).
- A **one-page checklist** version of this whole roadmap to tick off as you go.

---

## Sources

- [kubernetes-sigs/agent-sandbox (GitHub)](https://github.com/kubernetes-sigs/agent-sandbox) · [Agent Sandbox docs](https://agent-sandbox.sigs.k8s.io/docs/) · [Getting started overview](https://agent-sandbox.sigs.k8s.io/docs/getting_started/overview/)
- [Running Agents on Kubernetes with Agent Sandbox — Kubernetes Blog](https://kubernetes.io/blog/2026/03/20/running-agents-on-kubernetes-with-agent-sandbox/)
- [Agent Sandbox on Kubernetes — Northflank](https://northflank.com/blog/agent-sandbox-on-kubernetes)
- [K3s Requirements](https://docs.k3s.io/installation/requirements) · [K3s Resource Profiling](https://docs.k3s.io/reference/resource-profiling) · [K3s distributed/multicloud networking](https://docs.k3s.io/networking/distributed-multicloud)
- [Tailscale + Kubernetes home lab guide — Cloud Native Now](https://cloudnativenow.com/contributed-content/tailscale-kubernetes-the-ultimate-guide-to-zero-trust-networking-in-your-home-lab/)
- [Private networking on Hetzner with Tailscale — Onat Mercan](https://onatm.dev/2026/01/28/private-networking-on-hetzner-cloud-with-tailscale/)
- [Remote access to k3s with Tailscale — Shairyar Baig](https://shairyar.github.io/posts/remote-access-to-k3s-homelab-with-tailscale/)
- [Claude Code headless / self-hosting guide — amux](https://amux.io/guides/claude-code-headless/) · [Using Claude Code with Docker](https://claudecodeguides.com/claude-code-with-docker-containers-guide/)
- [herdr (GitHub)](https://github.com/ogulcancelik/herdr) · [herdr.dev](https://herdr.dev)
