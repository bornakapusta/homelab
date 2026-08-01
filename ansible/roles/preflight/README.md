# preflight

Asserts the settings that cannot be fixed later, on the controller, before a
single node is contacted.

**Unit of automation:** validation only. **Outcome:** either the run continues,
or it stops having changed nothing anywhere.

Several of the values checked here are written into TLS certificates by
`kubeadm init` and cannot be changed afterwards without `kubeadm reset` on every
node — `control_plane_endpoint` and `pod_cidr` above all. The role exists so that
a typo costs you a failed assertion instead of a cluster rebuild.

| Property | Value |
|---|---|
| Idempotent | **True** — makes no changes at all |
| Atomic | N/A — nothing to roll back |
| Check mode | Supported |
| Rollback | Not applicable; the role never mutates a node |

## Arguments

Declared and validated in [`meta/argument_specs.yml`](meta/argument_specs.yml).
Only `cluster_hosts` is required to run.

The role deliberately does **not** declare the other variables it checks as
required arguments. Argument validation runs before the tasks and would emit
`missing required arguments: pod_cidr`, replacing this role's own failure
messages — which name the variable, explain what breaks, and say how to fix it —
with a generic one. The explanatory `fail_msg` blocks in `tasks/main.yml` are the
point of the role, so they stay in charge.

## What it asserts

- Controller `ansible-core` meets the floor the roles are written against
- Every required variable in `group_vars/all.yml` is set and non-empty
- Both apt-key checksums and the Cilium OCI chart digest are present and well-formed
- `ssh_allowed_users` contains both accounts, **and** the account Ansible is
  currently connected as — dropping either locks you out on the next sshd reload
- `control_plane_endpoint` is a DNS name, not an IP
- `kubernetes_apt_version` belongs to `kubernetes_minor`
- `pod_cidr` does not collide with a 192.168.x home LAN
- Every inventory host has a literal IPv4 `ansible_host`
- Exactly one control-plane node (never run a two-node control plane — etcd
  loses quorum on a single failure)

## Usage

```yaml
- name: Configure all cluster nodes
  hosts: k8s_cluster
  roles:
    - role: preflight
      tags: [always, preflight]
```

Runs first in both `site.yml` and `cluster.yml`. Tagged `always` so it is not
skipped when you narrow a run with `--tags`.
