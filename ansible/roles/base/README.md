# base

Baseline OS configuration, identical on every node: hostname, `/etc/hosts`,
timezone, chrony, apt upgrade, base packages, WiFi power-save off, and
pending-reboot reporting.

**Unit of automation:** one machine's OS baseline. **Outcome:** a patched,
time-synchronised node that can resolve the control-plane endpoint.

> **This role is a patch event.** It runs `apt upgrade`, so every application may
> pull a kernel. Nothing reboots automatically — on a cluster you drain first, by
> hand, one node at a time. A pending reboot is reported at the end of the run.

| Property | Value |
|---|---|
| Idempotent | **True**, with one caveat below |
| Atomic | **False** — a failure mid-run leaves earlier tasks applied |
| Check mode | Supported |

**Idempotency caveat:** `apt upgrade` is idempotent in the sense that a converged
node reports no change, but it is not *reproducible* — the packages it installs
depend on when you run it. Two nodes provisioned weeks apart will differ. This is
why the Kubernetes and containerd packages are pinned and held by the
`kubernetes_node` role instead of being left to this one.

## Arguments

Declared and validated in [`meta/argument_specs.yml`](meta/argument_specs.yml).

Required: `timezone`, `control_plane_endpoint`, `control_plane_host`.
Optional: `base_packages`.

## Rollback

No automatic rollback. Per-item recovery:

| Change | How to undo |
|---|---|
| Hostname | `sudo hostnamectl set-hostname <old>` |
| `/etc/hosts` entries | Managed by `lineinfile`; edit or delete the line |
| WiFi power-save unit | `sudo systemctl disable --now wifi-no-powersave.service` then delete `/etc/systemd/system/wifi-no-powersave.service` |
| `apt upgrade` | Not reversible in practice. Restore from a snapshot if you need the old package set. |

Files this role **replaces** wholesale rather than edits:
`/etc/systemd/system/wifi-no-powersave.service`. Every file it writes carries an
`Ansible managed` header.

## Usage

```yaml
- name: Configure all cluster nodes
  hosts: k8s_cluster
  roles:
    - role: base
      tags: [base]
```
