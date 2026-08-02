# Linux & Kubernetes Foundations + Best-Practices Validation

*Prepared for Borna · July 18, 2026 · Linux comfort: 3/5*

This doc settles the OS-level and Kubernetes-distribution decisions, defines the server/network admin baseline (users, security, disks), and validates the whole plan against current best practices.

---

## 1. Distro: Ubuntu Server LTS vs Fedora Server

**Recommendation: Ubuntu Server LTS (24.04).** Fedora Server is a fine OS, but it's the wrong tool for a *stable cluster base you'll maintain for years*.

| | Ubuntu Server LTS | Fedora Server |
|---|---|---|
| Support lifecycle | **~5 years** per LTS — set-and-forget | **~13 months** — forced version jumps, reinstall/upgrade churn on all 3 nodes |
| SELinux | Not enabled by default → **fewer surprises** | Enforcing by default → must label `/var/lib/etcd`, `/etc/kubernetes/pki`, `/etc/cni/net.d` or run permissive; extra friction for a beginner |
| kubeadm tutorials | The **most** community docs/Q&A target Ubuntu | Fewer, and often assume you'll wrestle SELinux |
| Package freshness | Older but stable (fine — Kubernetes bundles its own bits) | Very fresh kernel/userland (nice, but you rarely need it for K8s) |
| Auto security updates | `unattended-upgrades` | `dnf-automatic` |

The deciding factor is **lifecycle**. Fedora's ~13-month window means you'd be doing disruptive OS upgrades on a live cluster roughly yearly — exactly the kind of churn you don't want while *also* learning Kubernetes. Ubuntu LTS lets the OS fade into the background so you focus on the cluster.

*(Aside: Debian 12 is an even more minimal, rock-stable alternative and a legitimate choice. But since you asked Ubuntu vs Fedora, and Ubuntu has the broadest tutorial coverage, go Ubuntu LTS.)*

---

## 2. "Why k3s? Let's use standard Kubernetes."

Good instinct — and given your goal, **I now recommend switching to kubeadm (vanilla/upstream Kubernetes).** Here's the honest reasoning, including where I was wrong to default to k3s.

### First, clear up a myth
k3s **is** real, CNCF-conformant Kubernetes — same API, same objects. It's not a "lite/fake" version. What k3s does is *package* Kubernetes as a single binary with batteries included (Flannel CNI, CoreDNS, Traefik ingress, ServiceLB, local-path storage) and hide the control-plane internals. In HA mode (our `--cluster-init` plan) it even uses embedded **etcd**, not SQLite.

### So why move to kubeadm anyway?
Because your stated goal is **"learn Kubernetes,"** and there the packaging that makes k3s easy is exactly what hides the things worth learning:

- **kubeadm is what the industry (and the CKA exam) treats as "standard" Kubernetes.** Skills transfer directly to production clusters.
- **It forces you to assemble the parts yourself** — container runtime, CNI, storage, ingress, load balancing — which is where the real understanding lives.
- **You practice etcd for real:** stacked etcd across 3 control-plane nodes, quorum, and snapshot backup/restore.
- **It's the foundation the rest of the stack assumes.** Skills and manifests transfer directly to any real Kubernetes you touch later.

### What you're signing up for (the honest cost)
kubeadm is "Kubernetes the hard way (lite)." Versus k3s you take on:

- Installing the selected **Cilium CNI** yourself for pod networking and NetworkPolicy.
- Installing **storage** yourself (**local-path-provisioner** to start; Longhorn later).
- Installing **ingress + bare-metal load balancer** yourself (**ingress-nginx** + **MetalLB** — k3s gave you Traefik/ServiceLB for free).
- **HA control plane needs a virtual IP** in front of the API servers (**kube-vip** is the homelab standard). This is the single biggest added complexity.
- **Certificate maintenance:** kubeadm control-plane certs **expire after 1 year** — you'll renew them (kubelet certs auto-rotate).
- **Manual version upgrades** node-by-node.

Your hardware clears kubeadm's bar easily (needs 2+ cores / 2 GB per node; you have 4 cores / 16 GB).

### Recommended learning ladder (important)
Don't start with full 3-node HA — the API-server VIP (kube-vip) is a lot for a first cluster. Instead:

