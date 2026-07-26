# worker

Joins a worker node to the cluster and labels it.

**Unit of automation:** one worker's cluster membership. **Outcome:** a
registered, labelled node, or an explicit failure that says what to do next.

| Property | Value |
|---|---|
| Idempotent | **True** — skips the join when already a member |
| Atomic | **False** |
| Check mode | **Partial** — cannot run standalone under `--check`; see below |

## Cannot run alone

The bootstrap token is minted by the `control_plane` role and cannot be produced
from a worker. Running `--tags workers` without the control-plane play fails on an
explicit assertion rather than hanging or timing out.

## Arguments

Declared and validated in [`meta/argument_specs.yml`](meta/argument_specs.yml).

Required: `control_plane_host`, `control_plane_endpoint`.

Consumed from the `control_plane` role via `hostvars`:
`control_plane_join_command`.

Every `kubectl` call in this role is delegated to `control_plane_host`, because a
worker has no admin kubeconfig of its own.

## Stale-state detection

A node holding `/etc/kubernetes/kubelet.conf` that the API server does not know
about is carrying leftovers from an earlier join attempt. This used to be
invisible: the control-plane role skips minting a token when every worker "has
joined", and this role skips joining when `kubelet.conf` exists — so such a node
stayed permanently out of the cluster while the run reported success. It now
fails with the fix:

```bash
sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d
```

## Rollback

```bash
# drain and remove from the cluster (run kubectl on the control-plane node)
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node>

# then on the worker itself
sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d
```

Cluster membership is queried live rather than read from the control-plane play's
facts, so re-running after a reset behaves correctly.

## Not covered by Molecule

Deliberately — joining requires a live API server.

## Usage

```yaml
- name: Join the workers
  hosts: workers
  roles:
    - role: worker
      tags: [workers, join]
```

Run after the control-plane play in the same `ansible-playbook` invocation, which
is what `make cluster` does.
