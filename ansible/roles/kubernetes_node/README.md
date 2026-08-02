# kubernetes_node

Everything a machine needs before `kubeadm` will work: swap off, kernel modules
and sysctls, containerd with the systemd cgroup driver, and pinned+held
kubelet/kubeadm/kubectl.

**Unit of automation:** one kubeadm-ready machine. **Outcome:** a node where
`kubeadm init` or `kubeadm join` will succeed. The kubelet is left **enabled but
not started** — it crash-loops by design until kubeadm configures it, which is
expected and harmless at this stage.

| Property | Value |
|---|---|
| Idempotent | **True** |
| Atomic | **False** |
| Check mode | Supported |

## Arguments

Declared and validated in [`meta/argument_specs.yml`](meta/argument_specs.yml).

Required: `kubernetes_minor`, `kubernetes_apt_version`, `kubernetes_key_sha256`,
`containerd_apt_version`, `docker_key_sha256`.
Optional: `kubernetes_node_managed_held_packages` (see `defaults/main.yml`).

Versions and their sha256 digests are pinned **together** in
`group_vars/all.yml`. Regenerate a digest whenever you bump its version:

```bash
curl -fsSL <url> | sha256sum
```

## Three things that will bite you

**`SystemdCgroup = true`.** containerd ships with it set to `false`, and the
resulting kubelet failure does not mention cgroups anywhere. The role patches it
and then *verifies* the patch landed, because the `regex_replace` becomes a
silent no-op if a future containerd renames the key.

**Change through persistent holds, then repair them.** Exact versions in
`group_vars` are deliberate changes, so the apt tasks use
`allow_change_held_packages` rather than temporarily unholding packages.
containerd is re-held immediately after its install, and the final idempotent
task re-holds every managed package as a repair/safety pass. Package installation
and hold updates are not atomic; rerunning the role repairs an interruption at
that boundary.

**`--node-ip` is pinned.** These machines have both WiFi and Ethernet, so left to
itself the kubelet may advertise an address that is not the `ansible_host`
everything else in this repo is built around. The mismatch presents as nodes
flapping Ready/NotReady. This must be in place **before** the node joins.

## Rollback

```bash
# release the version holds
sudo apt-mark unhold kubelet kubeadm kubectl containerd.io

# revert containerd config (a .bak~ copy sits beside it)
sudo cp /etc/containerd/config.toml.*~ /etc/containerd/config.toml
sudo systemctl restart containerd

# undo the kernel settings
sudo rm /etc/sysctl.d/99-kubernetes.conf /etc/modules-load.d/k8s.conf
sudo sysctl --system
```

**Swap is not restored by rollback.** The role comments out swap in `/etc/fstab`
and deletes `/swap.img`. Re-enabling swap means recreating the swapfile by hand.

Files this role **replaces** wholesale: `/etc/modules-load.d/k8s.conf`,
`/etc/sysctl.d/99-kubernetes.conf`, `/etc/containerd/config.toml`,
`/etc/default/kubelet`. It *edits* `/etc/fstab` in place. All carry an
`Ansible managed` header and are written with `backup: true`.

## Not covered by Molecule

Deliberately. This role manipulates swap, loads kernel modules, and sets sysctls
— a container shares the host kernel, so a passing container test would prove
nothing about whether it works on a real node. See `make test` for the role that
*is* covered.

## Usage

```yaml
- name: Configure all cluster nodes
  hosts: k8s_cluster
  roles:
    - role: kubernetes_node
      tags: [kubernetes]
```
