---
title: "feat: Default StorageClass via local-path-provisioner"
type: feat
status: active
date: 2026-08-07
origin: docs/plans/2026-08-06-001-feat-node-metrics-dashboard-plan.md
---

# ✨ feat: Default StorageClass via local-path-provisioner

## Overview

Add a `local_path_provisioner` role to `platform.yml` that installs Rancher's
local-path-provisioner and makes it the cluster's **default StorageClass**.

Follows the `metrics_server` role verbatim as its structural template — both
deliver a raw upstream manifest rather than a Helm chart, so the
download → digest-verify → narrowly transform → annotate ownership → reconcile
pipeline transfers directly.

## Problem Statement

`kubectl get storageclass` returns nothing. **No PersistentVolumeClaim in this
cluster can bind**, which blocks:

- Prometheus and Alertmanager (Phase 3.5, `docs/plans/2026-08-06-001-*`) — the
  immediate consumer, and the reason this is being built now
- every future stateful workload, including anything the agent sandboxes persist

It is the single named blocker in the corrected node-metrics plan.

## Proposed Solution

One new role, one new `platform.yml` entry, one new `group_vars/all.yml` pin
block, one new `tests/` validation playbook. No changes to existing roles.

### Why local-path and not something else

| Option | Verdict |
|---|---|
| **local-path-provisioner** | **Chosen.** Already the roadmap's decision (`homelab-roadmap.md:105`). Single Deployment, no CRDs, no extra daemons. Right weight for 3 nodes. |
| Longhorn | Replicated storage on 3× 256 GB NVMe costs more disk and RAM than the resilience is worth here; roadmap already labels it a later optional upgrade |
| NFS to a NAS | No NAS in the topology; adds a single point of failure outside the cluster |
| `hostPath` volumes by hand | No dynamic provisioning — every workload would hand-roll its own PV |

### ⚠️ The thing that must be understood before building on this

**local-path-provisioner does not enforce capacity.** A PVC requesting `20Gi`
receives an ordinary directory on the node's filesystem with **no quota**. The
number is bookkeeping; nothing stops a pod writing until the disk is full.

Consequences that must be carried into the monitoring work:

- Prometheus's `retentionSize` is not a safety net backed by the volume — it is
  the *only* thing standing between the TSDB and a full disk. Risk R-5 in the
  monitoring plan is more severe than written there.
- `/var/lib/containerd` (container images) shares whatever filesystem the
  provisioner writes into. A runaway PVC evicts images and breaks pod starts.
- A `NodeDiskFillingUp` alert is therefore not optional polish — it is the
  compensating control for a storage layer with no enforcement.

## Technical Approach

### Role shape — mirror `metrics_server` exactly

```
ansible/roles/local_path_provisioner/
├── defaults/main.yml          # structural, non-secret: kubeconfig, paths
├── vars/main.yml              # __local_path_provisioner_* constants
├── meta/main.yml
├── meta/argument_specs.yml    # enforced interface
├── README.md                  # purpose, arguments, idempotency, ROLLBACK
├── templates/
│   └── local-path-storage.yml.j2
└── tasks/
    ├── main.yml
    ├── validate.yml           # fail closed on the controller, before any apply
    ├── prepare_manifest.yml   # digest-verify + narrow transform
    ├── ownership_state.yml    # read what this role already owns
    └── reconcile_state.yml
```

Wire into `ansible/platform.yml` **before** `metrics_server`, and ahead of any
future monitoring role — nothing else depends on it, but everything stateful
will:

```yaml
    - role: local_path_provisioner
      tags: [platform, storage]
```

Add `make storage` to the Makefile alongside `make metrics`, and a
`tests/local_path_provisioner_validation.yml` entry in the `check` target.

### Pins for `group_vars/all.yml`

```yaml
# --- storage ---------------------------------------------------------------
# https://github.com/rancher/local-path-provisioner/releases
# Digest of the deploy manifest at that tag — git tags are mutable, so this is
# what makes the install reproducible.
#   curl -fsSL <url> | sha256sum
local_path_provisioner_version: "0.0.37"        # verify at implementation time
local_path_provisioner_manifest_sha256: "..."
local_path_provisioner_image_sha256: "..."      # rancher/local-path-provisioner
local_path_provisioner_helper_image_sha256: "..."  # busybox — see below

# Where PVs are created on each node. MUST be on a filesystem with headroom;
# confirm against `df -h` on a real node before first apply.
local_path_provisioner_data_path: "/var/lib/local-path-provisioner"

# This provisioner grants a helper pod hostPath write access to the path above,
# which is a deliberate exception to the repo's hardening posture. Must be
# explicitly acknowledged or validate.yml rejects the run.
local_path_provisioner_hostpath_acknowledged: true
```

The acknowledgement flag mirrors the existing
`metrics_server_kubelet_insecure_tls_acknowledged` pattern — a deliberate
security exception has to be *stated*, not inherited silently.

### The narrow homelab transformations

Upstream's `local-path-storage.yaml` is applied with exactly these changes:

1. **Pin both images by digest.** The Deployment's
   `rancher/local-path-provisioner` image, *and* the helper pod's image inside
   the ConfigMap's `helperPod.yaml` — upstream ships that one as bare `busybox`
   with no tag discipline, so it is the weakest link in an otherwise
   digest-pinned repo.

2. **Set the data path** in the ConfigMap's `config.json`.

3. **Scope provisioning to workers only.** `config.json`'s `nodePathMap`
   accepts a per-node list. Restricting it to `worker_hosts` means a PV can
   never be created on node-1. This is the storage-layer enforcement of the
   monitoring plan's decision to keep write-heavy workloads off the node running
   etcd — better as a structural guarantee here than as a `nodeSelector` a
   future workload might forget.

