---
type: Testing Guide
title: Testing and Validation Guidance
description: Local quality gates, secret scanning, Molecule coverage, physical-cluster validation, and known testing gaps for the homelab automation.
tags: [testing, ansible, molecule, validation]
---

# Testing and validation

## Local quality gates

Run before node changes:

```bash
make deps
make check
make test
pre-commit run --all-files
```

`make check` performs syntax checks for `site.yml` and `cluster.yml`, then runs ansible-lint with the strict `production` profile. There is no skip list. Role variables are intentionally namespaced because all roles in `site.yml` share one play-level namespace, and handlers can cross role boundaries.

Pre-commit adds:

- gitleaks secret scanning;
- private-key and large-file detection;
- merge-conflict, whitespace, line-ending, and YAML checks;
- the same ansible-lint gate.

Hooks are bypassable, so `make check` remains the explicit operational gate. The repository has no committed CI workflow for syntax, lint, or Molecule; the untracked root workflow is for OpenWiki updates, not infrastructure quality.

This testing strategy protects the [configuration and security invariants](/openwiki/domain/configuration-and-security.md) before the [operations runbook](/openwiki/operations/runbook.md) touches physical nodes.

## Molecule scope

`make test` runs only the `hardening` scenario through:

1. destroy;
2. create;
3. converge;
4. idempotence;
5. verify;
6. destroy.

The scenario uses an Ubuntu 26.04 systemd-enabled container and checks generated sshd, apt, and UFW configuration, backups, and idempotency. Hardening is a high-value target because a regression can lock out all nodes.

Other roles intentionally lack container scenarios:

- `base` depends on meaningful host package and reboot behavior;
- `kubernetes_node` needs real swap, modules, sysctls, and service interaction;
- `control_plane` and `worker` need a live Kubernetes API and network datapath.

Do not infer cluster readiness from a passing Molecule run. Expected Molecule output may include an initial warning about a missing `default` scenario; judge success by exit code and scenario recap.

## Physical node validation

Before cluster bootstrap, validate one node and then the serialized fleet:

```bash
make ping
cd ansible
ansible-playbook site.yml --check --diff --ask-become-pass
ansible-playbook site.yml --ask-become-pass
```

Check mode cannot model every command or handler, so it is advisory. After convergence, run the play again and inspect changes. A clean result is not currently expected until the package hold/unhold issue is fixed.

Verify on each node:

- SSH still works for the intended identities;
- `sudo -n true` works for the automation account;
- `sshd -t` succeeds;
- UFW is enabled and trusts all current node addresses;
- swap is disabled and absent from active fstab entries;
- containerd is running with `SystemdCgroup = true`;
- kubelet, kubeadm, kubectl, and containerd are at intended versions and held;
- kubelet uses the inventory address;
- pending reboot state is understood before bootstrap.

## Cluster and Cilium validation

The Cilium working-tree review passed syntax, lint, Molecule, Helm 4.2.3 CLI checks, chart render/lint, positive and negative digest assertions, exact OCI digest resolution, and diff checks. It did **not** exercise a live API, eBPF datapath, or physical LAN.

After `make cluster`, require all of the following:

```bash
KUBECONFIG=ansible/kubeconfig kubectl get nodes -o wide
KUBECONFIG=ansible/kubeconfig kubectl -n kube-system rollout status daemonset/cilium
KUBECONFIG=ansible/kubeconfig kubectl -n kube-system get daemonset cilium
KUBECONFIG=ansible/kubeconfig kubectl -n kube-system get pods -o wide
```

Success criteria:

- all three nodes report `Ready` with expected internal addresses;
- Cilium reaches 3 desired, current, and ready agents;
- CoreDNS is ready;
- no `NetworkPluginNotReady` events persist;
- Cilium pods do not restart repeatedly.

Then create temporary test pods scheduled on different workers and validate:

- pod-to-pod connectivity across nodes;
- service connectivity through kube-proxy;
- DNS resolution through CoreDNS;
- egress as intended;
- standard NetworkPolicy enforcement if a temporary policy is applied.

Delete test resources after validation. These live checks are the deployment gate for the [provisioning workflow](/openwiki/workflows/provisioning.md), not optional polish.

## Change-specific guidance

| Change area | Minimum checks |
|---|---|
| Playbook or role ordering | `make check`; inspect play-global handler effects; physical serialized run |
| SSH, sudo, or UFW | `make test`; console recovery plan; one-node physical validation before fleet |
| Inventory or endpoint | Preflight; DNS and `/etc/hosts`; certificate impact review; `make status` |
| Kubernetes or containerd version | Verify repository availability and suite suffix; update pins and digests together; package policy and holds |
| Cilium chart or values | Digest metadata verification; Helm render/lint; fresh or controlled cluster test; DNS and cross-node traffic |
| Worker join logic | New worker, already joined worker, and stale-state failure paths |
| Autoinstall | Real install on disposable/rebuildable node; harvested storage verification; SSH and sudo bootstrap |
| Tailscale | Verified installation source, vaulted credential, UFW tailnet rule, off-LAN SSH, second-run idempotency |

## Known gaps

- No remote CI enforces local gates.
- No automated kubeadm integration environment exists.
- No automated Cilium datapath or cross-node LAN test exists.
- No etcd backup/restore test exists.
- No HA failover, certificate renewal, persistent-storage recovery, or Argo CD recovery tests exist because those systems are not implemented.
- The package hold logic has a known issue that weakens idempotency and upgrade safety.

Keep unresolved operational gaps visible in the [quickstart backlog](/openwiki/quickstart.md) rather than inventing tests for components that do not yet exist.