1. **Stage A:** 1 control-plane node + 2 workers. Simpler, gets you a working cluster fast, teaches the core flow.
2. **Stage B:** once comfortable, rebuild/expand to **3 stacked-etcd control-plane nodes + kube-vip** for real HA.

**Fallback:** if kubeadm maintenance becomes a drag and you'd rather focus on the *agent* project than cluster plumbing, k3s remains a perfectly legitimate, conformant choice — no shame in it. But for "learn Kubernetes," kubeadm is the right call and I endorse your instinct.

---

## 3. Server & network administration baseline

Apply this identically on all three nodes (automate later with Ansible — itself a great learning exercise).

### 3.1 Users & access
- **No day-to-day root.** Create **one named sudo user** (e.g. `borna`) on every node; same username everywhere.
- SSH key type: **Ed25519** (`ssh-keygen -t ed25519`). Put your laptop's public key in `~/.ssh/authorized_keys`.
- Consider a separate **`deploy`/automation user** later for Ansible; keep it key-only too.
- `sudo` with a password is safer than passwordless; use passwordless only for a locked-down automation account if needed.

### 3.2 SSH hardening (`/etc/ssh/sshd_config`)
- `PermitRootLogin no`
- `PasswordAuthentication no`
- `KbdInteractiveAuthentication no`
- `PubkeyAuthentication yes`
- Once Tailscale is in place: **bind SSH to the tailnet IP** so it isn't reachable from the LAN broadly.
- Reload with `systemctl reload ssh`. Keep an existing session open when you test, so a mistake doesn't lock you out.

### 3.3 Firewall
- Use **ufw**, **default deny incoming**, allow outgoing.
- **Trust the three node IPs among themselves** — Kubernetes needs many inter-node ports open (API `6443`, etcd `2379-2380`, kubelet `10250`, `kube-scheduler`/`controller` `10257`/`10259`, NodePorts `30000-32767`, plus Cilium VXLAN `8472/udp`, health `4240/tcp`, and ICMP). Simplest robust rule: `ufw allow from <each node IP>` to fully trust node-to-node, and only expose SSH (from LAN/tailnet) and your ingress ports to everything else.
- Don't hand-punch every K8s port on the public side — nothing should be public anyway (LAN + Tailscale only).

### 3.4 Patching
- Enable **`unattended-upgrades` for security patches only.**
- **Disable automatic reboots** (`Unattended-Upgrade::Automatic-Reboot "false";`). On a cluster you want to `kubectl drain` a node, then reboot it yourself, one at a time — never let all three auto-reboot together.

### 3.5 fail2ban
- Optional. Once password auth is off, SSH brute-force is basically impossible, so its value is mostly quieter logs and protecting any app logins you expose later. Low priority.

### 3.6 Time sync
- Ensure **chrony** (or `systemd-timesyncd`) is active. Clock skew breaks **etcd** and **TLS certificates** — non-negotiable for a cluster.

### 3.7 Disks & storage layout
Single 256 GB NVMe per node. Recommendations:

- **Swap: OFF.** kubeadm's kubelet refuses to start with swap on by default (`--fail-swap-on=true`), and it's the simplest, most-documented setup. (Newer K8s *can* use swap, but keep it off while learning.)
- **Use LVM** during install so you can resize/carve volumes later without reinstalling.
- **Separate `/var` (or at least `/var/lib/containerd` + `/var/lib/kubelet`) onto its own logical volume.** Container images, writable layers, pod logs, and emptyDir volumes all land under `/var`; isolating it means a runaway image pull or log flood **can't fill `/` and crash the node.** This is the single most valuable disk decision on small SSDs like yours.
- **Filesystem: ext4** (simple, well understood) or xfs. ext4 is fine.
- **Monitor free space** (`df -h`) — 256 GB is tight once warm pools + image layers pile up (see roadmap sizing note). Keep images lean.
- **Encryption (LUKS):** best practice, but full-disk encryption on headless nodes means entering a passphrase at every boot (or setting up TPM/network unlock). For boxes physically inside your home, this is **optional**; skip it now, revisit if the hardware ever leaves the house.
- **imagefs split** (putting the container image store on a separate filesystem so K8s manages `imagefs`/`nodefs` independently) is a nice-to-have; the `/var` separation above already gets you most of the benefit.