4. **Mark the StorageClass default** —
   `storageclass.kubernetes.io/is-default-class: "true"`.

5. **Keep `volumeBindingMode: WaitForFirstConsumer`** (upstream default). Do not
   change it. It is what makes the PV follow the pod's scheduling decision, so a
   `nodeSelector` on Prometheus still lands its storage in the right place.

6. **Stamp ownership annotations** —
   `homelab.home.arpa/local-path-provisioner-managed-by` plus the manifest
   digest, matching `metrics_server`'s scheme.

### `validate.yml` — fail closed on the controller

Refuse to run when:

- version or either digest is malformed
- `local_path_provisioner_hostpath_acknowledged` is not `true`
- `local_path_provisioner_data_path` is not absolute, or is `/` or `/tmp`
- **a different default StorageClass already exists** — two defaults make PVC
  binding non-deterministic and the failure surfaces much later, as a pod stuck
  in `Pending` with an unhelpful event
- `worker_hosts` is empty

Add a table-driven `tests/local_path_provisioner_validation.yml` in the style of
`tests/metrics_server_validation.yml` — one case per rejection above, run on
localhost by `make check`, requiring no cluster.

### Decision: reclaim policy

Upstream defaults to `Delete` — deleting a PVC deletes the directory and its
contents.

**Recommendation: keep `Delete`, and treat it as a documented sharp edge** rather
than switching to `Retain`. `Retain` leaks orphaned directories that nothing
cleans up, on the exact disks where space is the binding constraint. The real
protection for Prometheus history is not to delete its PVC; that belongs in the
role README's rollback section, not in a policy that silently fills a 256 GB
disk with abandoned data.

## Acceptance Criteria

- [ ] `kubectl get storageclass` shows `local-path` marked `(default)`
- [ ] A throwaway PVC + pod binds, writes, and the file survives a pod restart
- [ ] The PV directory lands under `local_path_provisioner_data_path` on a **worker**
- [ ] A PVC scheduled onto node-1 is impossible — verified by inspecting `nodePathMap`
- [ ] Deleting the test PVC removes the directory (`Delete` policy confirmed)
- [ ] `make check` passes — ansible-lint `production`, **`skip_list` still empty**
- [ ] `tests/local_path_provisioner_validation.yml` passes, covering every rejection
- [ ] Second `ansible-playbook platform.yml` run reports **zero changes**
- [ ] Role has `README.md` (purpose, arguments, idempotency, **rollback**) and `meta/argument_specs.yml`
- [ ] Both images pinned by `@sha256:`, digests recorded in `group_vars/all.yml`
- [ ] Internal vars `__local_path_provisioner_` prefixed; defaults `local_path_provisioner_` prefixed
- [ ] `docs/PROJECT-PLAN.md` Phase 2.5 storage checkbox ticked

## Risks & Mitigation

| # | Risk | Mitigation |
|---|---|---|
| S-1 | **No capacity enforcement** — a PVC's size request is advisory; a pod can fill the disk | Cannot be fixed at this layer. Compensate with the `NodeDiskFillingUp` alert from the monitoring plan, and treat Prometheus `retentionSize` as load-bearing rather than belt-and-braces |
| S-2 | PV lands on node-1, putting write-heavy I/O on etcd's NVMe | `nodePathMap` restricted to `worker_hosts`; asserted in `validate.yml` |
| S-3 | A second default StorageClass appears later → non-deterministic binding | `validate.yml` refuses to run if another default exists |
| S-4 | Data path on a filesystem without headroom | **Requires real-node verification** — see open questions |
| S-5 | PV node affinity is permanent; the node that first hosts a PVC keeps it forever | Inherent to local storage. Documented in the README; the monitoring plan already treats the Prometheus node choice as irreversible |
| S-6 | Helper pod's hostPath write access weakens the hardening posture | Explicit acknowledgement flag, documented in the README with what it grants |
| S-7 | Upstream changes the manifest's resource set between versions | Assert an expected resource key list, as `metrics_server` does |

## Open Questions

1. **What is the disk layout on the real nodes?** ⛔ Blocks the data path choice.
   The original design put `/var` on its own LVM volume, but the nodes were
   rebuilt on Ubuntu 26.04 (`19c42d9`) and the layout has not been confirmed
   since. Needs `df -h` and `lsblk` on a worker. If `/var` is not separate,
   `/opt` versus `/var/lib` stops mattering and the real question becomes how
   much headroom the root volume has.
2. **Are the nodes reachable?** Everything here is unverifiable until
   `make ping` passes — the same blocker as the monitoring plan's Stage 0 gate.
3. Should the test PVC/pod become a permanent smoke test in `tests/`, or stay a
   manual acceptance step? It is the only check here that needs a live cluster.

## Sources & References

### Internal

- `ansible/roles/metrics_server/` — the structural template: `vars/main.yml` for
  the constants scheme, `tasks/prepare_manifest.yml` for digest-verified
  transformation, `tasks/ownership_state.yml` for the annotation-based ownership model
- `ansible/roles/metallb/tasks/validate.yml` — fail-closed controller-side validation
- `ansible/tests/metrics_server_validation.yml` — table-driven validation harness
- `ansible/group_vars/all.yml:200-212` — version + digest + acknowledgement pin block
- `ansible/platform.yml` — "services needed before Argo CD exists"
- `docs/plans/2026-08-06-001-feat-node-metrics-dashboard-plan.md` — the consumer
- `docs/homelab-roadmap.md:105` — local-path as the roadmap's storage decision

### External

- [rancher/local-path-provisioner](https://github.com/rancher/local-path-provisioner) · [releases](https://github.com/rancher/local-path-provisioner/releases) — v0.0.37 current; manifest at `deploy/local-path-storage.yaml`
