# Homelab Decision Doc — Kubernetes + Agent Offloading

*Prepared for Borna · July 18, 2026*

You have three identical machines: **Dell OptiPlex 7050 Micro/SFF, Intel Core i5-7500T, 16 GB RAM, 256 GB NVMe SSD, Windows 11 Pro.** You want to (1) learn Kubernetes, and (2) offload AI coding-agent work onto the cluster using "pre-warmed pods" preloaded with your projects, with **herdr** in the picture.

This document answers three questions before you touch the machines:

1. Is Talos OS the right choice?
2. What's the cleanest architecture for the agent-offloading goal?
3. Where does herdr actually fit — because it's not what you might think.

---

## The one thing to understand first: herdr is not a Kubernetes tool

This is the most important correction in this doc, so it comes first.

**herdr is a terminal multiplexer for AI coding agents** — think "tmux, rebuilt for agents." It's a single ~10 MB Rust binary that runs your coding agents (Claude Code, Codex, Cursor CLI, etc.) each in its own real terminal, and shows you at a glance which agent is 🔴 blocked, 🟡 working, 🔵 done, or 🟢 idle. It keeps sessions alive when you disconnect, and you can reattach from another terminal or even your phone over SSH.

What herdr is **not**: it does not create pods, it does not talk to Kubernetes, and it does not "pre-warm" anything. It runs agents *wherever a shell already runs* — your laptop, a server you SSH into, or a container you exec into.

Concretely, herdr's model for "offload to another machine" is its **`--remote`** flag:

```
herdr --remote ssh://you@yourserver:2222
```

That makes your local terminal a client of a herdr server running on the remote box. The agents run on the remote box; you watch them locally.

**Why this matters for you:** your goal of "pre-warmed pods preloaded with my projects" is a *Kubernetes* capability, not a herdr one. So the two tools solve different halves of your problem, and you need both — but they connect at a specific seam, described below.

---

## The real mechanism for "pre-warmed pods with my projects"

While researching this, I found that Kubernetes now has an official project built for precisely your use case: **Agent Sandbox** (`kubernetes-sigs/agent-sandbox`). It's a Kubernetes-native way to run isolated, stateful environments purpose-built for AI agent runtimes and dev environments. Its three building blocks map directly onto what you described:

- **SandboxTemplate** — a reusable definition of an environment (base image, your project code baked in, tools installed, resource limits). This is "my project, ready to go."
- **SandboxWarmPool** — keeps a pool of *pre-provisioned* Sandbox pods running so there's **no cold start**. Reports cite sub-second allocation, up to ~90% faster than starting a pod from scratch. This is your "pre-warmed pods."
- **SandboxClaim** — when you want an environment, you claim one and immediately get a ready pod from the warm pool.

So the corrected architecture is:

```
Your laptop
   │  (herdr, watching agents)
   ▼
Kubernetes cluster on the 3 OptiPlex boxes
   │
   ├── Agent Sandbox controller
   │      ├── SandboxTemplate: "my-project" (code + tools baked in)
   │      └── SandboxWarmPool: N pods kept hot, ready to claim
   │
   └── You claim a warm pod → exec/SSH into it → run your coding agent there
```

herdr sits on the *viewing* side: you run `herdr` on your laptop and each pane is an agent running inside one of those warm pods (reached via `kubectl exec` or SSH into the pod). Kubernetes does the pre-warming and isolation; herdr gives you the multi-agent dashboard.

> Note: Agent Sandbox is a young, fast-moving project (2025–2026). It's the *right conceptual fit* and great for learning, but expect rough edges. A simpler starting point is a plain Kubernetes **Deployment** that keeps N identical dev pods running (a poor-man's warm pool). You can graduate to Agent Sandbox once you're comfortable with the basics. Either way, the point stands: **the pre-warming lives in Kubernetes, not herdr.**

---

## Is Talos OS the right choice?

**Short answer: Talos is an excellent choice technically, but for a self-described beginner I recommend starting with k3s on plain Linux, and moving to Talos later.** Here's the reasoning.

### What Talos Linux is

Talos is a minimal, **immutable** Linux distribution that exists only to run Kubernetes. It has **no shell and no SSH** — you never log into a node. Everything is done through a declarative API and YAML config files. Updates atomically replace the whole OS partition, so nodes don't accumulate "cruft" and there's no configuration drift. After two years a node is identical to day one.

### The honest tradeoff for a beginner

| | Talos Linux | k3s on Ubuntu/Debian | Proxmox (then k3s/Talos in VMs) |
|---|---|---|---|
| What it is | K8s-only immutable OS | Lightweight K8s on normal Linux | Virtualization layer; run any OS in VMs |
| Beginner friendliness | Steeper — new mental model | **Easiest** — familiar Linux, SSH works | Medium — adds a VM layer to learn |
| Can you SSH in to debug? | **No** (by design) | Yes | Yes (into the VMs) |
| Troubleshooting when stuck | Fewer beginner tutorials, API-first | **Huge** community, endless guides | Large community |
| Long-term maintenance | **Best** — atomic upgrades, no drift | Good, but you patch the OS yourself | Good; easy to rebuild/experiment |
| Rebuild / experiment cost | Reflash USB | Reinstall OS | **Cheapest** — delete VM, make new one |
| Overhead on your hardware | **Lowest** (no full OS) | Very low | Small hypervisor overhead |

### Why not Talos first

