# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Infrastructure-as-code for a 3-node Kubernetes homelab (3× Dell OptiPlex 7050, Ubuntu 24.04 LTS). Uses Ansible for machine provisioning and kubeadm for cluster bootstrap. **Ansible owns the machines; Argo CD (not yet implemented) will own everything inside the cluster.**

## Commands

All commands run from repo root via Makefile:

```bash
make deps       # install required Ansible collections
make check      # ansible-playbook --syntax-check + ansible-lint (touches no node)
make ping       # verify SSH to all nodes
make nodes      # ansible-playbook site.yml (configure nodes, idempotent)
make cluster    # ansible-playbook cluster.yml (kubeadm init + CNI + join workers)
make all        # nodes + cluster in one go
make hosts      # print the /etc/hosts line THIS LAPTOP needs
make status     # kubectl get nodes + pods using fetched kubeconfig
```

Run `make check` before `make nodes` — the tree passes ansible-lint's `production`
profile and should stay that way.

**`make nodes` is also a patch event.** The `base` role runs `apt upgrade`, so every
run may pull a kernel. `site.yml` is `serial: 1` + `any_errors_fatal` so a bad change
stops at the first node instead of hitting all three. Nothing reboots automatically;
the base role reports pending reboots and you drain by hand, one node at a time.

**`make status` needs `k8s.lab.example` to resolve on your laptop.** The nodes get an
`/etc/hosts` entry from the `base` role; your laptop does not. Run `make hosts` once.

Run playbooks directly from `ansible/` dir when using tags:
```bash
cd ansible
ansible-playbook site.yml --tags hardening
ansible-playbook site.yml --tags kubernetes
```

Reset a broken cluster:
```bash
# On each node: sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d
make cluster
```

## Architecture

### Two-playbook design
- **`site.yml`** — idempotent node configuration. Re-run freely. Applies roles: `base` → `hardening` → `kubernetes_node`. Gets all nodes to an identical kubeadm-ready state.
- **`cluster.yml`** — one-time cluster bootstrap. Runs `control_plane` role on the CP node, then `worker` role on workers. Safe to re-run (skips init/join if already done via stat checks on `/etc/kubernetes/admin.conf` and `/etc/kubernetes/kubelet.conf`).

### Ansible roles (`ansible/roles/`)
Order in `site.yml` matters — see the note under `automation_user`.

| Role | Purpose |
|---|---|
| `preflight` | asserts required vars and settings that `kubeadm init` bakes into certs; fails on the controller before any node is touched |
| `base` | hostname, timezone, chrony, apt upgrade, base packages, WiFi power-save off, Tailscale, pending-reboot reporting |
| `automation_user` | dedicated `ansible` account, its own SSH key, validated sudoers drop-in |
| `hardening` | SSH lockdown (drop-in config), ufw firewall, unattended security upgrades (auto-reboot disabled) |
| `kubernetes_node` | swap off, kernel modules (overlay, br_netfilter), sysctls, containerd (from Docker repo, SystemdCgroup=true, pinned), kubelet/kubeadm/kubectl pinned+held, kubelet `--node-ip` pinned |
| `control_plane` | kubeadm init, Calico CNI (pod CIDR patched), kubeconfig fetch, generate join command |
| `worker` | join cluster using token from control_plane, wait for registration, label node |

`automation_user` **must** run before `hardening`: the account has to exist and be
listed in sshd's `AllowUsers` before `hardening` reloads sshd.

### Two-user model
`admin_user` (`borna`) is the human break-glass login. `ansible_service_user`
(`ansible`) is the automation account — separate SSH key, `from=`-restricted,
locked password, own validated sudoers file. Both are in `ssh_allowed_users`, and
`preflight` refuses to run if the account Ansible is connecting as is not on that
list (which would lock you out of every node on the next sshd reload).

This is separation for audit and key rotation, **not** privilege reduction —
Ansible needs root either way, so both accounts hold `NOPASSWD:ALL`.

`ansible_user` still points at `admin_user`. Switching it to the automation account
is a deliberate 4-step rollout documented in `group_vars/all.yml`.

### Key config files
- **`ansible/group_vars/all.yml`** — single source of truth for all *user-facing* variables (IPs, versions + their sha256 digests, users, pod CIDR, control plane endpoint). Role-internal lists live in that role's `defaults/main.yml` (e.g. `base_packages`) — deliberately not duplicated here, because a duplicate would silently win and edits to the role default would become no-ops.
- **`ansible/inventory.ini`** — node IPs and group membership (`control_plane`, `workers`, `k8s_cluster`)
- **`ansible/ansible.cfg`** — privilege escalation, SSH pipelining

### Inventory layout
```
[control_plane]  node-1 (192.168.178.26)
[workers]        node-2 (192.168.178.27), node-3 (192.168.178.28)
[k8s_cluster:children]  control_plane + workers
```

## Conventions

- Roles use `community.general` and `ansible.posix` modules directly, pinned to major ranges in `requirements.yml` (install with `make deps`)
- Do **not** set `stdout_callback = yaml` in `ansible.cfg` — that short name resolves to `community.general.yaml`, removed in community.general 12.0.0, and aborts every run. Use `stdout_callback = default` + `result_format = yaml`.
- Handlers live in each role's `handlers/main.yml` — hardening has `Reload sshd`/`Reload ufw`; kubernetes_node has `Reload sysctl`/`Restart containerd`/`Restart kubelet`
- The kubeconfig is fetched to `ansible/kubeconfig` (gitignored)
- `autoinstall/user-data` contains secrets and is gitignored; only `user-data.example` is tracked
- Versions **and their sha256 digests** are pinned together in `group_vars/all.yml`. The two apt signing keys and the Calico manifest are checksum-verified; never drop those `checksum:` lines. Regenerate a digest when you bump its version (`curl -fsSL <url> | sha256sum`). The k8s `Release.key` digest is stable across minor bumps.
- Anything writing to `/etc/sudoers.d/` must use `validate: visudo -cf %s` — a malformed file makes `sudo` unusable on every node at once
- Any task whose command line or output carries a secret gets `no_log: true`. Prefer removing the secret instead where possible (e.g. `kubeadm init --skip-token-print`), since `no_log` censors failures too

## Not yet implemented

`clusters/` (Argo CD app-of-apps), `images/` (agent sandbox image), HA control plane (kube-vip). See `docs/PROJECT-PLAN.md` for the roadmap.
