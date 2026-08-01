# control_plane

`kubeadm init`, Cilium CNI, kubeconfig distribution, and worker join-token
generation.

**Unit of automation:** the cluster's control plane. **Outcome:** a Ready
control-plane node with a working pod network, a kubeconfig fetched to your
laptop, and a join token published for the workers.

> **The decisions this role bakes in are permanent.**
> `control_plane_endpoint` and `pod_cidr` are written into the apiserver
> certificate and the CNI configuration. Changing either afterwards requires
> `kubeadm reset` on every node. The `preflight` role validates them first for
> exactly this reason.

| Property | Value |
|---|---|
| Idempotent | **True** — skips init and reconciles Cilium only on version/value drift |
| Atomic | **False** — a failure after `kubeadm init` leaves a live cluster |
| Check mode | **Partial** — see below |

## Arguments

Declared and validated in [`meta/argument_specs.yml`](meta/argument_specs.yml).

Required: `admin_user`, `control_plane_endpoint`, `pod_cidr`, `cilium_version`,
`cilium_chart_sha256`, `worker_hosts`.

Optional: `control_plane_cilium_helm_values` defaults to the deliberately small
bootstrap profile described below.

## Cilium bootstrap profile

The controller needs Helm 4.2.x, the first Helm 4 minor that officially
supports the pinned Kubernetes 1.36 release. The role installs Cilium from its
digest-pinned OCI chart and only runs `helm upgrade --install` when the release
version, status, or user-supplied values differ. Failed changes use Helm's
`--rollback-on-failure`. Before an install or upgrade, the role verifies that
the pinned digest's chart metadata matches `cilium_version`; Helm itself ignores
`--version` when an OCI digest is supplied. On a fresh cluster this verification
runs before `kubeadm init`, so an invalid or unavailable chart leaves no partial
cluster state behind.

The upper bound is intentional: a future Helm major can rename automation
flags or change release behavior, so the role fails closed until that major has
been reviewed.

The default profile keeps Kubernetes' `kube-proxy`, uses the PodCIDRs assigned
by kubeadm (`ipam.mode=kubernetes`), and uses a VXLAN overlay. Hubble, Envoy,
and L7 policy are disabled for the initial homelab footprint; standard
Kubernetes NetworkPolicy remains enabled. The Cilium operator starts with one
replica because the CNI is installed before either worker joins.

The role refuses to install Cilium beside an existing Calico DaemonSet. A
pre-workload cluster should be reset and rebuilt; a cluster containing data
needs Cilium's documented CNI migration procedure.

### Outbound value

`control_plane_join_command` — set as a fact on the control-plane host and read by
the `worker` role through `hostvars`. This is the role's one published output, and
the reason it is not `__`-prefixed like the role's internal variables.

The fact is only set when at least one worker still needs to join, and the token
it carries has a 24-hour TTL.

## Why `--skip-token-print` instead of `no_log`

The bootstrap token was the only secret in `kubeadm init`'s output, and
`no_log: true` censored *failures* too — leaving the single most failure-prone
task in the repo with no diagnostics at all. Removing the secret at the source is
strictly better than hiding the whole result. `no_log` is still used on
`kubeadm token create`, where the command's entire output *is* the secret.

## Check mode

`kubeadm token create` has no `check_mode: false`, so under `--check` it is
skipped, the join-command fact is never set, and the `worker` role's assertion
fails. Bootstrapping a cluster in check mode is not a meaningful operation, so
this is accepted rather than worked around — but it means `--check` on
`cluster.yml` is not a useful signal for fresh nodes.

## Rollback

There is no partial rollback of a `kubeadm init`. To start over:

```bash
# on every node, control plane last
sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d
make cluster
```

The fetched `ansible/kubeconfig` on your laptop contains cluster admin
credentials and is gitignored. Delete it when you tear a cluster down; it is not
revoked by `kubeadm reset`.

## Not covered by Molecule

Deliberately — the role needs a live API server to be meaningful. A container
cannot run `kubeadm init`.

## Usage

```yaml
- name: Initialise the control plane
  hosts: control_plane
  roles:
    - role: preflight
      tags: [always, preflight]
    - role: control_plane
      tags: [control_plane, init]
```