The specific thing that trips up beginners: when something breaks, your instinct is "let me SSH in and fix it," and with Talos **you can't** — everything is configuration and API. That's a feature in production and a genuine wall when you're still learning what a pod, a service, and a kubeconfig even are. You'd be learning *two* hard things at once (Kubernetes itself + Talos's API-only model).

**k3s** lets you learn Kubernetes on Linux you already understand, with the largest pool of tutorials and Q&A when you get stuck. It's a certified, lightweight Kubernetes — real K8s, just packaged to be small. 16 GB per node is far more than enough (k3s idles around ~1.5 GB).

### My recommendation

**Phase 1 (now):** Wipe Windows on all three boxes → install **Ubuntu Server LTS** (or Debian) → install **k3s** as a 3-node cluster (all three as control-plane/server nodes for high availability). Learn pods, deployments, services, ingress, storage. Get herdr working against one node over `--remote`.

**Phase 2 (later):** Once Kubernetes concepts click, rebuild on **Talos** for the cleaner, immutable, low-maintenance setup you'll actually want to keep. You'll appreciate *why* Talos does what it does, having felt the pain it removes. (Optional: put **Proxmox** on the boxes first if you want to spin Talos/k3s up and down in VMs while experimenting — great for a rebuild-friendly learning lab, at the cost of one more layer to learn.)

This "k3s → Talos" path is a well-worn route in the homelab community; plenty of people migrate exactly this way.

---

## Is your hardware up to the job?

**Yes, comfortably for learning and light agent workloads.** Notes and caveats:

- **CPU (i5-7500T, 4 cores / 4 threads, 2.7 GHz base, 35 W):** Fine for a control plane and a handful of workloads per node. Kubernetes is generally CPU-bound before RAM-bound when you add nodes, so three of them together give you 12 cores — a solid little cluster.
- **RAM (16 GB each, 48 GB total):** Plenty. k3s itself is light; a single 16 GB OptiPlex can run dozens of containers. Your ceiling will be how heavy your agent/dev pods are, not the cluster overhead.
- **Storage (256 GB NVMe each):** The tight spot. Container images — especially dev-environment images with language toolchains baked in — get large fast, and pre-warmed pools multiply that. 256 GB is workable to start, but plan to (a) keep images lean, and (b) budget for a bigger SSD in at least one node if you lean into Agent Sandbox with big project images. The 7050 typically has a spare SATA bay and/or the M.2 slot, so upgrades are easy and cheap.
- **Networking:** Gigabit onboard is fine. If you ever add heavy distributed storage (e.g., Ceph/Rook), you'd want more, but that's well beyond where you're starting.

**Verdict:** don't buy anything yet. Start with what you have; the only likely near-term upgrade is more SSD if pre-warmed images pile up.

---

## Recommended path (summary)

1. **Back up** anything you need off the three machines (you'll wipe Windows).
2. **Phase 1 — learn on k3s:** Ubuntu Server LTS on all three → k3s HA cluster (3 servers) → learn core Kubernetes.
3. **Add herdr** on your laptop; point it at a node with `herdr --remote` and run a coding agent there to feel the workflow.
4. **Warm pods, simple version:** a Deployment that keeps N identical dev pods running with your project baked into the image; `kubectl exec` in and run your agent, watched via herdr.
5. **Warm pods, real version:** adopt **Agent Sandbox** (`SandboxTemplate` + `SandboxWarmPool` + `SandboxClaim`) once you're comfortable.
6. **Phase 2 — Talos:** rebuild the cluster on Talos for a clean, immutable, low-maintenance long-term setup.

---

## Open questions for you (these shape the setup guide)

1. **Which coding agent(s)** do you plan to run in the pods (Claude Code, Codex, Cursor CLI, something else)? It affects the pod image.
2. **What are "your projects"** — roughly what languages/stacks? That determines what goes in the SandboxTemplate image.
3. **Networking:** are these three boxes on your home LAN with wired ethernet? Any interest in reaching the cluster from outside your home?
4. **Comfort with the command line / Linux** on a 1–5 scale — I'll pitch the setup guide's detail level accordingly.
5. **OK to wipe Windows** on all three, or do you want to keep Windows on one?

Answer those and the next deliverable is a step-by-step Phase 1 setup guide.

---

## Sources

- [Talos Linux (Sidero Labs)](https://www.siderolabs.com/talos-linux)
- [Why I Run Talos Linux — Pim Widdershoven](https://www.pimwiddershoven.nl/entry/why-i-run-talos-linux-a-minimal-os-built-for-kubernetes/)
- [The Best OS For Kubernetes — Mircea Anton](https://mirceanton.com/posts/the-best-os-for-kubernetes/)
- [Talos Linux: An Immutable OS for Kubernetes in Your Homelab — HomeLab Starter](https://homelabstarter.com/homelab-talos-linux/)
- [Reworking my homelab with Talos (k3s → Talos) — Rob Kenis](https://robkenis.com/posts/k3s_to_talos/)
- [Kubernetes Homelab Series Part 1 — Eric Daly](https://blog.dalydays.com/post/kubernetes-homelab-series-part-1-talos-linux-proxmox/)
- [K3s Requirements (official docs)](https://docs.k3s.io/installation/requirements)
- [K3s Resource Profiling (official docs)](https://docs.k3s.io/reference/resource-profiling)
- [Running Agents on Kubernetes with Agent Sandbox — Kubernetes Blog](https://kubernetes.io/blog/2026/03/20/running-agents-on-kubernetes-with-agent-sandbox/)
- [kubernetes-sigs/agent-sandbox (GitHub)](https://github.com/kubernetes-sigs/agent-sandbox)
- [Agent Sandbox documentation](https://agent-sandbox.sigs.k8s.io/docs/)
- [herdr (GitHub)](https://github.com/ogulcancelik/herdr) · [herdr.dev](https://herdr.dev)