---

## 4. Best-practices validation pass over the whole plan

Things to fix or add now that we're on kubeadm, so the build is sound:

1. **Control-plane HA needs kube-vip** (or keepalived+haproxy) for the API-server virtual IP. Added to the ladder above — start single-CP, add this at Stage B.
2. **Pick your stack add-ons deliberately (kubeadm gives you none):** CNI = Cilium; storage = local-path-provisioner → Longhorn later; ingress = ingress-nginx; bare-metal LB = **MetalLB** (needed for `LoadBalancer` services on your LAN).
3. **GitOps from day one.** Keep every manifest in a **git repo** (later: Argo CD or Flux). Makes any rebuild reproducible instead of a from-scratch redo.
4. **Don't put raw Secrets in git.** Since you're going GitOps, use **SOPS** or **Sealed Secrets** for the Anthropic/OpenAI keys. Plain `kubectl` Secrets are fine while local-only, but adopt encryption before anything hits git.
5. **etcd backups.** Learn `etcdctl snapshot save` and schedule it (a CronJob or a host cron). This is a core reason to run kubeadm — actually practice restore once.
6. **Certificate expiry reminder.** kubeadm control-plane certs expire in ~1 year — set a calendar reminder to `kubeadm certs renew`.
7. **Registry security.** Your in-cluster image registry should have **TLS + auth**, not be wide open on the LAN.
8. **Resource requests/limits** on the sandbox pods (already noted) so a runaway agent can't starve a node.
9. **Observability (later phase).** Add **Prometheus + Grafana** (kube-prometheus-stack) once the cluster is stable — you'll want to *see* CPU/RAM/disk pressure on these small nodes.
10. **Node reboots are manual & drained** (see 3.4) — add "drain → reboot → uncordon" to your operating habits.

### Revised phase impact (supersedes roadmap Phases 2–3)
- **Phase 2** becomes: install containerd + kubeadm/kubelet/kubectl, disable swap, kernel networking sysctls, `kubeadm init` (single CP first), install **Cilium CNI**.
- **New Phase 2.5:** install **MetalLB** + **ingress-nginx** + **local-path-provisioner** (the batteries k3s used to include).
- **Phase 3** adds: etcd snapshot backups, GitOps repo, SOPS/Sealed Secrets. HA (3× CP + kube-vip) is an explicit later step, not the starting point.

Everything downstream — the Rails sandbox image, Agent Sandbox warm pool, herdr, Tailscale — is unchanged by moving to kubeadm.

---

## 5. One cluster or two? (running GitOps-hosted apps alongside the agents)

You'll run two *kinds* of workload: **long-running hosted apps** (managed by GitOps) and **ephemeral agent sandboxes** (warm pools that churn). The question is whether they share a cluster.

**Recommendation: one physical cluster, separated logically — do NOT physically split your 3 nodes into two clusters.**

### Why not two physical clusters
With only three nodes, a physical split is the weakest option:

- **It destroys HA.** Two clusters from three nodes means something like 2+1 — neither side has a real HA control plane (etcd quorum needs 3). You'd have two fragile clusters instead of one solid one.
- **It fragments tiny resources.** 48 GB / 12 cores split in two leaves each half cramped; you can't lend capacity across the boundary when the agent pool spikes.
- **It doubles the ops burden** — two control planes, two upgrades, two backups, two CNIs, two sets of certs to renew — exactly the toil you don't want while learning.
- Multiple clusters are justified by *hard* isolation needs (separate tenants, compliance, blast-radius). Your two workload types are both *yours* on a home LAN — that bar isn't met.

### How to separate them *within* one cluster
Namespaces alone don't isolate (pods can talk across them and share node resources by default). Layer these on — each is a great learning topic:

- **Namespaces** per concern: e.g. `apps-*` for hosted apps, `agents`/`sandboxes` for the warm pool, `platform` for Argo CD/MetalLB/ingress.
- **Node taints + labels:** taint one node `workload=agents:NoSchedule` and give sandbox pods the matching toleration, so a runaway warm pool **can't starve your hosted apps**. Hosted apps schedule on the other nodes.
- **ResourceQuotas + LimitRanges** per namespace: cap how much CPU/RAM the agents namespace can consume cluster-wide.
- **NetworkPolicies:** default-deny, then allow only what each namespace needs (agents shouldn't reach your apps' databases, etc.).
- **RBAC:** scope access per namespace.

