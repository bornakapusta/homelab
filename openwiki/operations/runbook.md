---
type: Operations Runbook
title: Homelab Operations and Recovery Runbook
description: Practical commands, deployment gates, patch and reboot procedures, troubleshooting, reset steps, and active operational risks for the homelab.
tags: [operations, runbook, kubernetes, recovery]
---

# Operations and recovery runbook

## Command map

Run targets from the repository root:

| Command | Purpose | Important behavior |
|---|---|---|
| `make deps` | Install Ansible collections | Uses `ansible/requirements.yml` |
| `make check` | Syntax-check both playbooks and run production-profile lint | Required gate before node changes |
| `make test` | Run hardening-role Molecule | Needs a working Docker context; does not test kubeadm |
| `make ping` | Verify SSH connectivity | Does not verify sudo |
| `make nodes` | Run `site.yml` | Serial, but every run is also an apt patch event |
| `make cluster` | Run `cluster.yml` | Initializes/reconciles Cilium and joins workers |
| `make hosts` | Print laptop endpoint mapping | Needed when local DNS lacks `control_plane_endpoint` |
| `make status` | List nodes and all pods | Uses `ansible/kubeconfig` and first checks endpoint resolution |
| `make reset-help` | Print destructive kubeadm reset instructions | Does not perform the reset |

These commands operate the flows described in [provisioning and bootstrap](/openwiki/workflows/provisioning.md) and should follow the gates in [testing and validation](/openwiki/testing.md).

## Pre-deployment gate

Before the first physical-cluster run:

1. Confirm DHCP reservations for `.11`, `.44`, and `.66`.
2. Confirm SSH host keys and `make ping`.
3. Resolve sudo: either use `--ask-become-pass` for the initial human-admin run or establish validated passwordless sudo.
4. Generate the separate automation key, run once as the admin, verify `ansible@node-1` can `sudo -n true`, then change `ansible_user`.
5. Fix the package hold/unhold issue listed below.
6. Run `make check`, `make test`, and preferably `pre-commit run --all-files`.
7. Verify `helm version --short` reports reviewed Helm 4.2.x.
8. Review the full working-tree diff: Cilium behavior is currently uncommitted relative to `HEAD`.

Do not treat the offline Cilium review as live-cluster proof. It explicitly leaves kubeadm API, eBPF datapath, and cross-node networking validation to deployment.

## Routine node patching

`site.yml` runs apt safe upgrade. Automatic reboots are disabled, and pending reboots are reported. For each node:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
ssh <node> sudo reboot
kubectl uncordon <node>
```

Operate one node at a time. Rebooting the sole control plane causes temporary API downtime. Confirm workloads and Cilium recover before proceeding to the next node.

The node play is already `serial: 1`, but serialization does not replace drain/uncordon for a running cluster.

## Cluster health checks

Baseline checks:

```bash
make status
KUBECONFIG=ansible/kubeconfig kubectl -n kube-system rollout status daemonset/cilium
KUBECONFIG=ansible/kubeconfig kubectl -n kube-system get pods -o wide
```

Monitor for:

- Cilium restart loops or errors;
- `NetworkPluginNotReady` events;
- CoreDNS readiness failures;
- missing VXLAN reachability on UDP 8472;
- nodes registering an unexpected address;
- `/var/run/reboot-required` after node convergence;
- disk pressure, especially under `/var`.

Perform the pod-level network tests in [testing and validation](/openwiki/testing.md) after bootstrap or CNI changes.

## Common failures

| Symptom | Likely cause or first action |
|---|---|
| Privileged task reports interactive authentication required | Run the playbook with `--ask-become-pass`, or complete the passwordless automation-user rollout |
| Laptop `make status` cannot resolve API endpoint | Run `make hosts` and add the printed mapping, or configure real DNS |
| Node stays `NotReady` | Inspect Cilium DaemonSet and kubelet logs; verify UFW forwarding and peer trust |
| Kubelet crash-loops | Confirm containerd has `SystemdCgroup = true`; rerun node convergence after fixing package state |
| Worker has `kubelet.conf` but no API Node | Run `sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d` on that worker, then rerun `make cluster` |
| Worker-only tagged run cannot join | The control-plane play must mint the in-memory join command first |
| Cilium role refuses to proceed | A Calico DaemonSet exists; reset an empty cluster or follow an official data-preserving CNI migration |
| SSH fails after reimage with changed key | Verify the new physical fingerprint, then remove the stale known-host entry |
| Pods cannot communicate across nodes | Check PodCIDR overlap, UFW forwarding, complete node peer rules, and VXLAN UDP 8472 |

## Destructive reset

For an empty or intentionally discarded cluster, on every node:

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
```

Then rerun:

```bash
make cluster
```

Also remove or protect the stale controller copy at `ansible/kubeconfig`; it contains cluster-admin credentials even if the old API is gone. Do not use this reset procedure as a substitute for a migration when cluster data must survive.

## Active risks and known issues

### Package holds can end in the wrong state

`ansible/roles/kubernetes_node/tasks/main.yml` records package holds, unholds matching packages, then uses the unchanged original snapshot to decide whether to hold them. Packages that started held can be skipped by the final hold task and finish unheld. This contradicts the intended protection from later apt upgrades and may make consecutive runs alternate state. Treat this recent review finding as active even though an older idempotency todo is marked complete.

### First privileged run remains blocked

The latest committed node probe confirmed SSH and Python but found sudo requires interactive authentication. `make ping` can pass while `make nodes` fails. The operator must supply the become password or establish the intended sudo configuration.

### Cilium is uncommitted and not live-tested

The working tree replaces Calico with digest-pinned Cilium, verifies chart metadata, refuses side-by-side CNI installation, and reconciles Helm drift. Offline checks passed, but no physical node has exercised the path.

### Tailscale is incomplete

The optional base-role block executes an unverified installer script as root, lacks a declared vaulted key home, leaves the script in `/tmp`, and does not open UFW to `100.64.0.0/10`. Do not claim remote management is working until todo 017 is resolved and tested.

### Apt repository module has a removal deadline

Two `apt_repository` calls are deprecated for removal in ansible-core 2.25. The deliberate plan is to migrate to `deb822_repository` after a known-good first physical run, remove stale `.list` files, and verify package policy. Until then, avoid upgrading the controller beyond the supported module window.

### Availability and recovery are immature

Stage A has one API server and one etcd member. Backups, restore rehearsal, certificate renewal, HA promotion, and persistent-volume recovery are roadmap items, not implemented runbooks. The [architecture overview](/openwiki/architecture/overview.md) explains the future three-control-plane shape.

## Change and rollback discipline

- Host-level changes belong in Ansible; future cluster resources belong in Argo CD.
- Review handler timing when reordering roles because `flush_handlers` is play-global.
- Keep endpoint, PodCIDR, package version, and digest changes paired with explicit validation.
- Use generated file backups for break-glass recovery, but validate each subsystem rather than blindly restoring stale configuration.
- For Cilium bootstrap failure on an empty cluster, prefer a full reset over layering another CNI.
- After any security, network, or identity change, recheck the invariants in [configuration and security](/openwiki/domain/configuration-and-security.md).
