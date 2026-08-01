---
type: Quickstart Guide
title: Homelab Repository Quickstart
description: Engineer entrypoint for provisioning, bootstrapping, validating, and operating the three-node Ubuntu kubeadm homelab.
tags: [homelab, kubernetes, ansible, quickstart]
---

# Homelab repository quickstart

## What this repository does

This repository is infrastructure-as-code for three Dell OptiPlex nodes running Ubuntu 26.04 (`resolute`). Its implemented scope configures and hardens the machines, installs pinned Kubernetes prerequisites, bootstraps a single-control-plane kubeadm cluster, installs a minimal Cilium CNI, and joins two workers.

The central ownership rule is: **Ansible owns the machines and initial cluster bootstrap; future Argo CD configuration will own resources inside the cluster.** The planned end product adds hosted applications and disposable, pre-warmed AI coding environments, but those in-cluster layers do not exist yet.

The [architecture overview](/openwiki/architecture/overview.md) explains this boundary and the current topology. The [domain concepts guide](/openwiki/domain/concepts.md) separates the long-term product model from implemented scope, while the [provisioning workflows](/openwiki/workflows/provisioning.md) describe the executable sequence.

## Current state

| Area | State |
|---|---|
| Physical inventory | `node-1` at `192.168.178.11`; workers at `.44` and `.66`; DHCP reservations still need confirmation |
| Node automation | Implemented in `ansible/site.yml`; a privileged real-node run is blocked by interactive sudo unless `--ask-become-pass` is used |
| Automation identity | Role implemented, but `ansible_user` still selects the human admin account |
| Cluster bootstrap | Implemented in `ansible/cluster.yml`; nodes have not yet been bootstrapped |
| CNI | Uncommitted Cilium migration is offline-reviewed and pinned, but not live-tested |
| In-cluster platform | Argo CD, MetalLB, ingress, storage, monitoring, Agent Sandbox, and applications are roadmap only |
| Quality gates | Syntax, production-profile lint, pre-commit scanning, and hardening-role Molecule tests; no quality CI workflow |

The working tree contains substantial uncommitted Cilium changes. Do not assume `HEAD` alone represents the intended runtime. See the [source map](/openwiki/source-map.md) before reviewing or changing bootstrap behavior.

## First-time controller setup

From the repository root:

```bash
make deps
make hooks
make check
make test
```

Controller requirements include Ansible, Docker for Molecule, `kubectl`, SSH, and Helm **4.2.x** for the current Kubernetes 1.36 bootstrap path. `make test` only exercises hardening in a systemd-enabled container; it does not prove kubeadm or Cilium behavior.

Before touching nodes, inspect these two sources of truth:

- `ansible/inventory.ini`: host roles and fixed node addresses.
- `ansible/group_vars/all.yml`: identity, endpoint, CIDRs, package versions, artifact digests, and role-facing host lists.

Then verify basic connectivity:

```bash
make ping
```

If the human admin requires a sudo password, direct playbook runs need `--ask-become-pass`; the simple `make nodes` target does not add it. Complete the separate automation-key rollout documented beside `ansible_user` before switching Ansible to the `ansible` service account.

The [configuration and security guide](/openwiki/domain/configuration-and-security.md) identifies values that are baked into certificates or used across firewall, kubelet, and DNS configuration.

## Safe execution path

1. Reserve all inventory addresses in DHCP. An address change after bootstrap requires a cluster reset because the control-plane address is embedded in certificates.
2. Ensure `control_plane_endpoint` resolves on the nodes; `base` writes node-side `/etc/hosts` entries automatically.
3. Run `make check` and `make test`.
4. Configure nodes with `make nodes` or `cd ansible && ansible-playbook site.yml --ask-become-pass` if required.
5. Re-run node configuration and inspect idempotency before bootstrap. **First fix the active package hold/unhold defect described in the [operations runbook](/openwiki/operations/runbook.md).**
6. Upgrade and verify controller Helm 4.2.x.
7. Bootstrap with `make cluster`.
8. Run `make hosts` if the laptop cannot resolve `k8s.lab.example`, then run `make status`.
9. Perform live Cilium, CoreDNS, and cross-node pod tests from the [testing guide](/openwiki/testing.md).

Do not bootstrap merely to test automation: `control_plane_endpoint`, the advertise IP, certificate SANs, and `pod_cidr` become expensive to change.

## Where to go next

- [Architecture overview](/openwiki/architecture/overview.md) — ownership boundaries, topology, roles, and planned platform.
- [Domain concepts and invariants](/openwiki/domain/concepts.md) — product goals, staged delivery, quorum, workload isolation, and planned agent workflows.
- [Provisioning workflows](/openwiki/workflows/provisioning.md) — autoinstall, node convergence, control-plane initialization, Cilium reconciliation, and worker join.
- [Configuration and security](/openwiki/domain/configuration-and-security.md) — inventory-derived data, identity rollout, firewall, supply-chain pins, and secrets.
- [Operations runbook](/openwiki/operations/runbook.md) — routine commands, patching, recovery, troubleshooting, and active hazards.
- [Testing and validation](/openwiki/testing.md) — local gates, Molecule scope, and required physical-cluster checks.
- [Source map and history](/openwiki/source-map.md) — where implementation and decision evidence lives and how the repository evolved.

## Backlog

- **GitOps platform** — source anchor: `docs/PROJECT-PLAN.md` phases 2.5–3; deferred because `clusters/` and Argo CD configuration do not exist.
- **Observability** — source anchor: `docs/PROJECT-PLAN.md` phase 3.5; deferred because kube-prometheus-stack and metrics-server are planned only.
- **Agent environments** — source anchor: `docs/PROJECT-PLAN.md` phases 4–6; deferred because `images/`, Agent Sandbox resources, and herdr integration do not exist.
- **High availability and disaster recovery** — source anchor: `docs/PROJECT-PLAN.md` phases 2 and 3; deferred until single-control-plane bootstrap and an etcd restore procedure are implemented.
- **Remote access** — source anchor: `todos/017-pending-p2-tailscale-block-gaps.md`; deferred because the current optional Tailscale block is not supply-chain pinned and UFW does not permit the tailnet.