### GitOps ties it together
Run **one Argo CD** (in the `platform` namespace) as the single GitOps engine for *both* the platform components and your hosted apps, using the **app-of-apps** pattern from your git repo. (Flux is a fine alternative; Argo CD's UI is friendlier for a beginner.) This is the "run GitOps on the server to host apps" piece — it manages the cluster it lives on.

### If you genuinely want the "two clusters" experience later → vCluster
**vCluster** (loft-sh) runs fully isolated *virtual* clusters inside your one physical cluster — each with its own API server and RBAC, indistinguishable from a real cluster, but sharing the underlying nodes. It gives you the isolation and the multi-cluster learning (even different K8s versions, cluster-scoped CRDs without conflicts) **without splitting your hardware or losing HA.** Argo CD can deploy into each vCluster.

Good later-phase move: a `vc-apps` and `vc-agents` virtual cluster on top of the physical one. Add it once the base cluster is solid — it's an extra layer, not a starting point.

**Bottom line:** one physical cluster → namespaces + taints + quotas + NetworkPolicies now → one Argo CD for GitOps → vCluster later if you want true cluster-level separation. Skip the physical two-cluster split entirely.

## 6. Infrastructure as code & managing 3 nodes without doing everything 3×

This is exactly the right instinct, and there's a clean, layered answer. Think of it as **three planes**, each declarative and stored in **one git repo** (that repo *is* your infrastructure):

### Layer 1 — Identical OS installs: cloud-init / Ubuntu autoinstall
Instead of clicking through the Ubuntu installer three times, put an **autoinstall** file (`user-data`, which is cloud-init) on the install USB. Every machine then installs **unattended and identically**: same username, your SSH key, base packages, the **LVM + separate `/var`** disk layout from §3.7, swap off, timezone. Flash once, boot each box, walk away — three identical machines, zero manual clicking.

### Layer 2 — Node configuration & fleet management: Ansible
**Ansible is the answer to "manage 3 machines, don't do it 3×."** It's agentless (just SSH + your key), runs from your laptop, and is written in YAML. You keep an **inventory** of the three hosts and **playbooks** that describe the desired state; one command applies to all three at once:

```
ansible-playbook -i inventory.ini site.yml      # configure ALL nodes identically
ansible all -m ping                              # health-check the fleet
ansible all -a "uptime"                          # ad-hoc command on all 3
```

Playbooks are **idempotent** (safe to re-run) and version-controlled, so a node is reproducible from git. Ansible handles everything node-level from §3: create the sudo user, SSH hardening, ufw, unattended-upgrades, chrony, containerd, kernel sysctls, install `kubelet`/`kubeadm`/`kubectl`, then `kubeadm init` on the first node and join the rest. Adding a 4th node later = add one inventory line, re-run. Upgrades and patching become one rolling playbook (drain → upgrade → uncordon).

- **Secrets in the repo:** use **ansible-vault** (or SOPS) to encrypt keys/tokens so the repo stays safe to push.
- **Two ways to do the cluster bootstrap:**
  - **Write your own kubeadm playbooks (recommended for you).** You encode each kubeadm step yourself → you actually *learn* Kubernetes, which was the whole point of choosing kubeadm.
  - **Kubespray** (kubernetes-sigs) — a mature Ansible project that does OS prep + containerd + kubeadm + CNI in one resumable command (~15 min to a cluster). Production-grade and reliable, but it *abstracts* the details, so it fights the learning goal. Keep it as a reference / "graduate to it" option, not the first pass.

### Layer 3 — Everything inside the cluster: Argo CD (GitOps)
Ansible's job ends at "a working cluster exists." From there, **Argo CD** (already decided, §5) syncs all in-cluster state from git — platform components (MetalLB, ingress-nginx, Agent Sandbox), your hosted apps, namespaces, quotas, NetworkPolicies. Change git → cluster converges. No `kubectl apply` by hand.

### Where Terraform fits (mostly: not yet)
Terraform provisions *infrastructure* (VMs, cloud resources, DNS). Your three boxes already exist, so Terraform has little to do on bare metal now. It becomes useful later for things with an API — Tailscale ACLs, Cloudflare DNS, or if you ever add Hetzner VMs. Skip it for the initial build.

### The clean end-state
```
git repo  ─┬─ autoinstall/     (cloud-init: identical OS installs)
           ├─ ansible/         (fleet config + kubeadm bootstrap)   ← Layer 2
           └─ clusters/        (Argo CD app-of-apps: platform + apps) ← Layer 3
```
Everything is code; a node or the whole cluster is rebuildable from this repo — reinstall Ubuntu, run Ansible, let Argo CD sync, and you're back.

## 7. Monitoring & observability (Grafana)

**Recommendation: `kube-prometheus-stack`, deployed via Argo CD, tuned for small nodes.** This is the standard "Grafana setup" for Kubernetes — a single Helm chart bundling everything:

- **Prometheus** — metrics database (scrapes the cluster).
- **Grafana** — dashboards (your UI), pre-loaded with cluster/node/pod dashboards out of the box.
- **Alertmanager** — routes alerts (email, ntfy, Discord, Slack).
- **node-exporter** — per-node CPU/RAM/disk/network metrics.
- **kube-state-metrics** — Kubernetes object state (deployments, pods, PVCs…).

Put it in a `monitoring` namespace and let **Argo CD** manage it like everything else (GitOps).

### Tuning for your 3× 16 GB / 256 GB nodes
Prometheus is not tiny, so cap it deliberately:

- **Retention: ~15 days**, and set a **`retentionSize`** cap (e.g. 10–20 GB) so it can't fill the SSD. For a small cluster, ~10–20 GB PVC is plenty.
- Give Prometheus a **PVC on local-path**; budget ~1–2 GB RAM for it and ~512 MB for Grafana. Set resource requests/limits so monitoring can't starve workloads.
- Schedule Prometheus on a node with headroom — **not** the node you taint for agent sandboxes.
- Add **Grafana Loki** for logs **later** (indexes labels only, so it's light on storage) — same Grafana, one place for metrics + logs. Start with metrics; add logs once stable.

### If the footprint bites (fallbacks)
- **VictoriaMetrics** (`victoria-metrics-k8s-stack`) — a drop-in Prometheus replacement with markedly lower CPU/RAM and better compression; the closest "lighter kube-prometheus-stack." Good graduate-to if Prometheus feels heavy on the SSDs.
- **Grafana Cloud free tier** — run only lightweight agents (Grafana Alloy) on-cluster and ship metrics/logs *off* your nodes. Near-zero local storage/compute cost; tradeoff is data leaves your LAN and free-tier limits apply.

**Plan:** start with kube-prometheus-stack (learn the standard, keep data local), retention/size capped, via Argo CD → add Loki for logs → switch to VictoriaMetrics or Grafana Cloud only if resource pressure shows up in the very dashboards you just built.

## 8. Distributing pods to where hardware usage is lower (scheduling)

Kubernetes does this for you, but there's a **critical catch to understand up front:** the built-in scheduler places pods based on **resource *requests* (what a pod reserves)**, *not* on the node's **actual live CPU/RAM usage.** A node can look "empty" by requests while actually running hot, and vice-versa. Getting this right is layered:

### Layer 1 — the foundation (do this first, it's 80% of the win)
- **Set accurate `requests` and `limits` on every pod.** Without requests the scheduler is flying blind and will pile things up. `requests` = what the scheduler reserves and spreads on; `limits` = the hard ceiling.
- **Install `metrics-server`** (also needed for `kubectl top`, HPA, and the load-aware tools below).
- With good requests, the **default kube-scheduler already spreads** pods toward the node with the most free (requested) capacity — its default scoring favors *least-allocated* nodes.

### Layer 2 — spread things evenly on purpose
- **Pod Topology Spread Constraints** — tell Kubernetes "spread replicas of this app across the 3 nodes" instead of stacking them.
- **podAntiAffinity** — "don't put two of these on the same node."
- These give you even, resilient distribution across your three OptiPlex boxes.

### Layer 3 — schedule by *real* utilization (the literal "where usage is lower")
Because Layers 1–2 are requests-based, the true answer to "put pods where hardware usage is actually lowest" is a **load-aware scheduler**:

- **Trimaran** (kubernetes-sigs `scheduler-plugins`) — plugins like **TargetLoadPacking** and **LoadVariationRiskBalancing** score nodes by **actual measured load**, read from **metrics-server or your Prometheus** (which you'll already run for monitoring). This is the real "place on the least-loaded node" behavior.
- Alternatives in the same space: **Koordinator** and **Crane**.

### Layer 4 — rebalance what's already running
Scheduling only decides placement *at creation*. To fix drift over time:
- **Descheduler** (`LowNodeUtilization`) — periodically evicts pods off imbalanced nodes so they reschedule elsewhere. **Note:** its default is *requests*-based too; for actual-load rebalancing use **Koordinator's load-aware descheduling**.

### Complementary autoscaling (not distribution, but related)
- **HPA** scales the *number* of replicas up/down based on load. **VPA** right-sizes a pod's requests over time. (Cluster Autoscaler doesn't apply — your node count is fixed at 3.)

### Recommended ladder for your homelab
1. **Now:** accurate requests/limits + `metrics-server` + topology spread constraints → the default scheduler already distributes well and you learn the core mechanics.
2. **Next:** add the **Descheduler** for periodic rebalancing.
3. **Advanced/optional:** add **Trimaran** (fed by your Prometheus) for true real-load-aware placement — do this *after* monitoring is up and you've actually observed imbalance, not before.

### One tension to decide (agents vs balance)
Earlier we suggested **tainting one node for the agent sandboxes** (isolation, so a runaway warm pool can't hurt your apps). That deliberately *concentrates* agents on one node rather than load-spreading them. Pick per goal: **hard taint = isolation**; **requests + quotas + topology spread (no exclusive taint) = let agents spread across all three by load.** You can start isolated and relax to spreading later.

## 9. Reaching apps by hostname (internal DNS + ingress — not a CDN)

Quick terminology fix: what you want — typing `myapp.home.arpa` instead of `10.0.0.50:30080` — is **DNS + ingress + TLS**, not a CDN. A CDN geographically caches static content for distant users; irrelevant on a home LAN. (If you ever serve heavy static assets to the public you can add caching later — separate concern.) Here's the homelab-standard stack, and most of it we already planned:

### The moving parts
1. **ingress-nginx** (already in Phase 2.5) — the HTTP router. It reads the **Host header** and sends `app-a.home.arpa` to Service A, `app-b.home.arpa` to Service B. One entry point, many apps by name.
2. **MetalLB** (already planned) — gives ingress-nginx **one stable LAN IP** (a `LoadBalancer` service). All your hostnames point here.
3. **A DNS server that maps names → that IP.** This is the missing piece:
   - **Use the selected private namespace:** `*.home.arpa`. It is reserved for residential networks and uses a private CA for certificates. A real subdomain you own remains an option later if you want publicly trusted certificates.
   - **Run a local resolver** on the LAN: **AdGuard Home** or **dnsmasq** (both support **wildcard** records — `*.home.arpa → <ingress IP>`), or **Pi-hole** (no native wildcard, so pair it with ExternalDNS to create per-app records). Point your router/devices at it.
4. **cert-manager** — issues **TLS** so `https://app.home.arpa` is trusted, not a warning. Use an internal CA for `home.arpa`; Let's Encrypt DNS-01 becomes an option only if you later use a domain you own.

### Automate it (GitOps-friendly, optional)
- **ExternalDNS** watches your **Ingress** objects and **auto-creates the DNS records** in Pi-hole/AdGuard/bind/Cloudflare. Result: you deploy an app with `host: app.home.arpa`, and the record + cert appear automatically — no manual DNS edits. This is the clean end-state.

### Reaching them remotely (over Tailscale)
- Use Tailscale **Split DNS**: tell your tailnet to forward `home.arpa` queries to your home DNS server. Then the **same hostnames resolve whether you're home or away**, routed over the tunnel to the ingress IP. (Tailscale's MagicDNS also names your devices; Split DNS is what makes your *app* names work everywhere.)

### Don't confuse this with CoreDNS
**CoreDNS** (built into kubeadm) is the cluster's *internal* DNS for **pod-to-pod** service discovery (`svc.namespace.svc.cluster.local`). It is **not** what your laptop/browser uses — that's the external DNS server above. Two different resolvers, two different jobs.

### Recommended ladder
1. **Start:** own a domain (or pick `*.home`) → run **AdGuard Home** with a **wildcard** to the ingress IP → ingress-nginx routes by host. You can now reach apps by name on the LAN.
2. **Add TLS:** **cert-manager** for HTTPS.
3. **Automate:** **ExternalDNS** so records track your Ingress objects (GitOps).
4. **Remote:** **Tailscale Split DNS** so the names work away from home.

## 10. Updated stack summary

| Layer | Decision |
|---|---|
| Identical installs | **cloud-init / Ubuntu autoinstall** on the USB (unattended, identical nodes) |
| Fleet config / IaC | **Ansible** (agentless, one command → all 3 nodes; own kubeadm playbooks to learn) |
| Node OS | **Ubuntu Server LTS 24.04** |
| Kubernetes | **kubeadm (upstream)** — start 1 CP + 2 workers, then 3× CP + **kube-vip** for HA |
| Topology | **One physical cluster**; separate apps vs agents via namespaces + node taints + quotas + NetworkPolicies. **No physical two-cluster split.** vCluster later if you want true cluster isolation. |
| GitOps | **Argo CD** (app-of-apps) managing both platform + hosted apps |
| Container runtime | **containerd** |
| CNI | **Cilium** |
| Storage | **local-path-provisioner** → Longhorn later |
| Ingress / LB | **ingress-nginx** + **MetalLB** |
| Hostname access (DNS) | Local resolver (**AdGuard Home**/dnsmasq wildcard, or Pi-hole) → ingress IP; **ExternalDNS** to automate; **cert-manager** for TLS; **Tailscale Split DNS** for remote. *(This is your "internal CDN" ask — it's DNS+ingress, not a CDN.)* |
| Secrets | kubectl Secrets now → **SOPS / Sealed Secrets** with GitOps |
| Disposable envs | **Agent Sandbox** (SandboxTemplate/WarmPool/Claim) |
| Agents | Claude Code + Codex (PI later), baked into the Rails image |
| Pod distribution | requests/limits + **metrics-server** + topology spread (default scheduler) → **Descheduler** → **Trimaran** load-aware (real usage) later |
| Monitoring | **kube-prometheus-stack** (Prometheus + Grafana + Alertmanager), retention/size capped; Loki for logs later; VictoriaMetrics/Grafana Cloud as fallbacks |
| Remote access | **Tailscale** mesh (no Hetzner bridge needed) |
| End state | **Ubuntu + kubeadm** — **decided: no Talos migration** |

---

## Sources

- [Why kubeadm over k3s, RKE2, Talos in 2026 — Rommel Porras](https://blog.rommelporras.com/why-kubeadm-over-k3s-rke2-talos/)
- [Kubernetes distributions comparison for a 3-node homelab — Rost Glukhov](https://www.glukhov.org/post/2025/08/kubernetes-distributions-comparison/)
- [k3s or kubeadm? — KodeKloud community](https://kodekloud.com/community/t/k3s-or-kubeadm/494091)
- [Installing kubeadm — Kubernetes docs](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [Does Kubernetes support SELinux? — DEV](https://dev.to/carminezacc/does-kubernetes-support-selinux-3oop)
- [Install kubeadm HA cluster — computingforgeeks](https://computingforgeeks.com/kubeadm-ha-kubernetes-cluster-linux/)
- [Linux Server Security in 2026: SSH, Tailscale, Sudo — Webnestify](https://webnestify.cloud/insights/cybersecurity-hardening/linux-server-security-fundamentals/)
- [Linux Server Hardening Guide 2026 — Mecanik](https://mecanik.dev/en/posts/linux-server-hardening-guide-2026/)
- [SSH Hardening Best Practices — Linuxize](https://linuxize.com/post/ssh-hardening-best-practices/)
- [Swap memory management — Kubernetes docs](https://kubernetes.io/docs/concepts/cluster-administration/swap-memory-management/)
- [Configuring a separate image filesystem — Kubernetes blog](https://kubernetes.io/blog/2024/01/23/kubernetes-separate-image-filesystem/)
