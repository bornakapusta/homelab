# local_path_provisioner

Installs one pinned [local-path-provisioner](https://github.com/rancher/local-path-provisioner)
replica and makes its `local-path` StorageClass the cluster default, so a
PersistentVolumeClaim without an explicit class can bind. The role runs on the
Ansible controller with the admin kubeconfig fetched by `control_plane`; it
installs no node package and exposes no service.

## What a volume actually is

A PV from this class is a plain directory under `local_path_provisioner_data_path`
on **one worker**. That has three consequences to design around:

- **No capacity enforcement.** A `20Gi` request is bookkeeping only; nothing
  stops a pod writing until the node's filesystem is full. On these nodes the
  data path shares the root LV with `/var/lib/containerd`, so a runaway volume
  also evicts images and breaks pod starts. Prometheus `retentionSize` and a
  disk-filling alert are the real controls, not the PVC size.
- **Node affinity is permanent.** `WaitForFirstConsumer` creates the directory on
  the node where the first consuming pod is scheduled, and the PV is pinned
  there. If that worker is lost, the data is lost.
- **`reclaimPolicy: Delete`.** Deleting a PVC deletes its directory. Protect
  history by not deleting the PVC; `Retain` would only leak orphaned directories
  onto the disks where space is the binding constraint.

## Homelab transformation

The checksum-verified upstream manifest is applied with exactly these changes:

1. The provisioner image is pinned by digest.
2. The helper pod image inside the ConfigMap, upstream an untagged `busybox`,
   is pinned to an exact tag and digest.
3. `config.json` lists **only the inventory workers**, each with
   `local_path_provisioner_data_path`, and has no
   `DEFAULT_PATH_FOR_NON_LISTED_NODES` entry. The provisioner refuses to create
   a volume on any node it is not told about, so no PV can ever land on the
   control-plane node next to etcd.
4. The StorageClass is annotated `storageclass.kubernetes.io/is-default-class: "true"`.
   `WaitForFirstConsumer` and `Delete` are kept from upstream and asserted.
5. Every object carries an Ansible ownership annotation and the source-manifest
   checksum.

## hostPath acknowledgement

The helper pod that creates and deletes volume directories mounts the data path
from the host read-write and runs as root. That is a deliberate exception to
the repository's hardening posture, so the operator must set
`local_path_provisioner_hostpath_acknowledged: true`. Anyone able to create a
PVC can cause directories to be created and removed under that path on a
worker, but nowhere else.

## Arguments

`meta/argument_specs.yml` is the enforced interface. Pins and the data path live
in `group_vars/all.yml`:

| Variable | Meaning |
|---|---|
| `local_path_provisioner_version` | release tag of the manifest and image |
| `local_path_provisioner_manifest_sha256` | sha256 of `deploy/local-path-storage.yaml` at that tag |
| `local_path_provisioner_image_sha256` | provisioner OCI index digest |
| `local_path_provisioner_helper_image_version` / `_sha256` | busybox tag and OCI index digest |
| `local_path_provisioner_data_path` | absolute directory on workers; never `/` or under `/tmp` |
| `local_path_provisioner_hostpath_acknowledged` | must be `true` |

Defaults: `local_path_provisioner_kubeconfig`, `local_path_provisioner_cluster_hosts`
(`cluster_hosts`), `local_path_provisioner_worker_hosts` (`worker_hosts`).

`validate.yml` rejects malformed pins, a missing acknowledgement, an unsafe data
path, and worker lists that are empty or not a strict subset of the cluster.
Before any apply, the role also refuses to run when **another StorageClass is
already marked default**, or when any of the nine well-known objects exists
without this role's owner annotation.

## Idempotency

`kubectl diff` compares the complete rendered nine-object set; server-side
apply runs only when it reports drift, so an unchanged second run is read-only.
The provisioner watches its ConfigMap, so a data-path or worker-list change is
picked up without a pod restart. It affects only volumes created afterwards;
existing PVs keep the node and path they were created with.

## Operate

```bash
make storage                                   # reconcile + list StorageClasses
cd ansible && ansible-playbook platform.yml --tags storage --check --diff
```

Smoke test (manual; needs a live cluster):

```bash
export KUBECONFIG=ansible/kubeconfig
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: lpp-smoke}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 64Mi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: lpp-smoke}
spec:
  containers:
    - name: c
      image: busybox
      command: [sh, -c, 'echo ok > /data/f && sleep 3600']
      volumeMounts: [{name: d, mountPath: /data}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: lpp-smoke}}]
YAML
kubectl get pvc lpp-smoke            # Bound
kubectl get pv -o wide               # node affinity is a worker
kubectl delete pod/lpp-smoke pvc/lpp-smoke   # directory removed (Delete)
```

## Rollback

**Rollback destroys nothing on disk by itself, but every PVC that uses
`local-path` stops working.** Delete or migrate those workloads first; with
`Delete`, removing their PVCs while the provisioner still runs removes their
data.

First confirm the owner annotation on the existing objects is
`ansible-local-path-provisioner`, then from the repository root:

```bash
kubectl --kubeconfig ansible/kubeconfig delete storageclass/local-path --ignore-not-found
kubectl --kubeconfig ansible/kubeconfig delete \
  clusterrolebinding/local-path-provisioner-bind \
  clusterrole/local-path-provisioner-role --ignore-not-found
kubectl --kubeconfig ansible/kubeconfig delete namespace/local-path-storage --ignore-not-found
```

Deleting the namespace removes the Deployment, ConfigMap, ServiceAccount, Role
and RoleBinding. Volume directories left under the data path on the workers
are not removed; delete them by hand once nothing needs them. Then remove the
role from `platform.yml` (or revert the feature change) before another
platform run.
